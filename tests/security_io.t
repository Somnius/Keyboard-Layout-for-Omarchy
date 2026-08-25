#!/usr/bin/perl

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use FindBin;
use POSIX qw(mkfifo);
use Test::More;

my $repo = abs_path(File::Spec->catdir($FindBin::Bin, ".."));
my $reader = File::Spec->catfile($repo, "BoundedRead.pl");
my $runner = File::Spec->catfile($repo, "BoundedExec.pl");
my $writer = File::Spec->catfile($repo, "WriteInput.pl");
my $dir = tempdir(CLEANUP => 1);

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

sub run_command {
  my (@command) = @_;
  my ($stdout, $stdout_path) = tempfile(DIR => $dir);
  my ($stderr, $stderr_path) = tempfile(DIR => $dir);
  my $pid = fork();
  die "fork: $!" unless defined($pid);
  if ($pid == 0) {
    open(STDOUT, ">&", $stdout) or exit 126;
    open(STDERR, ">&", $stderr) or exit 126;
    exec { $command[0] } @command;
    exit 127;
  }
  waitpid($pid, 0) == $pid or die "waitpid: $!";
  my $status = $?;
  seek($stdout, 0, 0) or die "seek stdout: $!";
  seek($stderr, 0, 0) or die "seek stderr: $!";
  local $/;
  my $out = <$stdout> // "";
  my $err = <$stderr> // "";
  close($stdout);
  close($stderr);
  unlink($stdout_path, $stderr_path);
  my $exit = $status & 127 ? 128 + ($status & 127) : $status >> 8;
  return ($exit, $out, $err);
}

sub backup_paths {
  my ($path) = @_;
  return sort grep { -f $_ } glob("$path.bak.*");
}

subtest "bounded descriptor reader" => sub {
  my $regular = File::Spec->catfile($dir, "regular");
  put_raw($regular, "four");
  my ($exit, $out) = run_command($^X, $reader, $regular, "4");
  is($exit, 0, "accepts an exact-limit regular file");
  is($out, "four", "returns the descriptor contents");

  put_raw($regular, "five!");
  ($exit, $out) = run_command($^X, $reader, $regular, "4");
  isnt($exit, 0, "rejects overflow");
  is($out, "", "does not expose a prefix on overflow");

  put_raw($regular, "\xff");
  ($exit, $out) = run_command($^X, $reader, $regular, "4");
  isnt($exit, 0, "rejects invalid UTF-8");
  is($out, "", "does not expose invalid UTF-8");

  my $target = File::Spec->catfile($dir, "target");
  my $link = File::Spec->catfile($dir, "link");
  put_raw($target, "safe");
  symlink($target, $link) or die "symlink: $!";
  ($exit, $out) = run_command($^X, $reader, $link, "4");
  isnt($exit, 0, "rejects a final-component symlink");
  is($out, "", "does not read through the symlink");

  my $fifo = File::Spec->catfile($dir, "fifo");
  mkfifo($fifo, 0600) == 0 or die "mkfifo: $!";
  ($exit, $out) = run_command($^X, $reader, $fifo, "4");
  isnt($exit, 0, "rejects a FIFO without blocking");
  is($out, "", "does not read an unsafe file type");
};

subtest "bounded producer wrapper" => sub {
  my ($exit, $out) = run_command(
    $^X, $runner, "4", $^X, "-e", 'binmode STDOUT; print "four"'
  );
  is($exit, 0, "accepts exact-limit producer output");
  is($out, "four", "emits validated producer output");

  ($exit, $out) = run_command(
    $^X, $runner, "4", $^X, "-e", 'binmode STDOUT; print "five!"'
  );
  isnt($exit, 0, "rejects producer overflow");
  is($out, "", "does not pass a producer prefix to the collector");

  ($exit, $out) = run_command(
    $^X, $runner, "4", $^X, "-e", 'binmode STDOUT; print "ok"; exit 3'
  );
  isnt($exit, 0, "rejects nonzero producer exit");
  is($out, "", "suppresses output from a failed producer");

  ($exit, $out) = run_command(
    $^X, $runner, "4", $^X, "-e", 'binmode STDOUT; print "\xff"'
  );
  isnt($exit, 0, "rejects invalid producer UTF-8");
  is($out, "", "suppresses invalid producer bytes");
};

