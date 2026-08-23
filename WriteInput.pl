#!/usr/bin/perl

use strict;
use warnings;

use Encode qw(FB_CROAK decode encode);
use Errno qw(EEXIST ENOENT);
use Fcntl qw(
  O_CREAT O_EXCL O_NOFOLLOW O_NONBLOCK O_RDONLY O_WRONLY
  S_ISREG
);
use File::Basename qw(basename dirname);
use IO::Handle;

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

sub write_all {
  my ($file, $data, $label) = @_;
  my $offset = 0;
  while ($offset < length($data)) {
    my $written = syswrite($file, $data, length($data) - $offset, $offset);
    defined($written) && $written > 0 or fail(8, "$label write failed");
    $offset += $written;
  }
}

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

sub create_exclusive {
  my ($base_path, $mode) = @_;
  for (my $attempt = 0; $attempt < 100; $attempt++) {
    my $candidate = $attempt == 0 ? $base_path : "$base_path.$attempt";
    if (sysopen(my $file, $candidate,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, $mode)) {
      return ($file, $candidate);
    }
    next if $! == EEXIST;
    fail(8, "output create failed");
  }
  fail(8, "could not allocate an output name");
}

sub has_regular_backup {
  my ($directory, $prefix) = @_;
  opendir(my $dir, $directory) or fail(8, "backup directory open failed");
  my $seen = 0;
  while (defined(my $name = readdir($dir))) {
    next if $name eq "." || $name eq "..";
    ++$seen <= 4096 or fail(8, "backup directory has too many entries");
    next unless index($name, $prefix) == 0 && length($name) > length($prefix);
    my $candidate = "$directory/$name";
    next unless sysopen(my $file, $candidate,
                        O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    my @metadata = stat($file);
    close($file);
    if (@metadata && S_ISREG($metadata[2])) {
      closedir($dir) or fail(8, "backup directory close failed");
      return 1;
    }
  }
  closedir($dir) or fail(8, "backup directory close failed");
  return 0;
}

@ARGV == 4
  or fail(64, "usage: WriteInput.pl PATH MAX_BYTES LAYOUTS OPTIONS");
my ($path, $max_bytes, $layouts, $options) = @ARGV;
$max_bytes =~ /\A[1-9][0-9]*\z/ && $max_bytes <= 1_048_576
  or fail(64, "invalid byte limit");
$layouts =~ /\A[A-Za-z0-9_+-]+(?:,[A-Za-z0-9_+-]+){0,31}\z/
  && length($layouts) <= 2048
  or fail(64, "invalid layouts");
my %allowed_options = map { $_ => 1 } (
  "grp:caps_toggle",
  "grp:caps_toggle,grp_led:caps",
  "grp:alt_shift_toggle",
  "grp:ctrl_shift_toggle",
);
$allowed_options{$options} or fail(64, "invalid options");

my $source_exists = 1;
my ($source, @source_metadata);
if (!sysopen($source, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)) {
  if ($! == ENOENT) {
    $source_exists = 0;
  } else {
    fail(3, "input open failed");
  }
}

my $original = "";
my $mode = 0600;
if ($source_exists) {
  @source_metadata = stat($source);
  @source_metadata && S_ISREG($source_metadata[2])
    or fail(4, "input is not a regular file");
  $source_metadata[7] <= $max_bytes
    or fail(5, "input exceeds byte limit");
  $mode = $source_metadata[2] & 0777;

  $original = read_bounded($source, $max_bytes);
}

my $utf8_source = $original;
my $text = eval { decode("UTF-8", $utf8_source, FB_CROAK) };
defined($text) or fail(7, "input is not valid UTF-8");

my $replaced_layout = $text =~ s/(kb_layout\s*=\s*)"[^"]*"/$1"$layouts"/;
my $replaced_options = $text =~ s/(kb_options\s*=\s*)"[^"]*"/$1"$options"/;
if (!$replaced_layout || !$replaced_options) {
  $text .= "\nhl.config({\n  input = {\n";
  $text .= "    kb_layout = \"$layouts\",\n" unless $replaced_layout;
  $text .= "    kb_options = \"$options\",\n" unless $replaced_options;
  $text .= "  },\n})\n";
}

my $updated = encode("UTF-8", $text, FB_CROAK);
length($updated) <= $max_bytes or fail(5, "updated input exceeds byte limit");

my $directory = dirname($path);
my $filename = basename($path);
if ($source_exists && !has_regular_backup($directory, "$filename.bak.")) {
  read_bounded($source, $max_bytes) eq $original
    or fail(10, "input changed before backup");
  my ($backup, $backup_path) = create_exclusive("$path.bak." . time(), $mode);
  $partial_backup = $backup_path;
  chmod($mode, $backup_path) or fail(8, "backup permission setup failed");
  write_all($backup, $original, "backup");
  $backup->sync or fail(8, "backup sync failed");
  close($backup) or fail(8, "backup close failed");
  $partial_backup = undef;
}

my ($output, $output_path) = create_exclusive("$path.tmp.$$", $mode);
$temp_path = $output_path;
chmod($mode, $output_path) or fail(8, "input permission setup failed");
write_all($output, $updated, "input");
$output->sync or fail(8, "input sync failed");
close($output) or fail(8, "input close failed");

if ($source_exists) {
  read_bounded($source, $max_bytes) eq $original
    or fail(10, "input changed before replacement");
  my @current = lstat($path);
  @current && S_ISREG($current[2])
    && $current[0] == $source_metadata[0]
    && $current[1] == $source_metadata[1]
    && ($current[2] & 07777) == ($source_metadata[2] & 07777)
    or fail(10, "input changed before replacement");
  close($source) or fail(6, "input close failed");
} else {
  my @current = lstat($path);
  !@current && $! == ENOENT or fail(10, "input appeared before replacement");
}

rename($temp_path, $path) or fail(8, "input replacement failed");
$temp_path = undef;
