#!/usr/bin/perl
#
# The one place that reads and writes ~/.config/hypr/input.lua.
#
#   InputLua.pl read    PATH MAX_BYTES
#   InputLua.pl write   PATH MAX_BYTES BACKUP_DIR LAYOUTS VARIANTS OPTIONS EXPECTED
#   InputLua.pl backup  PATH MAX_BYTES BACKUP_DIR
#   InputLua.pl backups PATH MAX_BYTES BACKUP_DIR
#   InputLua.pl restore PATH MAX_BYTES BACKUP_DIR BACKUP_ID
#
# Reading and writing share one scanner that understands Lua comments and
# strings, so a commented-out example can never be mistaken for the live
# setting, and the writer always edits exactly what the reader reported.

use strict;
use warnings;

use Encode qw(FB_CROAK decode encode);
use Errno qw(EEXIST ENOENT);
use Fcntl qw(
  O_CREAT O_EXCL O_NOFOLLOW O_NONBLOCK O_RDONLY O_WRONLY
  S_ISDIR S_ISREG
);
use File::Basename qw(basename dirname);
use IO::Handle;
use JSON::PP ();
use POSIX qw(strftime);

use constant MAX_LAYOUTS => 4;
use constant MAX_READ_LAYOUTS => 32;
use constant MAX_NAME_CHARS => 64;
use constant MAX_FIELD_CHARS => 2048;
use constant MAX_OPTIONS => 32;
use constant KEEP_BACKUPS => 10;
use constant MAX_DIR_ENTRIES => 4096;

my $LAYOUT_RE = qr/\A[A-Za-z0-9_+-]{1,64}\z/;
my $VARIANT_RE = qr/\A[A-Za-z0-9_+-]{0,64}\z/;
my $KEPT_OPTION_RE = qr/\A[A-Za-z0-9_+.-]+:[A-Za-z0-9_+.-]+\z/;
my $SWITCH_OPTION_RE = qr/\Agrp:[a-z0-9_]{1,48}\z/;
my $LED_OPTION_RE = qr/\Agrp_led:[a-z0-9_]{1,48}\z/;
my $ROTATING_ID_RE = qr/\Ainput\.lua\.[0-9]{8}-[0-9]{6}(?:-[0-9]{1,2})?\z/;
my $ORIGINAL_ID_RE = qr/\Ainput\.lua\.bak\.[0-9]{1,12}(?:\.[0-9]{1,2})?\z/;
my @KEYS = qw(kb_layout kb_variant kb_options);

my $temp_path;
my $partial_backup;

END {
  unlink($temp_path) if defined($temp_path) && -e $temp_path;
  unlink($partial_backup) if defined($partial_backup) && -e $partial_backup;
}

sub fail {
  my ($code, $message) = @_;
  print STDERR "$message\n";
  exit $code;
}

sub byte_limit {
  my ($value) = @_;
  $value =~ /\A[1-9][0-9]*\z/ && $value <= 1_048_576
    or fail(64, "invalid byte limit");
  return $value;
}

# ---------------------------------------------------------------- scanner --