subtest "explicit input writer and backup ordering" => sub {
  my $input = File::Spec->catfile($dir, "input.lua");
  my $original = <<'LUA';
hl.config({
  input = {
    kb_layout = "us,gr",
    kb_options = "grp:caps_toggle,grp_led:caps",
  },
})
LUA
  put_raw($input, $original);
  chmod(0640, $input) or die "chmod input: $!";

  my ($exit) = run_command(
    $^X, $writer, $input, "262144", "de,fr", "grp:alt_shift_toggle"
  );
  is($exit, 0, "writes valid explicit settings");
  like(get_raw($input), qr/kb_layout = "de,fr"/, "replaces the layouts");
  like(get_raw($input), qr/kb_options = "grp:alt_shift_toggle"/, "replaces the options");
  is((stat($input))[2] & 0777, 0640, "preserves input permissions");
  my @backups = backup_paths($input);
  is(scalar(@backups), 1, "creates one backup before the first replacement");
  is(get_raw($backups[0]), $original, "backup contains the exact original bytes");

  ($exit) = run_command(
    $^X, $writer, $input, "262144", "us,pt", "grp:ctrl_shift_toggle"
  );
  is($exit, 0, "allows a later explicit write");
  my @later_backups = backup_paths($input);
  is(scalar(@later_backups), 1, "does not replace or multiply the one-time backup");

  my $unwritable = File::Spec->catdir($dir, "unwritable");
  mkdir($unwritable, 0700) or die "mkdir unwritable: $!";
  my $blocked = File::Spec->catfile($unwritable, "input.lua");
  put_raw($blocked, $original);
  chmod(0500, $unwritable) or die "chmod directory: $!";
  ($exit) = run_command(
    $^X, $writer, $blocked, "262144", "de,fr", "grp:alt_shift_toggle"
  );
  chmod(0700, $unwritable) or die "restore directory: $!";
  isnt($exit, 0, "aborts when the required backup cannot be created");
  is(get_raw($blocked), $original, "backup failure leaves input.lua untouched");

  my $linked = File::Spec->catfile($dir, "linked-input.lua");
  my $linked_target = File::Spec->catfile($dir, "linked-target.lua");
  put_raw($linked_target, $original);
  symlink($linked_target, $linked) or die "input symlink: $!";
  ($exit) = run_command(
    $^X, $writer, $linked, "262144", "de,fr", "grp:alt_shift_toggle"
  );
  isnt($exit, 0, "refuses to write through an input symlink");
  is(get_raw($linked_target), $original, "symlink target stays untouched");

  my $invalid = File::Spec->catfile($dir, "invalid-input.lua");
  put_raw($invalid, "\xff");
  ($exit) = run_command(
    $^X, $writer, $invalid, "262144", "de,fr", "grp:alt_shift_toggle"
  );
  isnt($exit, 0, "refuses invalid existing UTF-8");
  is(get_raw($invalid), "\xff", "invalid input stays untouched");
};

subtest "option allowlist" => sub {
  my $original = <<'LUA';
hl.config({
  input = {
    kb_layout = "us,gr",
    kb_options = "grp:caps_toggle",
  },
})
LUA

  my @accepted = (
    "grp:caps_toggle",
    "grp:caps_toggle,grp_led:caps",
    "grp:alt_shift_toggle",
    "grp:ctrl_shift_toggle",
    "shift:both_capslock_cancel,grp:caps_toggle",
    "shift:both_capslock_cancel,grp:caps_toggle,grp_led:caps",
    "compose:caps,shift:both_capslock_cancel,grp:alts_toggle",
    "compose:caps,shift:both_capslock_cancel,grp:alt_shift_toggle",
    "compose:caps,shift:both_capslock_cancel,grp:ctrl_shift_toggle",
  );
  my $index = 0;
  for my $options (@accepted) {
    my $input = File::Spec->catfile($dir, "allow-" . $index++ . ".lua");
    put_raw($input, $original);
    my ($exit) = run_command($^X, $writer, $input, "262144", "us,it", $options);
    is($exit, 0, "accepts $options");
    like(get_raw($input), qr/\Qkb_options = "$options"\E/, "writes $options verbatim");
  }

  # The allowlist is exact-match on purpose: near-misses and injection
  # attempts must not slip through on a substring.
  my @rejected = (
    "grp:alts_toggle",                                   # bare form is not offered
    "grp:evil_toggle",
    "compose:caps,grp:alts_toggle",                      # wrong stock prefix
    "compose:caps,shift:both_capslock_cancel,grp:alts_toggle,grp_led:caps",
    'grp:caps_toggle" } }) os.execute("touch /tmp/pwn',  # lua break-out
    "",
  );
  for my $options (@rejected) {
    my $input = File::Spec->catfile($dir, "deny-" . $index++ . ".lua");
    put_raw($input, $original);
    my ($exit) = run_command($^X, $writer, $input, "262144", "us,it", $options);
    isnt($exit, 0, "rejects '$options'");
    is(get_raw($input), $original, "leaves input.lua untouched for '$options'");
  }
};

done_testing();
