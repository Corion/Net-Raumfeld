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
        #$s->postaction( "GetMute", { InstanceID => 0, Channel => 'Master' })->then(sub($res) {
        #    say Dumper( $res );
        #})->retain;
        #$s->postaction( "GetVolume", { InstanceID => 0, Channel => 'Master' })->then(sub( $res ) {
        #    say Dumper( $res );
        #    #$loop->stop;
        #})->retain;
        #$s->postaction( "GetLineInStreamURL", { InstanceID => 0 })->then(sub( $res ) {
        #    say Dumper( $res );
        #})->retain;
        #$s->postaction( "GetFilter", { InstanceID => 0 })->then(sub( $res ) {
        #    say Dumper( $res );
        #})->retain;
        #$s->postaction( "SetVolume", { InstanceID => 0, Channel => 'Master' })->then(sub( $res ) {
        #    say Dumper( $res );
        #    #$loop->stop;
        #})->retain;
        #$s->postaction( "PlaySystemSound", { Sound => 'Success' })->then(sub( $res ) {
        #$s->postaction( "PlaySystemSound", { Sound => 'Failure' })->then(sub( $res ) {
        #    say Dumper( $res );
        #})->retain;
        #$s->postaction( "GetPowerState", { InstanceID => 0 })->then(sub( $res ) {
        #    say Dumper( $res );
        #    #$loop->stop;
        #})->retain;
    };

    my $s = $dev->service_by_name('urn:schemas-upnp-org:service:AVTransport:1');
    if( $s ) {
        $s->subscribe( sub($dev, $evt) {
            warn Dumper $evt;
        })->retain;
        #$s->postaction( "GetPowerState", { InstanceID => 0 })->then(sub($res) {
        #    say Dumper( $res );
        #})->retain;
        #$s->postaction( "EnterManualStandby", { InstanceID => 0 })->then(sub($res) {
        #    say Dumper( $res );
        #})->retain;
        #$s->postaction( "LeaveStandby", { InstanceID => 0 })->then(sub($res) {
        #    say Dumper( $res );
        #})->retain;

if(0) {
        #my $playlist = 'http://ice3.somafm.com:80/groovesalad-64-aac';
        my $playlist = 'http://live.hkstv.hk.lxdns.com/live/hks/playlist.m3u8';
        $s->postaction( "SetAVTransportURI", {
            InstanceID => 1,
            CurrentURIMetaData => '',
            CurrentURI => $playlist }
        )->then(sub($res) {
            say Dumper( $res );
            return $s->postaction( "Play", {
                InstanceID => 1,
                Speed => 1,
            });
        })->then(sub($res) {
            say "(playing?)";
            say Dumper $res;
            if( $res !~ /Buffered/ ) {
                say Dumper( $res );
                Future->fail(error => $res);
            } else {
                Future->done();
            };
        })->retain;
}
    }

});

$search->start_search(
    loop => $loop,
    #st => 'urn:schemas-upnp-org:device:MediaRenderer:1',
);

# $search->find_device( '' )->then(...)

$loop->run;
