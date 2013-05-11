package Net::Dogstatsd;

use strict;
use warnings;

use Carp qw( croak carp );
use Data::Dumper;
use Data::Validate::Type;
use IO::Socket::INET;
use Try::Tiny;


=head1 NAME

Net::Dogstatsd - Perl client to Datadog's dogstatsd metrics collector.


=head1 VERSION

Version 0.9.0

=cut

our $VERSION = '0.9.0';


=head1 SYNOPSIS

This module allows you to send multiple types of metrics to the Datadog service
via dogstatsd, a local daemon installed by Datadog agent package.

	use Net::Dogstatsd;

	# Create object.
	my $dogstatsd = Net::Dogstatsd->new();
	
=cut

=head1 MAIN

=cut

# Used to build the UDP datagram
my $METRIC_TYPES =
{
	'counter'   => 'c',
	'gauge'     => 'g',
	'histogram' => 'h',
	'timer'     => 'ms',
	'sets'      => 's',
};

=head1 METHODS

=head2 new()

Create a new Net::Dogstatsd object that will be used to interact with dogstatsd.

	use Net::Dogstatsd;

	my $dogstatsd = Net::Dogstatsd->new(
		host    => 'localhost',  #optional. Default = 127.0.0.1
		port    => '8125',       #optional. Default = 8125
		verbose => 1,            #optional. Default = 0
	);

=cut

sub new
{
	my ( $class, %args ) = @_;
	
	# Defaults
	my $host = $args{'host'} // '127.0.0.1';
	my $port = $args{'port'} // '8125';
	my $verbose = $args{'verbose'} // 0;
	
	my $self = {
		host             => $host,
		port             => $port,
		verbose          => $verbose,
	};
	
	bless( $self, $class );
	
	return $self;
}


=head2 verbose()

Get or set the 'verbose' property.

	my $verbose = $dogstatsd->verbose();
	$dogstatsd->verbose( 1 );

=cut

sub verbose
{
	my ( $self, $value ) = @_;
	
	if ( defined $value && $value =~ /^[01]$/ )
	{
		$self->{'verbose'} = $value;
	}
	else
	{
		return $self->{'verbose'};
	}
	
	return;
}


=head2 get_socket()

Create a new socket, if one does not already exist.

	my $socket = $dogstatsd->get_socket();

=cut

sub get_socket
{
	my ( $self ) = @_;
	my $verbose = $self->verbose();
	
	if ( !defined $self->{'socket'} )
	{
		try
		{
			$self->{'socket'} = IO::Socket::INET->new(
				PeerAddr => $self->{'host'},
				PeerPort => $self->{'port'},
				Proto    => 'udp'
				) 
			|| die "Could not open UDP connection to" . $self->{'host'} . ":" . $self->{'port'};
			
		}
		catch
		{
			croak( "Could not open connection to metrics server. Error: >$_<" );
		};
	}
	
	return $self->{'socket'};
}



=head2 increment()

Increment a counter metric. Include optional 'value' argument to increment by >1.
Include optional arrayref of tags/tag-values.

	$metric->increment(
		name  => $metric_name,
		value => $increment_value, #optional; default = 1
	);
	
	$metric->increment(
		name  => $metric_name,
		value => $increment_value, #optional; default = 1
		tags  => [ tag1, tag2:value, tag3 ],
	);

=cut

sub increment
{
	my ( $self, %args ) = @_;
	
	$self->_counter( action => 'increment', %args );
	return;
}


=head2 decrement()

Decrement a counter metric. Include optional 'value' argument to decrement by >1.
Include optional arrayref of tags/tag-values.

	$metric->decrement(
		name  => $metric_name,
		value => $decrement_value, #optional; default = 1
	);
	
	$metric->decrement(
		name  => $metric_name,
		value => $decrement_value, #optional; default = 1
		tags  => [ tag1, tag2:value, tag3 ],
	);

=cut

sub decrement
{
	my ( $self, %args ) = @_;
	
	$self->_counter( action => 'decrement', %args );
	return;
}


=head2 gauge()

Send a 'gauge' metric. ex: gas gauge value, inventory stock level
Include optional arrayref of tags/tag-values.

	$dogstatsd->gauge(
		name  => $metric_name,
		value => $gauge_value,
	);
	
	$dogstatsd->gauge(
		name  => $metric_name,
		value => $gauge_value,
		tags  => [ 'tag1', 'tag2:value', 'tag3' ],
	);

=cut

