package AnyEvent::Gnip::Stream;

use strict;
use 5.008_001;
our $VERSION = '0.01';

use AnyEvent::HTTP;
use AnyEvent::Util;
use MIME::Base64;
use URI;
use URI::Escape;

our $STREAMING_SERVER  = 'gnip.com';
our $PROTOCOL          = 'https';
our $REQ_METHOD        = 'GET';

sub new {
    my $class = shift;
    my %args  = @_;

    # Stream params
    my $username        = delete $args{username};
    my $password        = delete $args{password};
    my $gnip_box_name   = delete $args{gnip_box_name};
    my $collector_id    = delete $args{collector_id};

    # callbacks
    my $on_connect      = delete $args{on_connect} || sub { };
    my $on_tweet        = delete $args{on_tweet};
    my $on_error        = delete $args{on_error} || sub { die @_ };
    my $on_eof          = delete $args{on_eof} || sub { };
    my $on_keepalive    = delete $args{on_keepalive} || sub { };
    my $timeout         = delete $args{timeout};

    my $decode_json;
    unless (delete $args{no_decode_json}) {
        require JSON::XS;
        $decode_json = 1;
    }

    my $uri = URI->new("$PROTOCOL://$gnip_box_name.$STREAMING_SERVER/data_collectors/$collector_id/track.json");

    my $request_method = $REQ_METHOD;
    my $auth  = "Basic ".MIME::Base64::encode("$username:$password", '');

    my $self = bless {}, $class;

    {
        Scalar::Util::weaken(my $self = $self);

        my $set_timeout = $timeout
            ? sub { $self->{timeout} = AE::timer($timeout, 0, sub { $on_error->('timeout') }) }
            : sub {};

        my $json = JSON::XS->new->utf8(0);
        my $on_json_message = sub {
            my ($message) = @_;

            $set_timeout->();
            if ($message !~ /^\s*$/) {
                my $tweet = $decode_json ? $json->decode($message) : $message;
                $on_tweet->($tweet);
            }
            else {
                $on_keepalive->();
            }
        };

        $set_timeout->();

        my $cookie = {};
        $self->{connection_guard} = http_request(
            $request_method, $uri,
            headers => {
                Authorization => $auth,
            },
            cookie_jar => $cookie,
            on_header => sub {
                my($headers) = @_;
                if ($headers->{Status} ne '302') {
                    $on_error->("$headers->{Status}: $headers->{Reason}");
                    return;
                }
                return 1;
            },
            recurse => 0,
            sub {
                my ( $data, $header ) = @_;
                my $location = $header->{location};

                http_request(
                    $request_method, $location,
                    headers => {
                        Authorization => $auth,
                    },
                    cookie_jar => $cookie,
                    on_header => sub {
                        my($headers) = @_;
                        if ($headers->{Status} ne '200') {
                            $on_error->("$headers->{Status}: $headers->{Reason}");
                            return;
                        }
                        return 1;
                    },
                    want_body_handle => 1,
                    persistent => 1,
                    sub {
                        my ($handle, $headers) = @_;
                        return unless $handle;
                        
                        my $chunk_reader = sub {
                            my ($handle, $line) = @_;
                            
                            $line =~ /^([0-9a-fA-F]+)/ or die 'bad chunk (incorrect length)';
                            my $len = hex $1;

                            $handle->push_read(chunk => $len, sub {
                                my ($handle, $chunk) = @_;

                                $handle->push_read(line => sub {
                                    length $_[1] and die 'bad chunk (missing last empty line)';
                                });

                                $on_json_message->($chunk);
                            });
                        };
                        my $line_reader = sub {
                            my ($handle, $line) = @_;
                            $on_json_message->($line);
                        };
                        
                        $handle->on_error(sub {
                            undef $handle;
                            $on_error->( $_[2] );
                        } );
                        $handle->on_eof(sub {
                            undef $handle;
                            $on_eof->(@_);
                        });

                        if (($headers->{'transfer-encoding'} || '') =~ /\bchunked\b/i) {
                            $handle->on_read(sub {
                                my ($handle) = @_;
                                $handle->push_read(line => $chunk_reader);
                            });
                        } else {
                            $handle->on_read(sub {
                                my ($handle) = @_;
                                $handle->push_read(line => $line_reader);
                            });
                        }

                        $self->{guard} = AnyEvent::Util::guard {
                            $handle->destroy if $handle;
                        };

                        $on_connect->();
                    }
                );
            }
        );

    }

    return $self;
}

1;
