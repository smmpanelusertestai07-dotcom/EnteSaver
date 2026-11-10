#!/usr/bin/perl
# Starts one program with the variables PocketIDE handed over in a file instead of on the
# command line, where every process could read them in /proc/<pid>/cmdline.
#
# Usage: launch.pl <variables file> <program> [arguments...]
# The file holds NAME=value pairs, each ended by a NUL byte. It is deleted as soon as it has
# been read. Perl rather than bash, because bash refuses or rewrites some names (UID, RANDOM,
# SHELLOPTS) that a plain environment may carry.
use strict;
use warnings;
no warnings 'exec';

sub fail {
    my ($message) = @_;
    print STDERR "launch.pl: $message\n";
    exit 127;
}

fail('usage: launch.pl <variables file> <program> [arguments...]') if @ARGV < 2;
my $file = shift @ARGV;

open(my $input, '<:raw', $file) or fail("cannot read $file: $!");
my @pairs = do { local $/ = "\0"; <$input> };
close $input;
unlink $file;

for my $pair (@pairs) {
    chomp $pair;
    next if $pair eq '';
    my ($name, $value) = split /=/, $pair, 2;
    fail("not a variable name: $name") unless defined $value && $name =~ /\A[A-Z_][A-Z0-9_]*\z/;
    $ENV{$name} = $value;
}

my $program = $ARGV[0];
exec { $program } @ARGV or fail("cannot start $program: $!");