sub gauge
{
	my ( $self, %args ) = @_;
	my $verbose = $self->verbose();
	
	# Check for mandatory parameters
	foreach my $arg ( qw( name  value ) )
	{
		croak "Argument '$arg' is a required argument"
			if !defined( $args{$arg} ) || ( $args{$arg} eq '' );
	}
	
	# Check that value is a number
	if ( defined( $args{'value' } ) )
	{
		croak "Value >$args{'value'}< is not a number, which is required for gauge()"
			unless Data::Validate::Type::is_number( $args{'value'}, positive => 1 );
	}
	
	# Error checks common to all metric types
	$self->_error_checks( %args );
	
	$self->_send_metric(
		type        => 'gauge',
		value       => $args{'value'},
		name        => $args{'name'},
		tags        => defined $args{'tags'} ? $args{'tags'} : [],
		sample_rate => defined $args{'sample_rate'} ? $args{'sample_rate'} : 1,
	);
	
	return;
}


=head1 INTERNAL FUNCTIONS

=head2 _counter

	$self->_counter(
		action => [ increment | decrement ],
		%args
	);

=cut

sub _counter
{
	my ( $self, %args ) = @_;
	
	my $action = delete( $args{'action'} );
	my $multipliers = {
		'increment' => 1,
		'decrement' => -1,
	};
	
	croak "Error - invalid action >$action<" unless exists( $multipliers->{ $action } );
		
	my $multiplier = $multipliers->{ $action };
	
	# Check for mandatory parameters
	foreach my $arg ( qw( name  ) )
	{
		croak "Argument '$arg' is a required argument"
			if !defined( $args{$arg} ) || ( $args{$arg} eq '' );
	}
	
	# Check that value, if provided, is a positive integer
	if ( defined( $args{'value' } ) )
	{
		croak "Value >$args{'value'}< is not a positive integer, which is required for " . $action . '()'
			if ( $args{'value'} !~ /^\d+$/ || $args{'value'} <= 0 );
	}
	
	# Error checks common to all metric types
	$self->_error_checks( %args );
	
	$self->_send_metric(
		type        => 'counter',
		name        => $args{'name'},
		value       => 
			( defined $args{'value'} && $args{'value'} ne '' )
				? ( $args{'value'} * $multiplier )
				: $multiplier,
		tags        => defined $args{'tags'} ? $args{'tags'} : [],
		sample_rate => defined $args{'sample_rate'} ? $args{'sample_rate'} : 1,
	);
	
	return;
}


=head2 _error_checks()

	$self->_error_checks( %args );

Common error checking for all metric types.

=cut

sub _error_checks
{
	my ( $self, %args ) = @_;
	my $verbose = $self->verbose();
	
	# Metric name starts with a letter
	if ( $args{'name'} !~ /^[a-zA-Z]/ )
	{
		croak( "ERROR - Invalid metric name >" . $args{'name'} . "<. Names must start with a letter, a-z. Not sending." );
	}
	
	# Tags, if exist...
	if ( defined( $args{'tags'} ) && scalar( $args{'tags'} ) != 0 )
	{
		if ( !Data::Validate::Type::is_arrayref( $args{'tags'} ) )
		{
			croak "ERROR - Tag list is invalid. Must be an arrayref.";
		}
		
		foreach my $tag ( @{ $args{'tags'} } )
		{
			# Must start with a letter
			croak( "ERROR - Invalid tag >" . $tag . "< on metric >" . $args{'name'} . "<. Tags must start with a letter, a-z. Not sending." )
				if ( $tag !~ /^[a-zA-Z]/ );
			
			# Must be < 200 characters [ discovered this limitation while testing. Datadog stated it should truncate, but I received various errors ]
			croak( "ERROR - Invalid tag >" . $tag . "< on metric >" . $args{'name'} . "<. Tags must be 200 chars or less. Not sending." )
				if ( length( $tag ) > 200 );
			
			# NOTE: This check isn't required by Datadog, they will allow this through.
			# However, this tag will not behave as expected in the graphs, if we were to allow it.
			croak( "ERROR - Invalid tag >" . $tag . "< on metric >" . $args{'name'} . "<. Tags should only contain a single colon (:). Not sending." )
				if ( $tag =~ /^\S+:\S+:/ );
		}
	}
	
	# Check that optional 'sample_rate' argument is valid ( 1, or a float between 0 and 1 )
	if ( defined $args{'sample_rate'} )
	{
		if ( !Data::Validate::Type::is_number( $args{'sample_rate'} , strictly_positive => 1 ) || $args{'sample_rate'} > 1 )
		{
			croak "ERROR - Invalid sample rate >" . $args{'sample_rate'} . "<. Must be 1, or a float between 0 and 1.";
		}
	}
	
	return;
}


=head2 _send_metric()

