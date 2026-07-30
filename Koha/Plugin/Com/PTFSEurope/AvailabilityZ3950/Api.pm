package Koha::Plugin::Com::PTFSEurope::AvailabilityZ3950::Api;

 # This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Modern::Perl;

use JSON qw( decode_json );
use MIME::Base64 qw( decode_base64 );
use URI::Escape qw ( uri_unescape );
use List::Util qw ( any );
use POSIX;

use Mojo::Base 'Mojolicious::Controller';
use C4::Context;
use C4::Breeding qw( Z3950Search );
use Koha::Biblio;
use Koha::Database;
use Koha::Plugin::Com::PTFSEurope::AvailabilityZ3950;

sub search {

    # Validate what we've received
    my $c = shift->openapi->valid_input or return;

    # Gather together what we've been passed
    my $metadata    = $c->validation->param('metadata') || '';
    my $ui_context  = $c->validation->param('ui_context') || '';
    my $partners    = $c->validation->param('restrict') || '';
    my $start       = $c->validation->param('start') || 0;
    my $pageLength  = $c->validation->param('pageLength') || 20;
    $metadata       = decode_json(decode_base64(uri_unescape($metadata)));

    # Get details of the servers we could potentially be using
    # i.e. those that have been selected in the plugin config
    # We also get the config for later lookups
    my $plugin = Koha::Plugin::Com::PTFSEurope::AvailabilityZ3950->new();
    my $available_targets = $plugin->get_available_z_target_ids($ui_context);
    my $config = $plugin->retrieve_data('avail_config');
    $config = $config ? decode_json($config) : {};

    # Now we have the IDs of all targets we can potentially use,
    # we might want to limit down by parters IDs we've been passed
    # (which may have a target associated with them)
    my @passed_partners = split(/\|/, $partners);
    # Any values we've been passed are borrower IDs, we need to look up
    # the corresponding target ID, if there is one. This mapping is
    # defined in the plugin config.
    my @targets_to_search = ();
    if (scalar @passed_partners > 0) {
        # Iterate the targets that are available to us
        foreach my $available_target(@{$available_targets}) {
            my $config_key = "ill_avail_config_partners_$available_target";
            # Check if the config contains a partner mapping for this target
            if (
                # If this is a key defining a mapping to a partner ID
                # and the value is in the list of partner IDs
                # we've been passed
                $config->{$config_key} &&
                any { /$config->{$config_key}/ } @passed_partners
            ) {
                # We can search it
                push @targets_to_search, $available_target;
            }
        }
    } else {
        # We weren't passed any partners, so we just use all targets
        # available according to the plugin config
        @targets_to_search = @{$available_targets};
    }

    # Now get the full details of each target
    my $servers = get_z_targets(\@targets_to_search);

    # Try and calculate what page we're on
    my $page = $start == 0 ? 1 : floor($start / $pageLength) + 1;

    # The parameters we're going to use for Z searching
    my $pars= {
        biblionumber => 0,
        id           => \@targets_to_search,
        page         => $page,
    };

    # Ensure we're using predictable metadata property names
    my %lookup = map {(lc $_, $metadata->{$_})} keys %{$metadata};

    # Based on the metadata we've been passed, establish what gives us the
    # best chance of success.
    # NOTE: This logic needs to be kept in sync with a list of properties
    # in AvailabilityZ3950.pm
    if ($lookup{isbn} || $lookup{issn}) {
        if ($lookup{isbn}) {
            $pars->{isbn} = $lookup{isbn};
        } elsif ($lookup{issn}) {
            $pars->{issn} = $lookup{issn};
        }
    } elsif (
        $lookup{title} ||
        $lookup{container_title} ||
        $lookup{container_author} ||
        $lookup{author}
    ) {
        $pars->{title} = $lookup{container_title} || $lookup{title}
            if $lookup{container_title} || $lookup{title};
        $pars->{author} = $lookup{container_author} || $lookup{author}
            if $lookup{container_author} || $lookup{author};
    } else {
        return $c->render(
            status => 200,
            openapi => {
                results => {
                    search_results => [],
                    errors => [ { message => 'No usable metadata' } ]
                }
            }
        );
    }

    # C4::Breeding::Z3950Search expects to be passed a template (into the
    # params of which it inserts the response details), so we mock on
    my $template = MockTemplate->new;

    # Do the search
    Z3950Search($pars, $template);

    my $results = $template->param('breeding_loop') || [];
    my $errors = $template->param('errconn') || [];

    my $to_send = [];

    # Parse the Z response and prepare our response
    foreach my $result(@{$results}) {
        # Try and populate a 'source_record_id' field in each result
        # with each target's configured bib id field (if available)
        get_result_id($result, $servers, $config);
        # Now we try and populate a 'source_record_url' field in each result
        get_result_url($result, $servers, $config);
        # Now we try and populate an 'opac_url' field in each result
        get_opac_url($result, $servers, $config);
        # Determine if we should return this result in the OPAC
        my $hidden = $ui_context eq 'opac' && bib_hidden_in_opac(
            $result,
            $servers,
            $config
        );
        if (!$hidden) {
            push @{$to_send}, {
                title  => $result->{title},
                author => $result->{author},
                url    => $result->{url},
                opac_url => $result->{opac_url},
                isbn   => $result->{isbn},
                issn   => $result->{issn},
                source => $result->{server},
                date   => $result->{date}
            };
        }
    }

    my $return_hashref = {
        # We can't return the pagination information that DataTables expects
        # since this information isn't made available to us in any form
        # from Breeding.pm. The javascript that receives this response
        # will compensate for the lack of paging info
        search_results => $to_send,
        errors         => $errors
    };

    return $c->render(
        status => 200,
        openapi => { results => $return_hashref }
    );
}

