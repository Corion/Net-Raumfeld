package Net::Async::UPnP;
use 5.020; # signatures
use feature 'signatures';
no warnings 'experimental::signatures';

our $VERSION = '0.01';

our $SSDP_ADDR = '239.255.255.250';
our $SSDP_PORT = 1900;

sub entity_decode( $r ) {
    # Fake-decode XML
    $r =~ s/\&gt;/>/g;
    $r =~ s/\&lt;/</g;
    $r =~ s/\&quot;/\"/g;
    $r =~ s/\&amp;/\&/g;
    return $r
}

package Net::Async::UPnP::ControlPoint;
use Moo 2;
use 5.020; # signatures
use feature 'signatures';
no warnings 'experimental::signatures';
use Try::Tiny;
use Carp 'croak';
use PerlX::Maybe;

use Socket 'pack_sockaddr_in', 'inet_aton'; # IPv6 support?!
use IO::Async::Socket;
use IO::Async::Timer::Periodic;
use Net::Async::HTTP;
use Net::Async::HTTP::Server; # for UPnP events
use HTTP::Request;
use HTTP::Response;
use Scalar::Util 'weaken';
use List::Util 'max';
use Net::Address::IP::Local;     # ipv6 ?
use XML::LibXML '1.170';

with 'MooX::Role::EventEmitter';

has 'found_devices' => (
    is => 'ro',
    default => sub { +{} },
);

has 'subscribed_services' => (
    is => 'ro',
    default => sub { +{} },
);

has 'socket' => (
    is => 'rw',
);

has 'ua' => (
    is => 'lazy',
    default => sub ($self) {
        Net::Async::HTTP->new();
    },
);

has 'loop' => (
    is => 'lazy',
    default => sub ($self) {
        IO::Async::Loop->new()
    },
);

has 'server' => (
    is => 'lazy',
    default => \&_launch_server,
);

has 'server_url' => (
    is => 'rw'
);

has 'timer' => (
    is => 'rw',
);

has 'xpc' => (
    is => 'lazy',
    default => sub($s) {
        my $xpc = XML::LibXML::XPathContext->new;
        $xpc->registerNs('dev', 'urn:schemas-upnp-org:device-1-0');
        $xpc->registerNs('ev', 'urn:schemas-upnp-org:event-1-0');
        $xpc->registerNs('meta', 'urn:schemas-upnp-org:metadata-1-0/RCS/');
        return $xpc;
    },
);

has 'urlbase' => (
    is => 'rw',
);

sub _launch_server( $self ) {
    weaken( my $s = $self );

    # pre-bake our response
    my $response = HTTP::Response->new(200, 'OK',
        [ 'Content-Length' => 0,
          'Connection' => 'keep-alive',
          'Content-Type' => 'text/plain',
        ]
    );

    my $srv = Net::Async::HTTP::Server->new(
        on_request => sub( $server, $req ) {
            $s->on_event($req);
            $req->respond( $response );
            # If the client can't keep the connection open, free some resources
            if( $req->header('Connection') // 'close' eq 'close' ) {
                $req->stream->close;
            };
        },
    );
    $self->loop->add($srv);

    my $addr = Net::Address::IP::Local->public;
    return $srv->listen( addr => { family => "inet", socktype => "stream" })
    ->then( sub( $listener ) {
        my $url = sprintf 'http://%s:%s/', $addr, $srv->read_handle->sockport;
        $self->server_url( $url );
        return Future->done( $self )
    });
}

sub response_url( $self, $service ) {
    if( ! $self->server_url ) {
        croak "->response_url called before server was ready!";
    };
    my $res = URI->new( $self->server_url );
    #$res->query_form( id => $service->id );
    return $res
}

sub send_subscribe( $self, %args ) {
    my $url = delete $args{url};
    my $timeout = delete $args{timeout} // 300;
    my $event_url = delete $args{callback};
    my @identifier = $args{sid}
                   ? (SID      => delete $args{sid})
                   : (CALLBACK => "<$event_url>",
                      NT       => 'upnp:event',
                     )
                   ;
    return $self->ua->do_request(
        method => 'SUBSCRIBE',
        uri => $url,
        headers => {
            @identifier,
            TIMEOUT      => "Second-$timeout",
            'Connection' => 'keep-alive', # at least offer it to the device
        },
    )
}

