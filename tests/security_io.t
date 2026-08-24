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

subtest "default Omarchy template with commented-out settings" => sub {
  my $input = File::Spec->catfile($dir, "template-input.lua");
  my $template = <<'LUA';
-- Keyboard layout and options.
-- hl.config({
--   input = {
--     kb_layout = "us,se",
--     kb_options = "grp:alt_shift_toggle",
--   },
-- })
LUA
  put_raw($input, $template);

  my ($exit) = run_command(
    $^X, $writer, $input, "262144", "de,fr", "grp:alt_shift_toggle"
  );
  is($exit, 0, "writes settings against a fully-commented template");

  my $after = get_raw($input);
  like(
    $after,
    qr/^--\s*kb_layout = "us,se",$/m,
    "leaves the commented-out example line untouched"
  );
  like(
    $after,
    qr/^hl\.config\(\{$/m,
    "appends a new, active hl.config block"
  );
  like($after, qr/kb_layout = "de,fr"/, "active block carries the new layout");
  like(
    $after,
    qr/kb_options = "grp:alt_shift_toggle"/,
    "active block carries the new options"
  );

  my ($exit2) = run_command(
    $^X, $writer, $input, "262144", "us,pt", "grp:ctrl_shift_toggle"
  );
  is($exit2, 0, "allows a second apply against the same file");

  my $reapplied = get_raw($input);
  my @active_blocks = ($reapplied =~ /^hl\.config\(\{$/mg);
  is(scalar(@active_blocks), 1, "does not stack a second managed block");
  like($reapplied, qr/kb_layout = "us,pt"/, "second apply updates the layout");
  like(
    $reapplied,
    qr/kb_options = "grp:ctrl_shift_toggle"/,
    "second apply updates the options"
  );
  like(
    $reapplied,
    qr/^--\s*kb_layout = "us,se",$/m,
    "commented-out example line is still untouched after a second apply"
  );
};

done_testing();
