#!perl
use 5.020;
use feature 'signatures';
no warnings 'experimental::signatures';

use Net::UPnP;
use Net::UPnP::ControlPoint;

my $obj = Net::UPnP::ControlPoint->new();

#my @dev_list = $obj->search(st =>'urn:schemas-raumfeld-com:device:ConfigDevice:1', mx => 5);
#my @dev_list = $obj->search(st => 'upnp:rootdevice', mx => 3);
#my @dev_list = $obj->search(st => 'urn:schemas-raumfeld-com:device:RaumfeldDevice:1', mx => 3);
my @dev_list = $obj->search(st => 'urn:schemas-upnp-org:device:MediaRenderer:1', mx => 3);

use Data::Dumper;

say sprintf "%d devices", scalar @dev_list;
for my $d (@dev_list) {
    warn Dumper $d;
    say "Device: " . $d->getdevicetype . " - " . $d->getfriendlyname;

    if( my $event_url = $d->getdescription(name => 'eventSubURL') ) {
        say Dumper(subscribe( $d, 'http://192.168.1.23:1234' ));
    }

    for my $s ($d->getservicelist()) {
        my $type = $s->getdevicedescription(name => 'ServiceType');
        say "--- service";
        say "Type:\t$type",
        say "URL:\t\t".$s->getcontrolurl;
        say "POST:\t\t".$s->getposturl;

        if( $type eq 'urn:schemas-upnp-org:service:RenderingControl:1') {
            #my $msg = "GetDeviceSetting";
            #my $setting = "Volume";
            #my $res = $s->postaction($msg, { InstanceID => 0, "Name" => $setting });
            #if( (my $error) = ($res->getcontent =~ m!<errorDescription>([^<]+)</errorDescription>!)) {
            #    say "$msg - $error ('$setting')"
            #} else {
            #    say Dumper $res;
            #};

            #say action( $s, "SetDeviceSetting", "Name" => "Source Select", Value => "LineIn" )->getstatuscode;
            #say action( $s, "SetDeviceSetting", "Name" => "Source Select", Value => "BlueTooth" );
            #say action( $s, "SetDeviceSetting", "Name" => "Source Select", Value => "LineIn" );

        #say Dumper( action( $s, "SetRoomMute", value => 1 ));
            say Dumper( action( $s, "GetMute", InstanceID => 0, Channel => 'Master' ));
            #say Dumper( action( $s, "GetVolume", InstanceID => 11, Channel => 'Master' ));
            #say Dumper( action( $s, "SetMute", InstanceID => 0, Channel => 'Master', DesiredMute => 0 ));
        } else {
        }
        say "---";
    }
}
exit;

use Data::Dumper;
list_info($dev_list[0]);

sub subscribe( $dev, $event_url ) {
    my $ua = HTTP::Tiny->new();
    use URI::WithBase;
    my $base = $dev->getlocation;
    warn "Base:  $base";
    warn "Event: " . $dev->getdescription(name => 'eventSubURL');
    my $url = URI->new_abs( $dev->getdescription(name => 'eventSubURL'), $base );
    warn $url;
    return $ua->request('SUBSCRIBE', $url, {
        headers => {
            CALLBACK => "<$event_url>",
            NT => 'upnp:event',
            TIMEOUT => 'Second-300',
        },
    });
}

sub action($svc, $name, %args) {
    use HTTP::Tiny;
    use URI;
    #my $url = URI->new($dev->getlocation);
    #$url = "http://" . $url->host_port;
    #return HTTP::Tiny->new->get("$url/${loc}", {
    #    headers => {
    #        updateID => 'x',
    #        Prefer => 'wait=1',
    #    },
    #});


    $svc->postaction( $name, \%args );
}

sub fetch($dev, $loc) {
    use HTTP::Tiny;
    use URI;
    my $url = URI->new($dev->getlocation);
    # $url =~ s!\.xml!!;
    $url = "http://" . $url->host_port;
    return HTTP::Tiny->new->get("$url/${loc}", {
        headers => {
            updateID => 'x',
            Prefer => 'wait=1',
        },
    });
}

sub list_info($dev) {
    my $session = 1; # XXX well, some random string, later


    say Dumper fetch( $dev, "listDevices" );
    say Dumper fetch( $dev, "getHostInfo" );
    say Dumper fetch( $dev, "getZones" );
    say Dumper fetch( $dev, "loadLineIn" );
}

package Net::Raumfeld::Device {
    use Moo 2;
    use feature 'signatures';
    no warnings 'experimental::signatures';
    use XML::Simple 'XMLin';

    #has 'fff' => (
    #);

    sub from_upnp( $class, $device ) {
        my $info = XMLin( $device->fff, ForceArray => 1 );
        $class->new();
    }
}
