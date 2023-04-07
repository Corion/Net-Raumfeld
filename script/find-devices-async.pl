#!perl
use 5.020;
use feature 'signatures';
no warnings 'experimental::signatures';
use Net::Async::UPnP;
use Net::Async::UPnP::ControlPoint;
use IO::Async::Loop;

use Try::Tiny;

my $loop = IO::Async::Loop->new;
my $search = Net::Async::UPnP::ControlPoint->new();

$search->on( device => sub( $search, $dev ) {
    #say $dev->description;
    say sprintf '%s (%s) at %s  UDN: %s', $dev->friendlyname, $dev->devicetype, $dev->location, $dev->udn;

    for my $s ($dev->services->@*) {
        say "+ " . sprintf '%s at %s', $s->type, $s->controlurl;
    };

    use Data::Dumper;
    my $s = $dev->service_by_name('urn:schemas-upnp-org:service:RenderingControl:1');
    if( $s ) {
        $s->subscribe( sub($dev, $evt) {
            warn Dumper $evt;
        })->retain;
        $s->postaction( "GetMute", { InstanceID => 0, Channel => 'Master' })->then(sub($res) {
            say Dumper( $res );
        })->retain;
        $s->postaction( "GetVolume", { InstanceID => 0, Channel => 'Master' })->then(sub( $res ) {
            say Dumper( $res );
            #$loop->stop;
        })->retain;
    };

});

$search->start_search(
    loop => $loop,
    #st => 'urn:schemas-upnp-org:device:MediaRenderer:1',
);

# $search->find_device( '' )->then(...)

$loop->run;
