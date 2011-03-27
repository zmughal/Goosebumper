package App::Goosebumper::Sites::UH::BlackboardVista;

use strict;
use warnings;
use App::Goosebumper::Sites;
use App::Goosebumper::SitesHelper;

use Log::Log4perl qw(:easy);

use Data::Dumper;
use Carp;

sub new {
	my ($class, $sites_helper) = @_;
	ref($class) and croak "class name needed";

	my $self = {
		_SitesHelper => $sites_helper,
		site_name => $sites_helper->strip_sites(__PACKAGE__)
	};
	bless $self, $class;
}

sub screech {
	my $self = shift;
	my $sites_helper = $self->{_SitesHelper};
	my $site_name = $self->{site_name};
	DEBUG "Entering $site_name";

	my $cred = $sites_helper->{config}{sites}{$site_name};
	#{ local $Data::Dumper::Indent = 0; local $Data::Dumper::Terse = 1;
	#DEBUG "We have the credentials ", Dumper $cred; }
}

1;
