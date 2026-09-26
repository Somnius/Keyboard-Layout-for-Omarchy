#!/usr/bin/perl

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use FindBin;
use JSON::PP qw(decode_json);
use Test::More;

my $repo = abs_path(File::Spec->catdir($FindBin::Bin, ".."));
my $tool = File::Spec->catfile($repo, "InputLua.pl");
my $root = tempdir(CLEANUP => 1);
my $limit = "262144";
my $case = 0;

sub put_raw {
  my ($path, $data) = @_;
  open(my $file, ">:raw", $path) or die "open $path: $!";
  print {$file} $data or die "write $path: $!";
  close($file) or die "close $path: $!";
}

sub get_raw {
  my ($path) = @_;
  open(my $file, "<:raw", $path) or die "open $path: $!";
  local $/;
  my $data = <$file>;
  close($file) or die "close $path: $!";
  return $data;
}

sub run_tool {
  my (@args) = @_;
  my ($stdout, $stdout_path) = tempfile(DIR => $root);
  my ($stderr, $stderr_path) = tempfile(DIR => $root);
  my $pid = fork();
  die "fork: $!" unless defined($pid);
  if ($pid == 0) {
    open(STDOUT, ">&", $stdout) or exit 126;
    open(STDERR, ">&", $stderr) or exit 126;
    exec { $^X } $^X, $tool, @args;
    exit 127;
  }
  waitpid($pid, 0) == $pid or die "waitpid: $!";
  my $status = $?;
  seek($stdout, 0, 0);
  seek($stderr, 0, 0);
  local $/;
  my $out = <$stdout> // "";
  my $err = <$stderr> // "";
  unlink($stdout_path, $stderr_path);
  return ($status >> 8, $out, $err);
}

# A fresh directory holding input.lua (with CONTENT, unless undef) and an
# empty backups/ path, as the plugin lays them out.
sub fixture {
  my ($content) = @_;
  my $dir = File::Spec->catdir($root, "case" . ++$case);
  mkdir($dir) or die "mkdir: $!";
  my $input = "$dir/input.lua";
  put_raw($input, $content) if defined($content);
  return ($input, "$dir/backups");
}

sub read_settings {
  my ($input) = @_;
  my ($exit, $out, $err) = run_tool("read", $input, $limit);
  return $exit == 0 ? decode_json($out) : { error => $err, exit => $exit };
}

# Writes the way the service does: plan kb_options from the current read
# (keep non-switch options, add GROUPS) and pass that read as EXPECTED.
sub write_settings {
  my ($input, $backups, $layouts, $variants, $groups) = @_;
  my $current = read_settings($input);
  my $present = $current->{present} && $current->{present}{kb_options};
  my @kept = grep { !/\Agrp(?:_led)?:/ } @{$current->{options} || []};
  my @options = (@kept, $groups eq "" ? () : split(/,/, $groups));
  return run_tool("write", $input, $limit, $backups, $layouts, $variants,
    join(",", @options), $present ? join(",", @{$current->{options}}) : "-");
}

sub write_raw {
  my ($input, $backups, @rest) = @_;
  return run_tool("write", $input, $limit, $backups, @rest);
}