Send metric to stats server.

=cut

sub _send_metric
{
	my ( $self, %args ) = @_;
	my $verbose = $self->verbose();
	
	# Check for mandatory parameters
	foreach my $arg ( qw( name type value ) )
	{
		croak "Argument '$arg' is a required argument"
			if !defined( $args{$arg} ) || ( $args{$arg} eq '' );
	}
	
	my $original_name = $args{'name'};
	# Metric name should only contain alphanumeric, "_", ".". Convert anything else to underscore and warn about substitution
	# NOTE: Datadog will do this for you anyway, but won't warn you what the actual metric name will become.
	$args{'name'} =~ s/[^a-zA-Z0-9_\.]/_/;
	
	#TODO change to Log::Any output
	carp( "WARNING: converted metric name from >$original_name< to >", $args{'name'}, "<. Names should only contain: a-z, 0-9, underscores, and dots/periods." )
		if $args{'name'} ne $original_name;
	
	# Default sample rate = 1
	$args{'sample_rate'} //= 1;
	
	my $socket = $self->get_socket();
	return unless defined $socket;
	
	# Datagram format. More info at http://docs.datadoghq.com/guides/dogstatsd/
	# dashboard.metricname:value|type|@sample_rate|#tag1:value,tag2
	my $metric_string = $args{'name'} . ":" . $args{'value'} . '|' . $METRIC_TYPES->{ $args{'type'} } . '|@' . $args{'sample_rate'} ;
	
	if ( defined $args{'tags'} && scalar ( @{ $args{'tags'} } ) != 0 )
	{
		foreach my $tag ( @{ $args{'tags'} } )
		{
			my $original_tag = $tag;

			$tag =~ s/\s+$//; # Strip trailing whitespace
			# Tags should only contain alphanumeric, "_", "-",".", "/", ":". Convert anything else to underscore and warn about substitution
			$tag =~ s/[^a-zA-Z0-9_\-\.\/:]/_/g;
			$tag =~ s/\s+/_/g; # Replace remaining whitespace with underscore
			carp( "WARNING: converted tag from >$original_tag< to >", $tag, "<. Tags should only contain: a-z, 0-9, underscores, dashes, dots/periods, forward slashes, colons." )
				if $tag ne $original_tag;
		}
		$metric_string .= '|#' . join( ',', @{ $args{'tags'} } );
	}
	
	# Force to all lower case because Datadog has case sensitive tags and metric
	# names. We don't want to end up with multiple case variations of the same
	# metric name/tag
	$metric_string = lc( $metric_string );
	
	warn( "\nbuilt metric string >$metric_string<" ) if $verbose;
	
	# Use of rand() is how the Ruby and Python clients implement sampling, so we will too.
	if ( $args{'sample_rate'} == 1 || ( rand() < $args{'sample_rate'} ) )
	{
		my $response = IO::Socket::send( $socket, $metric_string, 0 );
		unless (defined $response) 
		{
			carp( "error sending metric [string >$metric_string<]: $!" );
		}
	}
	
	return;
}


=head1 RUNNING TESTS

By default, only basic tests that do not require a connection to Datadog's
platform are run in t/.

To run the developer tests, you will need to do the following:

=over 4

=item * Sign up to become a Datadog customer ( if you are not already), at
L<https://app.datadoghq.com/signup>. Free trial accounts are available.

=item * Install and configure Datadog agent software (requires python 2.6)
L<https://app.datadoghq.com/account/settings#agent>

=back


=head1 AUTHOR

Jennifer Pinkham, C<< <jpinkham at cpan.org> >>.


=head1 BUGS

Please report any bugs or feature requests to the GitHub Issue Tracker at L<https://github.com/jpinkham/net-dogstatsd/issues>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.


=head1 SUPPORT

You can find documentation for this module with the perldoc command.

	perldoc Net::Dogstatsd


You can also look for information at:

=over 4

=item * Bugs: GitHub Issue Tracker

L<https://github.com/jpinkham/net-dogstatsd/issues>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Net-Dogstatsd>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Net-Dogstatsd>

=item * MetaCPAN

L<https://metacpan.org/release/Net-Dogstatsd>

=back


=head1 ACKNOWLEDGEMENTS

Thanks to ThinkGeek (<http://www.thinkgeek.com/>) and its corporate overlords at
Geeknet (<http://www.geek.net/>), for footing the bill while I write code for them!

=head1 COPYRIGHT & LICENSE

Copyright 2013 Jennifer Pinkham.

This program is free software; you can redistribute it and/or modify it
under the terms of the Artistic License.

See http://dev.perl.org/licenses/ for more information.

=cut

1;