# Given a result, get the ID of the corresponding server
sub get_server_id {
    my ( $result, $servers ) = @_;
    # First identify the server based on it's name in the result
    my $server_name = $result->{server};
    my ($server) = grep { $_->servername eq $server_name } @{$servers};
    return $server->id;
}

# Given a result, using the result's target config try and get the
# source's bib id and add it to the result
sub get_result_id {
    my ( $result, $servers, $config ) = @_;
    my $server_id = get_server_id($result, $servers);
    my $bib_field = $config->{"ill_avail_config_bibid_${server_id}"};
    if ($bib_field) {
        my ( $tag, $subfield ) = split( /\$/, $bib_field );
        my $bib_id = $result->{$tag};
        if ($bib_id) {
            $bib_id = ref $bib_id eq 'ARRAY' ? ${$bib_id}[0] : $bib_id;
            $bib_id =~ s/^\[\Q$subfield\E\]// if $subfield;
            $bib_id=~s/^\s+|\s+$//g;
            $result->{source_record_id} = $bib_id;
        }
    }
    return $result;
}

# Only applies to Koha targets
#
# Given a result, determine if this item should be removed from the results
# based on Koha's OpacHiddenItems syspref. If all this bib's results are
# hidden, don't return this result
# This function is in part a copy/paste from 19.11 Koha::Biblio::hidden_in_opac
# so we can retain < 19.11 compatibility
sub bib_hidden_in_opac {
    my ( $result, $servers, $config ) = @_;
    # First determine if this server needs results suppressing
    my $server_id = get_server_id($result, $servers);
    my $suppress = $config->{"ill_avail_config_suppress_${server_id}"};
    # Now get the suppression rules
    my $rules = {};
    eval {
        my $yaml = C4::Context->preference('OpacHiddenItems') . "\n\n";
        $rules = YAML::Load($yaml);
    };
    if ($suppress && $result->{source_record_id}) {
        # Return if this biblio should be provided in search results
        my $biblio = Koha::Biblios->find( $result->{source_record_id} );
        if (!$biblio) {
            return 0;
        }

		my @items = $biblio->items->as_list;
		return 0 unless @items;

        return !(any { !item_hidden_in_opac({ rules => $rules, item => $_ }) } @items);
    } else {
        # Either we are not suppressing or this biblio doesn't have a
        # biblionumber, so we should return it
        return 0;
    }
}

# Only applies to Koha targets
#
# Given an item, determine if this item should be removed from the results
# This function is essentially a copy/paste from 19.11 Koha::Item::hidden_in_opac
# so we can retain < 19.11 compatibility
sub item_hidden_in_opac {
	my ( $params ) = @_;

	my $rules = $params->{rules} // {};
	my $item = $params->{item};

	return 1
	if C4::Context->preference('hidelostitems') and
		$item->itemlost > 0;

	my $hidden_in_opac = 0;

	foreach my $field ( keys %{$rules} ) {
		if ( any { $item->$field eq $_ } @{ $rules->{$field} } ) {
			$hidden_in_opac = 1;
			last;
		}
	}

	return $hidden_in_opac;
}

# Given a result, using the result's target config try and contruct a link
# to the record's bib
sub get_result_url {
    my ( $result, $servers, $config ) = @_;
    my $server_id = get_server_id($result, $servers);
    my $link_field = $config->{"ill_avail_config_link_${server_id}"};
    if ($link_field && $result->{source_record_id}) {
        $link_field =~ s/source_record_id/$result->{source_record_id}/g;
        $result->{url} = $link_field;
    }
    return $result;
}

# Given a result, get the result's corresponding OPAC URL
sub get_opac_url {
    my ( $result, $servers, $config ) = @_;
    my $server_id = get_server_id($result, $servers);
    my $opac = $config->{"ill_avail_config_opac_${server_id}"};
    if ($opac) {
        $result->{opac_url} = $opac;
    }
    return $result;
}

sub get_z_targets {
    my ( $ids ) = @_;

    my $where = $ids ? { id => $ids } : {};
    # Get the details of the servers we're querying
    # We may be filtering based on the server IDs we've been passed
    my $schema = Koha::Database->new()->schema();
    my $rs = $schema->resultset('Z3950server')->search($where);
    my @servers = $rs->all;
    return \@servers;
}

# Contained MockTemplate object is a compatability shim used so we can pass
# a minimal object to Z3950Search and thus use existing Koha breeding and
# configuration functionality.
# (Shamelessly ripped off from https://github.com/PTFS-Europe/koha-ill-koha/blob/master/Base.pm#L920-L961)

{

  package MockTemplate;

  use base qw(Class::Accessor);
  __PACKAGE__->mk_accessors("vars");

  sub new {
    my $class = shift;
    my $self = {VARS => {}};
    bless $self, $class;
  }

  sub param {
    my $self = shift;

    # Getter
    if (scalar @_ == 1) {
      my $key = shift @_;
      return $self->{VARS}->{$key};
    }

    # Setter
    while (@_) {
      my $key = shift;
      my $val = shift;

      if    (ref($val) eq 'ARRAY' && !scalar @$val) { $val = undef; }
      elsif (ref($val) eq 'HASH'  && !scalar %$val) { $val = undef; }
      if    ($key) {
        $self->{VARS}->{$key} = $val;
      }
      else {
        warn "Problem = a value of $val has been passed to param without key";
      }
    }
  }
}

1;
