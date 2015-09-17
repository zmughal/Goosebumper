package App::Goosebumper::Site::UH::BlackboardVista;

use strict;
use warnings;
use App::Goosebumper::Site;
use App::Goosebumper::SiteHelper;

use Log::Log4perl qw(:easy);

use WWW::Scripter;

use Data::Dumper;
use Carp;

my $url = "http://www.uh.edu/blackboard/";

sub new {
	my ($class, $site_helper) = @_;
	ref($class) and croak "class name needed";

	my $self = {
		_SiteHelper => $site_helper,
		site_name => $site_helper->strip_site(__PACKAGE__)
	};
	bless $self, $class;
}

sub screech {
	my $self = shift;
	my $site_helper = $self->{_SiteHelper};
	my $site_name = $self->{site_name};
	DEBUG "Entering $site_name";

	my $mech = new WWW::Scripter;
	$self->{_mech} = $mech;
	$mech->use_plugin(JavaScript =>
		engine  => 'JE',
	);

	$mech->get( $url );

	$self->_login();

	#$self->_visit_courses();
	#$site_helper->download_cache($self);
	#$site_helper->write_cache($self->{cache});
}

sub _login {
	my $self = shift;
	my $site_helper = $self->{_SiteHelper};
	my $site_name = $self->{site_name};
	my $mech = $self->{_mech};

	my $cred = $site_helper->{config}{site}{$site_name};

	$mech->follow_link( url_regex => qr/logonDisplay/ );

	$mech->submit_form( with_fields => {
		webctid => $cred->{username},
		password => $cred->{password},
	});
	$mech->post( URI->new_abs("/webct/authenticateUser.dowebct", $mech->base),
		$mech->current_form);
	#$mech->get('https://learn.uh.edu/webct/urw/tp0.lc5122011/cobaltMainFrame.dowebct');
	DEBUG $mech->title;
	DEBUG "Logged in";
	print $mech->content;
}

1;