# Split Lua source into the tokens that matter for `key = "value"`:
# identifiers, single `=`, string literals, and everything else as one-char
# "other" tokens. Comments and whitespace produce nothing, so an assignment
# inside `-- ...` or `--[[ ... ]]` is invisible.
sub tokenize {
  my ($text) = @_;
  my @tokens;
  pos($text) = 0;
  my $length = length($text);
  while (pos($text) < $length) {
    if ($text =~ /\G--\[(=*)\[/gc) {
      my $close = "]$1]";
      my $end = index($text, $close, pos($text));
      pos($text) = $end < 0 ? $length : $end + length($close);
    } elsif ($text =~ /\G--[^\n]*/gc) {
    } elsif ($text =~ /\G\s+/gc) {
    } elsif ($text =~ /\G(["'])/gc) {
      my $quote = $1;
      my $start = pos($text) - 1;
      my $body = $quote eq '"' ? qr/\G(?:\\.|[^\\\n"])*/s : qr/\G(?:\\.|[^\\\n'])*/s;
      $text =~ /$body/gc;
      my $closed = $text =~ /\G\Q$quote\E/gc ? 1 : 0;
      my $end = pos($text);
      my $inner_end = $closed ? $end - 1 : $end;
      push @tokens, {
        type => "string",
        value => substr($text, $start + 1, $inner_end - $start - 1),
        start => $start,
        end => $end,
      };
    } elsif ($text =~ /\G\[(=*)\[/gc) {
      my $start = pos($text) - length($1) - 2;
      my $close = "]$1]";
      my $open_end = pos($text);
      my $end = index($text, $close, $open_end);
      my $stop = $end < 0 ? $length : $end + length($close);
      push @tokens, {
        type => "string",
        value => substr($text, $open_end, ($end < 0 ? $length : $end) - $open_end),
        start => $start,
        end => $stop,
        long => 1,
      };
      pos($text) = $stop;
    } elsif ($text =~ /\G([A-Za-z_][A-Za-z0-9_]*)/gc) {
      push @tokens, { type => "ident", value => $1 };
    } elsif ($text =~ /\G==/gc) {
      push @tokens, { type => "other" };
    } elsif ($text =~ /\G=/gc) {
      push @tokens, { type => "eq" };
    } else {
      $text =~ /\G./gcs;
      push @tokens, { type => "other" };
    }
  }
  return @tokens;
}

# The last live `key = "string"` assignment of each key wins, the same way a
# later hl.config() call overrides an earlier one.
sub scan {
  my ($text) = @_;
  my @tokens = tokenize($text);
  my %wanted = map { $_ => 1 } @KEYS;
  my %found;
  for (my $i = 0; $i + 2 < @tokens; $i++) {
    my ($name, $eq, $value) = @tokens[$i, $i + 1, $i + 2];
    next unless $name->{type} eq "ident" && $wanted{$name->{value}};
    next unless $eq->{type} eq "eq" && $value->{type} eq "string";
    $found{$name->{value}} = $value;
  }
  return \%found;
}

sub split_field {
  my ($raw) = @_;
  return () if $raw eq "";
  return map { my $x = $_; $x =~ s/\A\s+|\s+\z//g; $x } split(/,/, $raw, -1);
}

# Validates the scanned assignments and returns plain data, or a message.
sub settings_from {
  my ($found) = @_;
  my %value;
  for my $key (@KEYS) {
    next unless $found->{$key};
    my $raw = $found->{$key}{value};
    return (undef, "$key is too long") if length($raw) > MAX_FIELD_CHARS;
    return (undef, "$key contains control characters or escapes")
      if $raw =~ /[\x00-\x1f\x7f\\]/;
    return (undef, "$key uses a long-bracket string") if $found->{$key}{long};
    $value{$key} = $raw;
  }

  my @layouts = grep { $_ ne "" } split_field($value{kb_layout} // "");
  return (undef, "kb_layout has too many layouts") if @layouts > MAX_READ_LAYOUTS;
  for (@layouts) {
    return (undef, "kb_layout contains an invalid layout name") unless $_ =~ $LAYOUT_RE;
  }

  my @variants = split_field($value{kb_variant} // "");
  return (undef, "kb_variant has too many entries") if @variants > MAX_READ_LAYOUTS;
  for (@variants) {
    return (undef, "kb_variant contains an invalid variant name") unless $_ =~ $VARIANT_RE;
  }
  $#variants = $#layouts;
  @variants = map { $_ // "" } @variants;

  my @options = grep { $_ ne "" } split_field($value{kb_options} // "");
  return (undef, "kb_options has too many entries") if @options > MAX_OPTIONS;
  for (@options) {
    return (undef, "kb_options contains an unsupported option")
      unless $_ =~ $KEPT_OPTION_RE;
  }

  return ({
    layouts => \@layouts,
    variants => \@variants,
    options => \@options,
    present => { map { $_ => ($found->{$_} ? JSON::PP::true : JSON::PP::false) } @KEYS },
  }, "");
}

# ------------------------------------------------------------------- files --

sub read_bounded {
  my ($file, $max_bytes) = @_;
  defined(sysseek($file, 0, 0)) or fail(6, "input seek failed");
  my $data = "";
  while (length($data) <= $max_bytes) {
    my $remaining = $max_bytes + 1 - length($data);
    my $read = sysread($file, my $chunk, $remaining);
    defined($read) or fail(6, "input read failed");
    last if $read == 0;
    $data .= $chunk;
  }
  length($data) <= $max_bytes or fail(5, "input exceeds byte limit");
  return $data;
}

sub decode_utf8 {
  my ($bytes, $label) = @_;
  my $copy = $bytes;
  my $text = eval { decode("UTF-8", $copy, FB_CROAK) };
  defined($text) or fail(7, "$label is not valid UTF-8");
  return $text;
}

# Opens a regular file without following a final symlink. Returns
# (handle, stat) or () when it does not exist.
# With SOFT, anything unusable is reported as absent instead of fatal.
sub open_regular {
  my ($path, $max_bytes, $label, $soft) = @_;
  my $file;
  if (!sysopen($file, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)) {
    return () if $! == ENOENT || $soft;
    fail(3, "$label open failed");
  }
  my @metadata = stat($file);
  if (!@metadata || !S_ISREG($metadata[2]) || $metadata[7] > $max_bytes) {
    return () if $soft;
    fail(4, "$label is not a regular file") unless @metadata && S_ISREG($metadata[2]);
    fail(5, "$label exceeds byte limit");
  }
  return ($file, \@metadata);
}

sub write_all {
  my ($file, $data, $label) = @_;
  my $offset = 0;
  while ($offset < length($data)) {
    my $written = syswrite($file, $data, length($data) - $offset, $offset);
    defined($written) && $written > 0 or fail(8, "$label write failed");
    $offset += $written;
  }
}

sub create_exclusive {
  my ($base_path, $mode, $separator) = @_;
  for (my $attempt = 0; $attempt < 100; $attempt++) {
    my $candidate = $attempt == 0 ? $base_path : "$base_path$separator$attempt";
    if (sysopen(my $file, $candidate,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, $mode)) {
      return ($file, $candidate);
    }
    next if $! == EEXIST;
    fail(8, "output create failed");
  }
  fail(8, "could not allocate an output name");
}

sub list_names {
  my ($directory, $pattern) = @_;
  opendir(my $dir, $directory) or do {
    return () if $! == ENOENT;
    fail(8, "backup directory open failed");
  };
  my (@names, $seen);
  while (defined(my $name = readdir($dir))) {
    next if $name eq "." || $name eq "..";
    ++$seen <= MAX_DIR_ENTRIES or fail(8, "backup directory has too many entries");
    push @names, $name if $name =~ $pattern;
  }
  closedir($dir) or fail(8, "backup directory close failed");
  return sort { backup_key($a) cmp backup_key($b) } @names;
}

# Oldest first: by timestamp, then by the numeric collision suffix.
sub backup_key {
  my ($name) = @_;
  my ($stamp, $suffix) = $name =~ /\A(.*?)(?:[-.]([0-9]{1,2}))?\z/;
  return sprintf("%s#%03d", $stamp, $suffix // 0);
}

sub ensure_backup_dir {
  my ($directory) = @_;
  if (!mkdir($directory, 0700) && $! != EEXIST) {
    fail(8, "backup directory create failed");
  }
  my @metadata = lstat($directory);
  @metadata && S_ISDIR($metadata[2]) or fail(8, "backup directory is not a directory");
}

# Saves the current bytes into the rotating store unless the newest backup
# already holds exactly those bytes, then prunes to the newest KEEP_BACKUPS.
sub rotate_backup {
  my ($directory, $bytes, $max_bytes) = @_;
  ensure_backup_dir($directory);

  my @existing = list_names($directory, $ROTATING_ID_RE);
  if (@existing) {
    my ($newest) = open_regular("$directory/$existing[-1]", $max_bytes, "backup", 1);
    if ($newest) {
      my $same = read_bounded($newest, $max_bytes) eq $bytes;
      close($newest);
      return undef if $same;
    }
  }

  # Never reuse a pruned name within the same second: the next backup always
  # sorts after every existing one, so pruning can only remove older states.
  my $base = "input.lua." . strftime("%Y%m%d-%H%M%S", localtime());
  my $next = -1;
  for (@existing) {
    next unless /\A\Q$base\E(?:-([0-9]{1,2}))?\z/;
    $next = $1 // 0 if ($1 // 0) > $next;
  }
  $next < 99 or fail(8, "too many backups in one second");
  my $name = $next < 0 ? $base : "$base-" . ($next + 1);
  my $backup_path = "$directory/$name";
  sysopen(my $backup, $backup_path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
    or fail(8, "backup create failed");
  $partial_backup = $backup_path;
  write_all($backup, $bytes, "backup");
  $backup->sync or fail(8, "backup sync failed");
  close($backup) or fail(8, "backup close failed");
  $partial_backup = undef;

  my @all = list_names($directory, $ROTATING_ID_RE);
  while (@all > KEEP_BACKUPS) {
    my $oldest = shift @all;
    my @metadata = lstat("$directory/$oldest");
    unlink("$directory/$oldest") if @metadata && S_ISREG($metadata[2]);
  }
  return $name;
}

# Atomically replaces PATH with BYTES, provided the file still is exactly the
# one that was read (same inode, mode and content) or is still absent.
sub replace_input {
  my ($path, $max_bytes, $source, $source_metadata, $original, $bytes) = @_;
  my $mode = $source_metadata ? ($source_metadata->[2] & 0777) : 0600;

  my ($output, $output_path) = create_exclusive("$path.tmp.$$", $mode, ".");
  $temp_path = $output_path;
  chmod($mode, $output_path) or fail(8, "input permission setup failed");
  write_all($output, $bytes, "input");
  $output->sync or fail(8, "input sync failed");
  close($output) or fail(8, "input close failed");

  if ($source) {
    read_bounded($source, $max_bytes) eq $original
      or fail(10, "input changed before replacement");
    my @current = lstat($path);
    @current && S_ISREG($current[2])
      && $current[0] == $source_metadata->[0]
      && $current[1] == $source_metadata->[1]
      && ($current[2] & 07777) == ($source_metadata->[2] & 07777)
      or fail(10, "input changed before replacement");
    close($source) or fail(6, "input close failed");
  } else {
    my @current = lstat($path);
    !@current && $! == ENOENT or fail(10, "input appeared before replacement");
  }

  rename($temp_path, $path) or fail(8, "input replacement failed");
  $temp_path = undef;
}

sub load_input {
  my ($path, $max_bytes) = @_;
  my ($source, $metadata) = open_regular($path, $max_bytes, "input");
  return (undef, undef, "") unless $source;
  return ($source, $metadata, read_bounded($source, $max_bytes));
}

sub emit_json {
  my ($value) = @_;
  binmode(STDOUT, ":raw") or fail(8, "output setup failed");
  print STDOUT JSON::PP->new->canonical->encode($value), "\n"
    or fail(8, "output write failed");
  close(STDOUT) or fail(8, "output write failed");
}

# ---------------------------------------------------------------- commands --

sub command_read {
  @ARGV == 2 or fail(64, "usage: InputLua.pl read PATH MAX_BYTES");
  my ($path, $max) = ($ARGV[0], byte_limit($ARGV[1]));
  my ($source, undef, $bytes) = load_input($path, $max);
  my $text = decode_utf8($bytes, "input");
  close($source) if $source;
  my ($settings, $error) = settings_from(scan($text));
  $settings or fail(11, $error);
  $settings->{exists} = $source ? JSON::PP::true : JSON::PP::false;
  emit_json($settings);
}

# LAYOUTS and VARIANTS line up; OPTIONS is the complete kb_options the panel
# planned (the service merges, resolves key conflicts and adds the switch
# key); EXPECTED is the live kb_options it planned from, or "-" when the key
# was absent, so a plan made from an older file is never written.
sub parse_requested {
  my ($layouts_arg, $variants_arg, $options_arg, $expected_arg) = @_;
  $layouts_arg =~ /\A[^,]+(?:,[^,]+){0,3}\z/ or fail(64, "invalid layouts");
  my @layouts = split(/,/, $layouts_arg, -1);
  for (@layouts) { $_ =~ $LAYOUT_RE or fail(64, "invalid layouts") }

  # "-" leaves kb_variant alone: nothing needs it (no variants, no live key,
  # and no variant in effect from Omarchy's defaults).
  my $skip_variant = $variants_arg eq "-";
  my @variants = $skip_variant ? () : split(/,/, $variants_arg, -1);
  @variants = ("") x @layouts if $variants_arg eq "" || $skip_variant;
  @variants == @layouts or fail(64, "variants must match layouts");
  for (@variants) { $_ =~ $VARIANT_RE or fail(64, "invalid variants") }

  my @options = $options_arg eq "" ? () : split(/,/, $options_arg, -1);
  @options <= MAX_OPTIONS or fail(64, "invalid options");
  my (%seen, $switches, $leds);
  for (@options) {
    $_ =~ $KEPT_OPTION_RE && !$seen{$_}++ or fail(64, "invalid options");
    if (/\Agrp:/) { $_ =~ $SWITCH_OPTION_RE && !$switches++ or fail(64, "invalid options") }
    if (/\Agrp_led:/) { $_ =~ $LED_OPTION_RE && !$leds++ or fail(64, "invalid options") }
  }

  $expected_arg eq "-" || $expected_arg eq ""
    || $expected_arg =~ /\A[A-Za-z0-9_+.:,-]{1,2048}\z/
    or fail(64, "invalid expected options");
  return (\@layouts, $skip_variant ? undef : \@variants, \@options, $expected_arg);
}

sub command_write {
  @ARGV == 7 or fail(64,
    "usage: InputLua.pl write PATH MAX_BYTES BACKUP_DIR LAYOUTS VARIANTS OPTIONS EXPECTED");
  my ($path, $max, $backup_dir) = ($ARGV[0], byte_limit($ARGV[1]), $ARGV[2]);
  my ($layouts, $variants, $options, $expected) = parse_requested(@ARGV[3 .. 6]);

  my ($source, $metadata, $original) = load_input($path, $max);
  my $text = decode_utf8($original, "input");
  my $found = scan($text);
  my ($current, $error) = settings_from($found);
  $current or fail(11, "input.lua cannot be edited safely: $error");

  my $live = $found->{kb_options} ? join(",", @{$current->{options}}) : "-";
  $live eq $expected or fail(10, "input changed before replacement");

  # kb_variant is written whenever the service asks (VARIANTS not "-"): some
  # layout has a variant, the key is live, or Omarchy's defaults put a variant
  # from vconsole.conf in effect that must never pair with the new layouts.
  my %new = (
    kb_layout => join(",", @$layouts),
    kb_options => join(",", @$options),
  );
  $found->{kb_variant} && !$variants
    and fail(64, "kb_variant is live and must be written");
  $new{kb_variant} = (grep { $_ ne "" } @$variants) ? join(",", @$variants) : ""
    if $variants;

  # Replace from the end so earlier offsets stay valid.
  my @edits = sort { $b->{start} <=> $a->{start} }
    map { { %{$found->{$_}}, key => $_ } }
    grep { $found->{$_} && exists $new{$_} } @KEYS;
  for my $edit (@edits) {
    substr($text, $edit->{start}, $edit->{end} - $edit->{start}) =
      "\"$new{$edit->{key}}\"";
  }
  # A missing key goes on its own line right after a live sibling that ends
  # its line with a comma, so it lands inside the same `input = { }` table.
  # Only when no such sibling exists is a separate hl.config() block added.
  my @missing = grep { !$found->{$_} && exists $new{$_} } @KEYS;
  my ($anchor) = sort { $b->{start} <=> $a->{start} }
    grep { defined } map { scan($text)->{$_} } qw(kb_layout kb_options);
  if (@missing && $anchor) {
    my $line_start = rindex($text, "\n", $anchor->{start}) + 1;
    my ($indent) = substr($text, $line_start) =~ /\A([ \t]*)/;
    my $line_end = index($text, "\n", $anchor->{end});
    $line_end = length($text) if $line_end < 0;
    if (substr($text, $anchor->{end}, $line_end - $anchor->{end}) =~ /\A[ \t]*,[ \t]*(?:--[^\n]*)?\z/) {
      my $lines = join("", map { "\n$indent$_ = \"$new{$_}\"," } @missing);
      substr($text, $line_end, 0) = $lines;
      @missing = ();
    }
  }
  if (@missing) {
    $text .= "\n" if $text ne "" && $text !~ /\n\z/;
    $text .= "\nhl.config({\n  input = {\n";
    $text .= "    $_ = \"$new{$_}\",\n" for @missing;
    $text .= "  },\n})\n";
  }

  my $updated = encode("UTF-8", $text, FB_CROAK);
  length($updated) <= $max or fail(5, "updated input exceeds byte limit");
  return if $source && $updated eq $original;
  rotate_backup($backup_dir, $original, $max) if $source;
  replace_input($path, $max, $source, $metadata, $original, $updated);
}

# A manual backup: the same rotating store, the same checks, no write to
# input.lua. Prints {"created":bool,"id":...}.
sub command_backup {
  @ARGV == 3 or fail(64, "usage: InputLua.pl backup PATH MAX_BYTES BACKUP_DIR");
  my ($path, $max, $backup_dir) = ($ARGV[0], byte_limit($ARGV[1]), $ARGV[2]);
  my ($source, undef, $bytes) = load_input($path, $max);
  $source or fail(2, "input does not exist");
  decode_utf8($bytes, "input");
  close($source);
  my $id = rotate_backup($backup_dir, $bytes, $max);
  emit_json({
    created => defined($id) ? JSON::PP::true : JSON::PP::false,
    id => $id // "",
  });
}

sub backup_path_for {
  my ($path, $backup_dir, $id) = @_;
  return ("$backup_dir/$id", "rotating") if $id =~ $ROTATING_ID_RE;
  return (dirname($path) . "/$id", "original") if $id =~ $ORIGINAL_ID_RE;
  fail(12, "unknown backup id");
}

sub describe_backup {
  my ($file_path, $kind, $id, $max) = @_;
  my ($file, $metadata) = open_regular($file_path, $max, "backup", 1);
  return undef unless $file;
  my $bytes = read_bounded($file, $max);
  close($file);
  my $text = eval { decode("UTF-8", my $copy = $bytes, FB_CROAK) };
  my ($settings) = defined($text) ? settings_from(scan($text)) : (undef);
  return {
    id => $id,
    kind => $kind,
    time => $metadata->[9],
    size => $metadata->[7],
    layouts => $settings ? join(",", map {
      my $variant = $settings->{variants}[$_];
      $settings->{layouts}[$_] . ($variant ne "" ? "($variant)" : "")
    } 0 .. $#{$settings->{layouts}}) : "",
    valid => $settings ? JSON::PP::true : JSON::PP::false,
  };
}

sub command_backups {
  @ARGV == 3 or fail(64, "usage: InputLua.pl backups PATH MAX_BYTES BACKUP_DIR");
  my ($path, $max, $backup_dir) = ($ARGV[0], byte_limit($ARGV[1]), $ARGV[2]);
  my @rows;
  for my $id (list_names($backup_dir, $ROTATING_ID_RE)) {
    my $row = describe_backup("$backup_dir/$id", "rotating", $id, $max);
    push @rows, $row if $row;
  }
  for my $id (list_names(dirname($path), $ORIGINAL_ID_RE)) {
    my $row = describe_backup(dirname($path) . "/$id", "original", $id, $max);
    push @rows, $row if $row;
  }
  @rows = sort { $b->{time} <=> $a->{time} || $b->{id} cmp $a->{id} } @rows;
  emit_json(\@rows);
}

sub command_restore {
  @ARGV == 4 or fail(64, "usage: InputLua.pl restore PATH MAX_BYTES BACKUP_DIR BACKUP_ID");
  my ($path, $max, $backup_dir, $id) = ($ARGV[0], byte_limit($ARGV[1]), @ARGV[2, 3]);
  my ($backup_path) = backup_path_for($path, $backup_dir, $id);

  my ($backup) = open_regular($backup_path, $max, "backup");
  $backup or fail(12, "backup does not exist");
  my $restored = read_bounded($backup, $max);
  close($backup);
  my ($settings, $error) = settings_from(scan(decode_utf8($restored, "backup")));
  $settings or fail(11, "backup cannot be restored: $error");

  my ($source, $metadata, $original) = load_input($path, $max);
  rotate_backup($backup_dir, $original, $max) if $source;
  replace_input($path, $max, $source, $metadata, $original, $restored);
}

my %commands = (
  read => \&command_read,
  write => \&command_write,
  backup => \&command_backup,
  backups => \&command_backups,
  restore => \&command_restore,
);
my $command = shift(@ARGV) // "";
$commands{$command} or fail(64, "usage: InputLua.pl read|write|backup|backups|restore ...");
$commands{$command}->();
