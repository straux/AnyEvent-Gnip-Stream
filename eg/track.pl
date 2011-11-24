#!/usr/bin/env perl

use strict;
use warnings;

use AnyEvent::Gnip::Stream;
use YAML::XS qw( LoadFile Dump );

# YAML conf file model:
#---
#gnip:
#  user: gnip_user
#  password: gnip_password
#  stream_url: stream_url

my $conf = shift or die "file ?\n";
$conf = LoadFile( $conf )->{gnip};

my $done = AE::cv;
my $listener = AnyEvent::Gnip::Stream->new(
    user          => $conf->{user},
    password      => $conf->{password},
    stream_url    => $conf->{stream_url},
    on_tweet      => sub {
        my $tweet = shift;
        print $tweet->{actor}->{preferredUsername}." > ".$tweet->{body}."\n";
    },
    on_error      => sub {
        warn shift."\n";
        $done->send;
    },
    on_connect    => sub {
        print "Stream started!\n";
    },
    on_eof        => sub {
        warn "EOF\n";
        $done->send;
    },
    compression   => 0,
    timeout       => 60,
);
$done->recv;