sub rotating {
  my ($backups) = @_;
  opendir(my $dir, $backups) or return ();
  # Oldest first, ordering same-second collisions (-1 … -99) numerically.
  my @names = map { $_->[0] }
    sort { $a->[1] cmp $b->[1] || $a->[2] <=> $b->[2] }
    map { /\A(input\.lua\.[0-9]{8}-[0-9]{6})(?:-([0-9]+))?\z/ ? [$_, $1, $2 // 0] : () }
    readdir($dir);
  closedir($dir);
  return @names;
}

sub count_rotating { my @names = rotating(@_); return scalar(@names) }

my $omarchy_template = <<'LUA';
-- Keep only your personal input overrides here.

hl.config({
  input = {
    -- English primary, Greek secondary.
    kb_layout = "us,gr",

    -- Caps Lock switches layouts.
    kb_options = "grp:caps_toggle,grp_led:caps",

    -- Use a specific keyboard variant if needed (e.g. intl for international keyboards).
    -- kb_variant = "intl",
  },
})
LUA

subtest "reader ignores comments and strings" => sub {
  my ($input) = fixture(<<'LUA');
-- kb_layout = "de"
--[[ kb_options = "grp:alt_shift_toggle"
kb_variant = "nodeadkeys" ]]
--[==[ kb_layout = "fr" ]==]
local note = "kb_layout = \"it\""
local other = 'kb_options = "x:y"'
hl.config({ input = { kb_layout = "us,gr", kb_options = "grp:caps_toggle" } })
LUA
  my $settings = read_settings($input);
  is_deeply($settings->{layouts}, ["us", "gr"], "only the live kb_layout counts");
  is_deeply($settings->{options}, ["grp:caps_toggle"], "only the live kb_options counts");
  is_deeply($settings->{variants}, ["", ""], "a commented kb_variant is ignored");
  ok(!$settings->{present}{kb_variant}, "kb_variant is reported absent");
};

subtest "the last live assignment wins" => sub {
  my ($input) = fixture(<<'LUA');
hl.config({ input = { kb_layout = "us" } })
hl.config({ input = { kb_layout = "us,ru", kb_variant = ",phonetic" } })
LUA
  my $settings = read_settings($input);
  is_deeply($settings->{layouts}, ["us", "ru"], "later hl.config wins");
  is_deeply($settings->{variants}, ["", "phonetic"], "variants align with layouts");
};

subtest "reader rejects unsafe values" => sub {
  for my $bad ('kb_layout = "us;rm"', 'kb_layout = "us\\ngr"',
               'kb_options = "grp:caps_toggle,\\"x"', 'kb_layout = [[us]]',
               'kb_options = "not an option"') {
    my ($input) = fixture("hl.config({ input = { $bad } })\n");
    my $result = read_settings($input);
    ok($result->{error}, "rejects $bad");
  }
  my ($missing) = fixture(undef);
  my $settings = read_settings($missing);
  ok(!$settings->{exists}, "a missing file reads as empty, not an error");
  is_deeply($settings->{layouts}, [], "no layouts when missing");
};

subtest "writer edits the live settings in place" => sub {
  my ($input, $backups) = fixture($omarchy_template);
  my ($exit, undef, $err) = write_settings($input, $backups,
    "us,gr,de", ",polytonic,nodeadkeys", "grp:alt_shift_toggle");
  is($exit, 0, "write succeeds") or diag($err);
  my $text = get_raw($input);
  like($text, qr/^    kb_layout = "us,gr,de",$/m, "layouts replaced in place");
  like($text, qr/^    kb_variant = ",polytonic,nodeadkeys",$/m,
    "missing kb_variant inserted beside kb_layout");
  like($text, qr/^    -- kb_variant = "intl",$/m, "the commented example is untouched");
  like($text, qr/^    -- English primary, Greek secondary\.$/m, "comments survive");
  unlike($text, qr/hl\.config\(\{\n  input = \{\n    kb_variant/, "no extra block appended");
  my $settings = read_settings($input);
  is_deeply($settings->{layouts}, ["us", "gr", "de"], "reads back layouts");
  is_deeply($settings->{variants}, ["", "polytonic", "nodeadkeys"], "reads back variants");
  is_deeply($settings->{options}, ["grp:alt_shift_toggle"], "reads back options");

  ($exit) = write_settings($input, $backups, "us,gr", "", "grp:caps_toggle,grp_led:caps");
  is($exit, 0, "second write succeeds");
  $settings = read_settings($input);
  is_deeply($settings->{variants}, ["", ""], "variants cleared when none requested");
  like(get_raw($input), qr/kb_variant = "",/, "existing kb_variant key kept but emptied");
};

subtest "writer keeps foreign kb_options" => sub {
  my ($input, $backups) = fixture(
    qq{hl.config({ input = { kb_layout = "us,gr", kb_options = "compose:ralt,grp:alt_shift_toggle,caps:escape,grp_led:scroll" } })\n});
  my ($exit) = write_settings($input, $backups, "us,gr", "", "grp:ctrl_shift_toggle");
  is($exit, 0, "write succeeds");
  is_deeply(read_settings($input)->{options},
    ["compose:ralt", "caps:escape", "grp:ctrl_shift_toggle"],
    "non-group options kept, old group options replaced");

  ($exit) = write_settings($input, $backups, "us,gr", "", "");
  is($exit, 0, "a write with no switch option succeeds");
  is_deeply(read_settings($input)->{options}, ["compose:ralt", "caps:escape"],
    "no group option means none is written");
};

subtest "writer appends when nothing is present" => sub {
  my ($input, $backups) = fixture("-- only comments\n");
  my ($exit) = write_settings($input, $backups, "us", "intl", "grp:caps_toggle");
  is($exit, 0, "write succeeds");
  my $settings = read_settings($input);
  is_deeply($settings->{layouts}, ["us"], "layout appended");
  is_deeply($settings->{variants}, ["intl"], "variant appended");
  like(get_raw($input), qr/\A-- only comments\n/, "original content preserved");

  my ($absent, $absent_backups) = fixture(undef);
  ($exit) = write_settings($absent, $absent_backups, "us,gr", "", "grp:caps_toggle");
  is($exit, 0, "creates a missing input.lua");
  is((stat($absent))[2] & 0777, 0600, "new file is private");
  is(count_rotating($absent_backups), 0, "nothing to back up for a new file");
};

subtest "writer validates its arguments" => sub {
  my ($input, $backups) = fixture($omarchy_template);
  my $live = "grp:caps_toggle,grp_led:caps";
  my @bad = (
    ["us,gr,de,fr,it", "", "grp:caps_toggle", $live],
    ["us;x", "", "grp:caps_toggle", $live],
    ["", "", "grp:caps_toggle", $live],
    ["us,gr", "intl", "grp:caps_toggle", $live],
    ["us,gr", ",bad variant", "grp:caps_toggle", $live],
    ["us,gr", "", "not an option", $live],
    ["us,gr", "", "grp:caps_toggle,grp:alt_shift_toggle", $live],
    ["us,gr", "", "grp:caps_toggle,grp_led:caps,grp_led:num", $live],
    ["us,gr", "", "compose:ralt,compose:ralt", $live],
    ["us,gr", "", "grp:\"x", $live],
    ["us,gr", "", "grp:caps_toggle", "bad expected;"],
  );
  for my $args (@bad) {
    my ($exit) = write_raw($input, $backups, @$args);
    is($exit, 64, "rejects @{[join(' | ', @$args)]}");
  }
  is(get_raw($input), $omarchy_template, "rejected writes leave input.lua untouched");

  my ($unsafe, $unsafe_backups) = fixture(
    qq{hl.config({ input = { kb_layout = "us", kb_options = "weird option" } })\n});
  my ($exit) = write_raw($unsafe, $unsafe_backups, "us,gr", "", "grp:caps_toggle", "-");
  is($exit, 11, "refuses to rewrite options it cannot keep faithfully");
};

subtest "writer refuses a plan made from an older file" => sub {
  my ($input, $backups) = fixture($omarchy_template);
  my ($exit) = write_raw($input, $backups, "de", "", "grp:caps_toggle", "grp:alt_shift_toggle");
  is($exit, 10, "expected options differ from the live ones");
  ($exit) = write_raw($input, $backups, "de", "", "grp:caps_toggle", "-");
  is($exit, 10, "expected absent but the key is live");
  is(get_raw($input), $omarchy_template, "input.lua untouched");
  is(count_rotating($backups), 0, "no backup for a refused write");

  ($exit) = write_raw($input, $backups, "de", "", "grp:caps_toggle",
    "grp:caps_toggle,grp_led:caps");
  is($exit, 0, "the matching expectation writes");
};

subtest "stock install keeps Omarchy's effective options" => sub {
  # The issue #1 case: Omarchy's input.lua with everything commented out.
  my ($input, $backups) = fixture(<<'LUA');
-- hl.config({
--   input = {
--     kb_layout = "us,se",
--     kb_options = "grp:alt_shift_toggle",
--   },
-- })
LUA
  my ($exit, undef, $err) = write_raw($input, $backups, "us,se", "",
    "compose:caps,shift:both_capslock_cancel,grp:alt_shift_toggle", "-");
  is($exit, 0, "writes the planned options") or diag($err);
  my $settings = read_settings($input);
  is_deeply($settings->{layouts}, ["us", "se"], "layouts are live");
  is_deeply($settings->{options},
    ["compose:caps", "shift:both_capslock_cancel", "grp:alt_shift_toggle"],
    "Omarchy's defaults survive alongside the switch key");
  ok($settings->{present}{kb_variant}, "kb_variant is written with the layouts");
  is_deeply($settings->{variants}, ["", ""], "as empty variants");
  like(get_raw($input), qr/\A-- hl\.config\(\{\n--   input/, "the commented example is untouched");

  my ($plain, $plain_backups) = fixture($omarchy_template);
  ($exit) = write_raw($plain, $plain_backups, "us,gr", "-", "grp:caps_toggle,grp_led:caps",
    "grp:caps_toggle,grp_led:caps");
  is($exit, 0, "'-' variants on an unchanged file");
  is(get_raw($plain), $omarchy_template, "leaves the file byte-identical (no kb_variant added)");

  my ($live, $live_backups) = fixture(qq{hl.config({ input = { kb_layout = "us", kb_variant = "intl", kb_options = "" } })\n});
  ($exit) = write_raw($live, $live_backups, "us", "-", "", "");
  is($exit, 64, "'-' is refused when kb_variant is live");
};

subtest "writer file safety" => sub {
  my ($input, $backups) = fixture($omarchy_template);
  chmod(0640, $input) or die;
  my ($exit) = write_settings($input, $backups, "de,fr", "", "grp:alt_shift_toggle");
  is($exit, 0, "write succeeds");
  is((stat($input))[2] & 0777, 0640, "preserves permissions");

  my ($linked, $linked_backups) = fixture(undef);
  my $target = "$linked.target";
  put_raw($target, $omarchy_template);
  symlink($target, $linked) or die;
  ($exit) = write_settings($linked, $linked_backups, "de", "", "grp:caps_toggle");
  isnt($exit, 0, "refuses to write through a symlink");
  is(get_raw($target), $omarchy_template, "symlink target untouched");

  my ($invalid, $invalid_backups) = fixture("\xff");
  ($exit) = write_settings($invalid, $invalid_backups, "de", "", "grp:caps_toggle");
  is($exit, 7, "refuses invalid UTF-8");
  is(get_raw($invalid), "\xff", "invalid input untouched");

  my ($big, $big_backups) = fixture("-- " . ("x" x 300) . "\n");
  ($exit) = run_tool("write", $big, "100", $big_backups, "us", "", "grp:caps_toggle", "-");
  is($exit, 5, "refuses an oversized input");

  my ($blocked, $blocked_backups) = fixture($omarchy_template);
  put_raw($blocked_backups, "not a directory");
  ($exit) = write_settings($blocked, $blocked_backups, "de", "", "grp:caps_toggle");
  isnt($exit, 0, "aborts when the backup cannot be made");
  is(get_raw($blocked), $omarchy_template, "backup failure leaves input.lua untouched");
};

subtest "rotating backups" => sub {
  my ($input, $backups) = fixture($omarchy_template);
  my $original = get_raw($input);
  my ($exit) = write_settings($input, $backups, "de", "", "grp:caps_toggle");
  is($exit, 0, "first write");
  my @names = rotating($backups);
  is(scalar(@names), 1, "one backup after one write");
  is(get_raw("$backups/$names[0]"), $original, "backup holds the exact prior bytes");
  is((stat("$backups/$names[0]"))[2] & 0777, 0600, "backup is private");
  is((stat($backups))[2] & 0777, 0700, "backup directory is private");

  ($exit) = write_settings($input, $backups, "de", "", "grp:caps_toggle");
  is(count_rotating($backups), 1, "a write that changes nothing makes no backup");

  for my $layout (qw(fr it es pt nl pl se no fi dk cz hu)) {
    write_settings($input, $backups, $layout, "", "grp:caps_toggle");
  }
  @names = rotating($backups);
  is(scalar(@names), 10, "keeps only the newest ten");
  my $newest = read_settings($input);
  is_deeply($newest->{layouts}, ["hu"], "the live file has the last write");
  like(get_raw("$backups/$names[-1]"), qr/kb_layout = "cz"/, "newest backup is the previous state")
    or diag(join("\n", map { "$_: " . (get_raw("$backups/$_") =~ /kb_layout = "(\w+)"/)[0] } @names));
};

subtest "manual backup" => sub {
  my ($input, $backups) = fixture($omarchy_template);
  my ($exit, $out) = run_tool("backup", $input, $limit, $backups);
  is($exit, 0, "manual backup succeeds");
  my $result = decode_json($out);
  ok($result->{created}, "reports a new backup");
  like($result->{id}, qr/\Ainput\.lua\.[0-9]{8}-[0-9]{6}\z/, "reports its id");
  is(get_raw("$backups/$result->{id}"), $omarchy_template, "holds the exact bytes");
  is(get_raw($input), $omarchy_template, "input.lua is not touched");

  ($exit, $out) = run_tool("backup", $input, $limit, $backups);
  is($exit, 0, "a repeat succeeds");
  ok(!decode_json($out)->{created}, "but makes no duplicate of unchanged bytes");
  is(count_rotating($backups), 1, "still one backup");

  my ($absent, $absent_backups) = fixture(undef);
  ($exit) = run_tool("backup", $absent, $limit, $absent_backups);
  is($exit, 2, "nothing to back up when input.lua is missing");

  my ($invalid, $invalid_backups) = fixture("\xff");
  ($exit) = run_tool("backup", $invalid, $limit, $invalid_backups);
  is($exit, 7, "refuses to store invalid UTF-8");
};

subtest "backup listing and restore" => sub {
  my ($input, $backups) = fixture($omarchy_template);
  my $original_bak = "$input.bak.1787432230";
  put_raw($original_bak, $omarchy_template);
  write_settings($input, $backups, "de,fr", "", "grp:alt_shift_toggle");
  write_settings($input, $backups, "it", "", "grp:caps_toggle");

  my ($exit, $out) = run_tool("backups", $input, $limit, $backups);
  my ($vinput, $vbackups) = fixture($omarchy_template);
  write_settings($vinput, $vbackups, "us,gr", ",polytonic", "grp:caps_toggle");
  write_settings($vinput, $vbackups, "us", "", "grp:caps_toggle");
  my (undef, $vout) = run_tool("backups", $vinput, $limit, $vbackups);
  is(decode_json($vout)->[0]{layouts}, "us,gr(polytonic)", "summaries include variants");
  is($exit, 0, "listing succeeds");
  my $rows = decode_json($out);
  is(scalar(@$rows), 3, "lists rotating and original backups");
  my ($orig) = grep { $_->{kind} eq "original" } @$rows;
  is($orig->{id}, "input.lua.bak.1787432230", "original backup listed by name");
  is($orig->{layouts}, "us,gr", "original backup summarised");
  my ($rot) = grep { $_->{kind} eq "rotating" && $_->{layouts} =~ /de/ } @$rows;
  is($rot->{layouts}, "de,fr", "rotating backup summarised");
  ok($orig->{valid}, "original backup is restorable");

  for my $id ("../input.lua", "input.lua", "input.lua.bak.x", "/etc/passwd",
              "input.lua.20260101-000000/../../x", "") {
    ($exit) = run_tool("restore", $input, $limit, $backups, $id);
    is($exit, 12, "refuses backup id '$id'");
  }
  ($exit) = run_tool("restore", $input, $limit, $backups, "input.lua.20000101-000000");
  is($exit, 12, "refuses a well-formed id that does not exist");

  my $before = get_raw($input);
  ($exit) = run_tool("restore", $input, $limit, $backups, "input.lua.bak.1787432230");
  is($exit, 0, "restores the original backup");
  is(get_raw($input), $omarchy_template, "input.lua now equals the original");
  ok(-f $original_bak, "the original backup file is left in place");
  my @names = rotating($backups);
  is(get_raw("$backups/$names[-1]"), $before, "the replaced state was backed up first");

  my $evil = "$backups/input.lua.20000101-000000";
  symlink($input, $evil) or die;
  ($exit) = run_tool("restore", $input, $limit, $backups, "input.lua.20000101-000000");
  isnt($exit, 0, "refuses a symlinked backup");

  my $broken = "$backups/input.lua.20000101-000001";
  put_raw($broken, qq{kb_layout = "us;evil"\n});
  ($exit) = run_tool("restore", $input, $limit, $backups, "input.lua.20000101-000001");
  is($exit, 11, "refuses a backup that does not parse");
  is(get_raw($input), $omarchy_template, "failed restores leave input.lua untouched");

  ($exit, $out) = run_tool("backups", $input, $limit, $backups);
  is($exit, 0, "listing survives a symlink and a broken backup");
  my ($bad) = grep { $_->{id} eq "input.lua.20000101-000001" } @{decode_json($out)};
  ok($bad && !$bad->{valid}, "broken backup is listed as not restorable");
};

done_testing();
