#!/usr/bin/env perl

use strict;
use warnings;

use AnyEvent::Gnip::Stream;
use YAML::XS qw( LoadFile Dump );

# YAML conf file:
#---
#user: gnip_user
#password: gnip_password
#box_name: gnip_box_name
#collector_id: 1

my ( $conf ) = @ARGV;
$conf = LoadFile( $conf )->{gnip};

my $done = AE::cv;
my $listener = AnyEvent::Gnip::Stream->new(
    username      => $conf->{user},
    password      => $conf->{password},
    gnip_box_name => $conf->{box_name},
    collector_id  => $conf->{collector_id},
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
    timeout       => 60,
);
$done->recv;