sub subscribe_service( $self, %args ) {
    my $service = delete $args{ service } or croak "No service given";
    my $cb      = delete $args{ cb } or croak "No callback given!";

    my $id = $service->id;
    my $subscribed = grep { $_->{service}->id eq $id } values %{ $self->subscribed_services };

    # we should maybe also have a status "subscribing", to prevent overlapping
    # subscription requests...
    if( ! $subscribed ) {
        weaken( my $s = $self );
        return $self->server->then(sub ($srv) {
            my $event_url = $self->response_url($self);
            my $url = $service->eventsuburl;
            return $s->send_subscribe(
                url => $url,
                callback => $event_url,
            )->then( sub( $res, @args ) {
                my $sid = $res->headers->header('SID');
                my $timeout = $res->headers->header('TIMEOUT');
                $timeout =~ s!\D!!g;

                # Install our renewal timer
                my $timer = IO::Async::Timer::Periodic->new(
                    reschedule => 'drift',
                    interval => max( $timeout - 30, 30 ),
                    on_tick => sub {
                        $s->send_subscribe(
                            url     => $url,
                            sid     => $sid,
                            timeout => $timeout,
                        )->retain;
                    },
                );
                $timer->start();
                $s->loop->add($timer);
                $s->subscribed_services->{ $sid } = {
                    service => $service,
                    sid     => $sid,
                    refresh => $timer,
                };
                # Maybe leave the redistribution of events to the service?!
                $s->on("event_".$sid => sub( $cp, @args ) { $cb->(@args) } );
                return Future->done($service);
            });
        })->catch(sub {
            use Data::Dumper;
            warn Dumper \@_;
        });
    } else {
        return Future->done( $service )
    }
}

sub on_event( $self, $req ) {
    #use Data::Dumper; warn Dumper [$req->headers];
    my $session_id = $req->header('sid') or return;
    my $service = $self->subscribed_services->{$session_id}->{service}
        or return;

    my @res;
    my $b = $req->body;
    my $d = XML::LibXML->load_xml( string => $b );
    my $lastChange = $self->xpc->findnodes( '//LastChange', $d );

    if( $lastChange->size ) {
        my $payload = Net::Async::UPnP::entity_decode( $lastChange->shift->textContent );
        my $p = XML::LibXML->load_xml( string => $payload );
        my %instance;

        for my $instance ( $self->xpc->findnodes( '//meta:InstanceID', $p )) {
            $instance{ InstanceID } = $instance->getAttribute('val');

            for my $change ($self->xpc->findnodes( './/*', $instance )) {

                for my $attr ($change->attributes()) {
                    my $name = $attr->nodeName;
                    if( $name eq 'val') { $name = $change->nodeName };
                    $instance{ $name } = $attr->nodeValue();
                }
            }
        }

        push @res, \%instance;

    } elsif( $self->xpc->findnodes('//ev:property', $d)->size ) {
        my $prop = $self->xpc->findnodes('//ev:property', $d);
        for my $props ($prop->get_nodelist) {
            warn $props->toString;
            $props = $props->toString;
            while( $props =~ m!<(?:\w+:)?(\w+)>(.*?)</(?:\w+:)\1>!g ) {
                push @res, [ $1 => $2 ];
            }
        }
    } else {
        warn "Unparsed event $b";
        return
    }

    # Notify all listeners
    $self->emit("event_" .$session_id, $service, \@res);
}

