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

done_testing();
