#!/usr/bin/perl

use strict;
use warnings;

use Encode qw(FB_CROAK decode);
use Errno qw(ENOENT);
use Fcntl qw(O_NOFOLLOW O_NONBLOCK O_RDONLY S_ISREG);

sub fail {
  my ($code, $message) = @_;
  print STDERR "$message\n";
  exit $code;
}

@ARGV == 2 or fail(64, "usage: BoundedRead.pl PATH MAX_BYTES");
my ($path, $max_bytes) = @ARGV;
$max_bytes =~ /\A[1-9][0-9]*\z/ && $max_bytes <= 1_048_576
  or fail(64, "invalid byte limit");

sysopen(my $file, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or do {
  fail(2, "input does not exist") if $! == ENOENT;
  fail(3, "input open failed");
};

my @metadata = stat($file);
@metadata && S_ISREG($metadata[2]) or fail(4, "input is not a regular file");
$metadata[7] <= $max_bytes or fail(5, "input exceeds byte limit");

my $data = "";
while (length($data) <= $max_bytes) {
  my $remaining = $max_bytes + 1 - length($data);
  my $read = sysread($file, my $chunk, $remaining);
  defined($read) or fail(6, "input read failed");
  last if $read == 0;
  $data .= $chunk;
}

length($data) <= $max_bytes or fail(5, "input exceeds byte limit");
close($file) or fail(6, "input close failed");
my $utf8_check = $data;
eval { decode("UTF-8", $utf8_check, FB_CROAK); 1 }
  or fail(7, "input is not valid UTF-8");

binmode(STDOUT, ":raw") or fail(8, "output setup failed");
print STDOUT $data or fail(8, "output write failed");
close(STDOUT) or fail(8, "output write failed");