sub start_search( $self, %options ) {
    my $on_device = delete $options{ on_new_device };
    $options{ st } //= 'upnp:rootdevice';
    $options{ mx } //= 3; # do we want
    $options{ loop } //= $self->loop;

    $options{ host } //= $Net::Async::UPnP::SSDP_ADDR;
    $options{ port } //= $Net::Async::UPnP::SSDP_PORT;

    $options{ loop }->add( $self->ua );

    my $pingback = IO::Async::Socket->new(
        on_recv => sub( $sock, $data, $addr, @rest ) {
            my $res = HTTP::Response->parse( $data );
            my $loc = $res->headers->header('Location');
            if( ! $loc) {
                return
            } else {
                my $url = URI->new( $loc );
                if( ! $self->found_devices->{$url}) {
                    $self->ua->do_request(
                        uri => $loc
                    )->then(sub( $res ) {
                        return
                            if $self->found_devices->{$url};

                        my $body = $res->decoded_content;
                        # Yah, extract this before parsing the XML, this attribute
                        # is deprecated in UPnP 1.1 anyway:
                        my $urlbase;
                        if( $body =~ m!<((?:\w+:)?URLBase)>([^<]+)</\1>!sm ) {
                            $urlbase = $2;
                        }
                        my $dev = Net::Async::UPnP::Device->new(
                                  controlpoint => $self,
                                  ua           => $self->ua,
                                  ssdp         => $data,
                                  description  => $body,
                                  location     => $loc,
                            maybe urlbase      => $urlbase,
                        );
                        $self->found_devices->{$url} = $dev;
                        return if $self->found_devices->{$dev->udn};

                        $self->found_devices->{$dev->udn} = $dev;

                        try {
                            $self->emit( 'device' => $dev );
                        } catch {
                            warn "Callback raised error: $_";
                        };
                    })->retain;
                };
            }
        },
        on_recv_error => sub {
           my ( $self, $errno ) = @_;
           die "Cannot recv - $errno\n";
        },
    );
    $self->socket( $pingback );
    $options{ loop }->add( $pingback );
    # What about multihomed hosts?!
    $pingback->bind(
        service => $options{ port },
        #host => $options{ host },
        socktype => 'dgram'
    )->get;

    weaken(my $s = $self);
    my $timer = IO::Async::Timer::Periodic->new(
        reschedule => 'skip',
        first_interval => 0,
        interval => $options{ mx } + 30,
        on_tick => sub {
            $s->send_search( $pingback, $options{ host }, $options{ port }, $options{ st }, $options{ mx });
        },
    );
    $self->timer( $timer );
    $timer->start;
    $options{ loop }->add( $timer );
}

sub send_search( $self, $socket, $host, $port, $st, $mx ) {
    my $req = HTTP::Request->new(
        'M-SEARCH' => '*',
        [ ST => $st,
          MX => $mx,
          Man => '"ssdp:discover"',
          Host => join ":", $host, $port,
        ],
    );
    $req->protocol('HTTP/1.1');

    my $addr = pack_sockaddr_in $port, inet_aton( $host );

    my $data = $req->as_string;
    $data =~ s!\n!\r\n!g;
    $socket->send( $data, 0, $addr );
}

sub stop_search( $self, %options ) {
    $self->socket->close;
    $self->socket( undef );
}

package Net::Async::UPnP::Device;
use Moo 2;
use 5.020; # signatures
use feature 'signatures';
no warnings 'experimental::signatures';

use URI;
use XML::LibXML '1.170';

has 'ua' => (
    is => 'ro',
    weak_ref => 1,
    default => sub ($self) {
        Net::Async::HTTP->new();
    },
);

has 'urlbase' => (
    is => 'ro',
);

has 'controlpoint' => (
    is => 'ro',
    weak_ref => 1,
);

has 'ssdp' => (
    is => 'ro',
);

has 'description' => (
    is => 'ro',
);

has 'location' => (
    is => 'ro',
);

has 'devicetype' => (
    is => 'lazy',
    default => sub($s) { $s->get_attribute('deviceType');},
);

has 'manufacturer' => (
    is => 'lazy',
    default => sub($s) { $s->get_attribute('manufacturer');},
);

has 'friendlyname' => (
    is => 'lazy',
    default => sub($s) { $s->get_attribute('friendlyName');},
);

has 'udn' => (
    is => 'lazy',
    default => sub($s) { $s->get_attribute('UDN');},
);

has 'services' => (
    is => 'lazy',
    default => \&_parse_services,
);

around BUILDARGS => sub( $orig, $class, %args ) {
    if( exists $args{ description } and ! ref $args{ description } ) {
        $args{ description } = XML::LibXML->load_xml( string => $args{ description } );
    };
    return $class->$orig(%args)
};

has 'xpc' => (
    is => 'lazy',
    default => sub($s) {
        my $xpc = XML::LibXML::XPathContext->new;
        $xpc->registerNs('dev', 'urn:schemas-upnp-org:device-1-0');
        $xpc->registerNs('ev', 'urn:schemas-upnp-org:event-1-0');
        return $xpc;
    },
);

sub get_attribute( $self, $attr ) {
    my @res = $self->xpc->findnodes( "//dev:$attr", $self->description )->get_nodelist;

    if( @res ) {
        return $res[0]->textContent
    } else {
        return
    }
}

sub _parse_services( $self, $description = $self->description ) {
    my @services = $self->xpc->findnodes( '//dev:serviceList/dev:service', $self->description );
    @services = map {
        Net::Async::UPnP::Service->new(
            device       => $self,
            description  => $_,
            controlpoint => $self->controlpoint,
        );
    } @services;
    return \@services;
}

sub service_by_name( $self, $name ) {
    foreach my $s ($self->services->@*) {
        return $s if $s->type eq $name
    }
    return ()
}

