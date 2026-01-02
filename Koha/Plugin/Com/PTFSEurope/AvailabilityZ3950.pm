package Koha::Plugin::Com::PTFSEurope::AvailabilityZ3950;

use Modern::Perl;

use base qw( Koha::Plugins::Base );
use Koha::DateUtils qw( dt_from_string );
use Koha::Database;
use C4::Breeding qw( Z3950Search );
use Koha::Plugin::Com::PTFSEurope::AvailabilityZ3950::Api;

use Cwd qw( abs_path );
use CGI;
use LWP::UserAgent;
use HTTP::Request;
use JSON qw( encode_json decode_json );
use Digest::MD5 qw( md5_hex );
use MIME::Base64 qw( decode_base64 );
use URI::Escape qw ( uri_unescape );

our $VERSION = "1.1.0";

our $metadata = {
    name            => 'ILL availability - z39.50',
    author          => 'Open Fifth',
    date_authored   => '2019-06-24',
    date_updated    => '2026-01-02',
    minimum_version => '24.05.00.000',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'This plugin provides ILL availability searching for z39.50 targets'
};

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    $self->{schema} = Koha::Database->new()->schema();
    $self->{config} = decode_json($self->retrieve_data('avail_config') || '{}');

    return $self;
}

# Recieve a hashref containing the submitted metadata
# and, if we can work with it, return a hashref of our service definition
sub ill_availability_services {
    my ($self, $params) = @_;

    # A list of metadata properties we're interested in
    # NOTE: This list needs to be kept in sync with a similar list in
    # Api.pm
    my $properties = [
        'isbn',
        'issn',
        'container_title',
        'container_author',
        'title',
        'author'
    ];
    
    # Ensure we're working with predictable metadata property keys
    my $metadata = $params->{metadata};
    my %lookup = map {(
        lc $_, $metadata->{$_}
    )} keys %{$metadata};

    # Establish if we can service this item
    my $can_service = 0;
    foreach my $property(@{$properties}) {
        if ( $lookup{$property} && length $lookup{$property} > 0 ) {
            $can_service++;
        }
    }

    # Check we have at least one Z target we can use
    my $ids = $self->get_available_z_target_ids($params->{ui_context});

    # Bail out if we can't do anything with this request
    return 0 if scalar @{$ids} == 0;

    my $endpoint = '/api/v1/contrib/' . $self->api_namespace .
        '/ill_availability_search_z3950?ui_context=' .
        $params->{ui_context} . '&metadata=';

    # We need an array of partner IDs that are enabled
    my $partner_ids = [];
    foreach my $id(@{$ids}) {
        my $partner_id = $self->get_partner_id($id);
        push @{$partner_ids}, $partner_id if $partner_id;
    }

    return {
        # Our service should have a reasonably unique ID
        # to differentiate it from other service that might be in use
        id => md5_hex(
            $self->{metadata}->{name}.$self->{metadata}->{version}
        ),
        plugin     => $self->{metadata}->{name},
        endpoint   => $endpoint,
        name       => $self->get_name(),
        enabled    => $partner_ids,
        datatablesConfig => {
            serverSide   => 'true',
            processing   => 'true',
            pagingType   => 'simple',
            info         => 'false',
            lengthChange => 'false',
            ordering     => 'false',
            searching    => 'false'
        }
    };
}

# Return our name
sub get_name {
    my ($self) = @_;
    return $self->{config}->{ill_avail_z3950_name} || 'z30.50';
};

sub get_available_z_target_ids {
    my ($self, $ui_context) = @_;

    # Receive a display context and iterate through the plugin's config
    # looking for targets that have been both selected and enabled in
    # this context
    my $config = $self->{config};
    my %id_hash = ();
    foreach my $key(%{$config}) {
        if (
            $key=~/^target_select_/ ||
            $key=~/^ill_avail_config_display_${ui_context}_/
        ) {
            $id_hash{$config->{$key}}++;
        }
    }
    my @id_arr = map { $id_hash{$_} == 2 ? $_ : () } keys %id_hash;
    return \@id_arr;
}

sub get_partner_id {
    my ($self, $target_id) = @_;

    # For a given target ID, return the associated partner ID
    # may be undef if one is not specified
    my $config = $self->{config};
    my $key = "ill_avail_config_partners_$target_id";
    return $config->{$key} if $config->{$key};
}

sub api_routes {
    my ($self, $args) = @_;

    my $spec_str = $self->mbf_read('openapi.json');
    my $spec = decode_json($spec_str);

    return $spec;
}

sub api_namespace {
    my ($self) = @_;

    return 'ill_availability_z3950';
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {

        my $template = $self->get_template({ file => 'configure.tt' });
        $template->param(
            targets => scalar Koha::Plugin::Com::PTFSEurope::AvailabilityZ3950::Api::get_z_targets(),
            config => scalar $self->{config}
        );

        $self->output_html( $template->output() );
    }
    else {
		my %blacklist = ('save' => 1, 'class' => 1, 'method' => 1);
        my $hashed = { map { $_ => (scalar $cgi->param($_))[0] } $cgi->param };
        my $p = {};
		foreach my $key (keys %{$hashed}) {
           if (!exists $blacklist{$key}) {
               $p->{$key} = $hashed->{$key};
           }
		}
        $self->store_data({ avail_config => scalar encode_json($p) });
        print $cgi->redirect(-url => '/cgi-bin/koha/plugins/run.pl?class=Koha::Plugin::Com::PTFSEurope::AvailabilityZ3950&method=configure');
        exit;
    }
}

sub install() {
    return 1;
}

sub upgrade {
    my ( $self, $args ) = @_;

    my $dt = dt_from_string();
    $self->store_data(
        { last_upgraded => $dt->ymd('-') . ' ' . $dt->hms(':') }
    );

    return 1;
}

sub uninstall() {
    return 1;
}

1;
