package AnyEvent::Gnip::Stream;

use strict;
use 5.008_001;
our $VERSION = '0.02';

use AnyEvent::HTTP;
use AnyEvent::Util;
use MIME::Base64;
use URI;
use URI::Escape;

our $REQ_METHOD = 'GET';

sub new {
    my $class = shift;
    my %args  = @_;

    # Stream params
    my $user    = delete $args{user};
    my $password   = delete $args{password};
    my $stream_url = delete $args{stream_url};

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

    my $compressed;
    if (delete $args{compression}) {
        use IO::Uncompress::Gunzip qw( gunzip $GunzipError );
        $compressed = 1;
    }

    my $uri = URI->new($stream_url);

    my $request_method = $REQ_METHOD;
    my $auth  = "Basic ".MIME::Base64::encode("$user:$password", '');

    my $self = bless {}, $class;

    {
        Scalar::Util::weaken(my $self = $self);

        my $set_timeout = $timeout
            ? sub { $self->{timeout} = AE::timer($timeout, 0, sub { $on_error->('timeout') }) }
            : sub {};

        my $unzip = sub {
            my $in = shift;
            my $out;
            gunzip( \$in => \$out ) or die "gunzip error: $GunzipError\n";
            $out;
        };


        my $json = JSON::XS->new->utf8(0);
        my $on_json_message = sub {
            my ($message) = @_;

            $message = $unzip->( $message ) if $compressed;
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

        my %head = ();
        $head{'Accept-Encoding'} = 'gzip' if $compressed;
        my $cookie = {};
        $self->{connection_guard} = http_request(
            $request_method, $uri,
            headers => {
                Authorization => $auth,
                %head,
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

                my $chunk_reader;
                $chunk_reader = sub {
                    my ( $handle, $line, $message ) = @_;

                    $message ||= '';
                    $line =~ /^([0-9a-fA-F]+)/ or die 'bad chunk (incorrect length)';
                    $handle->push_read( line => sub {
                        my ($handle, $chunk) = @_;
                        $message .= $chunk;
                        $handle->push_read(line => sub {
                            my ($handle, $chunk) = @_;
                            if(length $chunk) {
                                $chunk_reader->( $handle, $chunk, $message );
                            } else {
                                $on_json_message->($message);
                            }
                        });
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
    return $self;
}

1;
__END__

=encoding utf-8

=head1 NAME

AnyEvent::Gnip::Stream - Receive Gnip Power Track streaming API in an event loop

=head1 SYNOPSIS

    use AnyEvent::Gnip::Stream;

    # receive updates from Gnip Power Track
    my $done = AE::cv;
    my $listener = AnyEvent::Gnip::Stream->new(
        user     => $user,
        password    => $password,
        stream_url  => $stream_url,
        on_tweet    => sub {
            my $tweet = shift;
            print $tweet->{actor}->{preferredUsername}.": ".$tweet->{body}."\n";
        },
        on_error    => sub {
            warn shift."\n";
            $done->send;
        },
        on_connect  => sub {
            print "Stream started!\n";
        },
        on_eof      => sub {
            warn "EOF\n";
            $done->send;
        },
        on_keepalive => sub {
          warn "ping\n";
        },
        timeout => 60,
    );
    $done->recv;

=head1 DESCRIPTION

AnyEvent::Gnip::Stream is an AnyEvent user to receive Gnip Power Track streaming
API, available at L<http://docs.gnip.com/w/page/35663947/Power-Track> and
L<http://docs.gnip.com/w/page/37218164/Getting%20Started%20with%20Commercial%20Twitter%20Data>.

See L<eg/track.pl> for more client code example.

=head1 METHODS

=head2 my $streamer = AnyEvent::Gnip::Stream->new(%args);

=over 4

=item B<user> B<password>

These arguments are used for basic authentication.

=item B<stream_url>

URL of the Gnip collector to link to.

=item B<timeout>

Set the timeout value.

=item B<on_connect>

Callback to execute when a stream is connected.

=item B<on_tweet>

Callback to execute when a new tweet is received.

=item B<on_error>

Callback to execute when an error occurs.

=item B<on_eof>

=item B<on_keepalive>

=item B<no_decode_json>

Set this param to TRUE if you don't want to deserialize json input from the stream.

=back

=head1 NOTES

The API uses the HTTPS protocol. For this, you need to install the L<Net::SSLeay> module.

=head1 AUTHOR

Stéphane Raux E<lt>stephane.raux@linkfluence.netE<gt>

(Based on Tatsuhiko Miyagawa's L<AnyEvent::Twitter::Stream>)

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<AnyEvent::Twitter::Stream>

=cut