package Net::Async::UPnP::Service;
use Moo 2;
use 5.020; # signatures
use feature 'signatures';
no warnings 'experimental::signatures';
use URI;
use Carp 'croak';
use Encode 'encode';

around BUILDARGS => sub( $orig, $class, %args ) {
    if( exists $args{ description } and ! ref $args{ description } ) {
        $args{ description } = XML::LibXML->load_xml( string => $args{ description } );
    };
    return $class->$orig(%args)
};

has 'controlpoint' => (
    is => 'ro',
    weak_ref => 1,
);

has 'xpc' => (
    is => 'lazy',
    default => sub($s) {
        my $xpc = XML::LibXML::XPathContext->new;
        $xpc->registerNs('dev', 'urn:schemas-upnp-org:device-1-0');
        $xpc->registerNs('ev', 'urn:schemas-upnp-org:event-1-0');
        return $xpc;
    },
);

has 'description' => (
    is => 'ro',
);

has 'device' => (
    is => 'ro',
    weak_ref => 1,
);

has 'eventsuburl' => (
    is => 'lazy',
    default => sub($s) {
        my $base = $s->device->urlbase || $s->device->location;
        URI->new_abs( $s->get_attribute( 'eventSubURL' ), $base )
    }
);

has 'id' => (
    is => 'lazy',
    default => sub($s) { $s->device->udn . ":" . $s->type },
);

sub get_attribute( $self, $attr ) {
    my @res = $self->xpc->findnodes( "//dev:$attr", $self->description )->get_nodelist;

    if( @res ) {
        return $res[0]->textContent
    } else {
        return
    }
}

has 'type' => (
    is => 'lazy',
    default => sub($s) { $s->get_attribute('serviceType') },
);

has 'controlurl' => (
    is => 'lazy',
    default => sub($s) {
        my $base = $s->device->urlbase || $s->device->location;
        URI->new_abs( $s->get_attribute( 'controlURL' ), $base )
    }
);

# I've looked at SOAP::Serializer and XML::Compile::SOAP, and wept
sub _soap_xml( $self, $action_name,$args ) {
    $action_name or croak "Need an action_name";
    my $service_type = delete $args->{ service_type } // $self->type or croak "Need a service_type";
    my $res = <<"SOAP_CONTENT";
<?xml version="1.0" encoding="utf-8\"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:$action_name xmlns:u="$service_type">
SOAP_CONTENT

	if (ref $args) {
		while (my ($arg_name, $arg_value) = each (%{$args} ) ) {
			if (length($arg_value) <= 0) {
				$res .= encode('UTF-8', "<$arg_name />\n");
			} else {
                $res .= encode('UTF-8', "<$arg_name>$arg_value</$arg_name>\n");
            }
		}
	}

    $res .= <<"SOAP_CONTENT";
</u:$action_name>
</s:Body>
</s:Envelope>
SOAP_CONTENT

    return $res
}

sub _parse_soap_response( $self, $action, $body ) {
}

sub postaction( $self, $action_name, $args ) {
    my $loc = $self->controlurl;
    $action_name or croak "Need an action_name";
    my $soap = $self->_soap_xml($action_name, $args);
    my $ua = $self->device->ua;
    my $type = $self->type;

    $ua->do_request(
        uri => $loc,
        headers => {
            SOAPACTION => "$type#$action_name",
        },
        content_type => 'text/xml; charset="utf-8"',
        content => $soap,
        method => 'POST',
    )->then( sub( $res ) {
        # decode the SOAP response maybe?!
        if( $res->code == 200 ) {
            my $body = $res->decoded_content;
            $body =~ m!<(?:\w+:)?${action_name}Response[^>]*>(.*?)</(?:\w+:)?${action_name}Response>!
                or return Future->fail(xmlerror => 500, "Invalid XML:\n". $body);
            my $res = $1;
            my %results;
            while( $res =~ m!<((?:\w+:)?(\w+))(?:[^>]*)>([^<]*)</\1>!sg ) {
                my $name = $2;
                my $r = $3;
                $r = Net::Async::UPnP::entity_decode( $r );
                $results{ $name } = $r;
            }
            Future->done( \%results )
        } else {
            warn $res->code;
            Future->fail( error => $res->code, $res->decoded_content )
        }
    });
}

sub subscribe( $self, $cb ) {
    return $self->controlpoint->subscribe_service(
        service => $self,
        cb => $cb
    );
}

# There is no unsubscribe yet

1;
