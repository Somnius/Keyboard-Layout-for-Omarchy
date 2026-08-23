#!/usr/bin/perl

use strict;
use warnings;

use Encode qw(FB_CROAK decode);

my $child_pid;

sub terminate_child {
  my ($exit_code) = @_;
  if (defined($child_pid) && $child_pid > 0) {
    kill("TERM", $child_pid);
    waitpid($child_pid, 0);
    $child_pid = undef;
  }
  exit $exit_code;
}

$SIG{TERM} = sub { terminate_child(143) };
$SIG{INT} = sub { terminate_child(130) };
$SIG{HUP} = sub { terminate_child(129) };

sub fail {
  my ($code, $message) = @_;
  print STDERR "$message\n";
  exit $code;
}

@ARGV >= 2 or fail(64, "usage: BoundedExec.pl MAX_BYTES COMMAND [ARG ...]");
my $max_bytes = shift @ARGV;
$max_bytes =~ /\A[1-9][0-9]*\z/ && $max_bytes <= 1_048_576
  or fail(64, "invalid byte limit");

pipe(my $reader, my $writer) or fail(3, "producer pipe failed");
my $pid = fork();
defined($pid) or fail(3, "producer fork failed");

if ($pid == 0) {
  $SIG{TERM} = "DEFAULT";
  $SIG{INT} = "DEFAULT";
  $SIG{HUP} = "DEFAULT";
  close($reader);
  open(STDOUT, ">&", $writer) or exit 126;
  open(STDERR, ">", "/dev/null") or exit 126;
  close($writer);
  exec { $ARGV[0] } @ARGV;
  exit 127;
}
$child_pid = $pid;

close($writer) or do {
  kill("TERM", $pid);
  waitpid($pid, 0);
  fail(3, "producer pipe failed");
};

my $data = "";
my $read_failed = 0;
while (length($data) <= $max_bytes) {
  my $remaining = $max_bytes + 1 - length($data);
  my $read = sysread($reader, my $chunk, $remaining);
  if (!defined($read)) {
    $read_failed = 1;
    last;
  }
  last if $read == 0;
  $data .= $chunk;
}

my $overflow = length($data) > $max_bytes;
if ($overflow || $read_failed) {
  close($reader);
  kill("TERM", $pid);
  waitpid($pid, 0);
  $child_pid = undef;
  fail(5, "producer output exceeds byte limit") if $overflow;
  fail(6, "producer output read failed");
}

close($reader) or do {
  kill("TERM", $pid);
  waitpid($pid, 0);
  $child_pid = undef;
  fail(6, "producer output read failed");
};
waitpid($pid, 0) == $pid or fail(6, "producer wait failed");
$child_pid = undef;
$? == 0 or fail(9, "producer exited unsuccessfully");

my $utf8_check = $data;
eval { decode("UTF-8", $utf8_check, FB_CROAK); 1 }
  or fail(7, "producer output is not valid UTF-8");

binmode(STDOUT, ":raw") or fail(8, "output setup failed");
print STDOUT $data or fail(8, "output write failed");
close(STDOUT) or fail(8, "output write failed");
