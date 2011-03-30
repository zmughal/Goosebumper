package App::Goosebumper::Sites::UH::EgrBlackboard;

use strict;
use warnings;
use App::Goosebumper::Sites;
use App::Goosebumper::SitesHelper;

use Log::Log4perl qw(:easy);

use WWW::Mechanize::Firefox;
use HTML::TreeBuilder;

use Data::Dumper;
use Carp;

use URI::WithBase;
use URI::Escape;
use File::Temp qw/ tempfile /;
use File::Slurp;

# From <https://developer.mozilla.org/en/XPCOM_Interface_Reference/nsIWebBrowserPersist>
use constant PERSIST_STATE_FINISHED => 3;

my $url = "http://blackboard.egr.uh.edu/";

sub new {
	my ($class, $sites_helper) = @_;
	ref($class) and croak "class name needed";

	my $self = {
		_SitesHelper => $sites_helper,
		site_name => $sites_helper->strip_sites(__PACKAGE__)
	};
	$self->{cache} = $sites_helper->read_cache($self->{site_name});
	bless $self, $class;
}

sub screech {
	my $self = shift;
	my $sites_helper = $self->{_SitesHelper};
	my $site_name = $self->{site_name};
	DEBUG "Entering $site_name";

	my $mech = $sites_helper->start_firefox();
	$self->{_mech} = $mech;

	$mech->get( $url );

	$self->_login();

	$self->_visit_courses();
	$sites_helper->download_cache($self);
	$sites_helper->write_cache($self->{cache});
}

sub _login {
	my $self = shift;
	my $sites_helper = $self->{_SitesHelper};
	my $site_name = $self->{site_name};
	my $mech = $self->{_mech};

	my $cred = $sites_helper->{config}{sites}{$site_name};
	#{ local $Data::Dumper::Indent = 0; local $Data::Dumper::Terse = 1;
	#DEBUG "We have the credentials ", Dumper $cred; }

	$mech->follow_link( text => 'User Login' );

	my $login_input_xpath='//input[@name="Login"]'; # needed to login
	if(eval { $mech->xpath($login_input_xpath, any => 1) } )
	{
		$mech->field( user_id => $cred->{username});
		$mech->field( password => $cred->{password});
		$mech->click( { xpath => $login_input_xpath });
	}
}

sub _visit_courses {
	my $self = shift;
	my $mech = $self->{_mech};
	$mech->click(  $mech->xpath('//a/span[text()="Courses"]/parent::*',
		frames=>1, single=>1 )  );

	my %course_h;
	push @{$course_h{$_->{href}}}, $_->{innerHTML} for $mech->xpath( '//th//a', frames=>1);
	DEBUG Dumper \%course_h;

	my $course_list = $mech->base;
	for my $course (keys %course_h) {
		# $course is an href
		my $course_name = $course_h{$course}->[1]; # name is in second list
		$course_name =~ s/(.+?):.*/$1/;
		my $course_link_text = $course_h{$course}->[0];
		$mech->get( $course );
		sleep 1;	# allow to load
		$self->_process_course($course_name);
	}


}

sub _process_course {
	my $self = shift;
	my $course_name = shift;
	my $mech = $self->{_mech};
	DEBUG "Processing course $course_name";

	my $course_home = $mech->base;
	my @pages = ( 'Course Information', 'Course Documents', 'Assignments',
		'Course Documents'); #'Staff Information'
	my $files = $self->{cache}{content}{courses}{$course_name}{files} // [];
	for my $page (@pages) {
		DEBUG "Looking at page $page";
		$mech->follow_link( text => $page );
		sleep 2; # wait for it to load the frame
		my $page_find = (grep { $_->{label} eq $page } @$files)[0];
		unless ( $page_find ) {
			my $new_page = { label => $page };
			push @$files, $new_page;
			$page_find = $new_page;
		}
		$page_find->{files} = $self->_process_page_items($page_find->{files});
	}
	$self->{cache}{content}{courses}{$course_name}{files} = $files;
}

sub _process_page_items {
	my $self = shift;
	my $files = shift;
	my $mech = $self->{_mech};
	for my $item ($mech->xpath('//img[@alt="Item"]/parent::*/following-sibling::*', frames=>1)) {
		my $subitems = $self->_process_item($item->{innerHTML}, $mech->base );
		for my $subitem (@$subitems) {
			DEBUG "Looking at item ", $subitem->{label};
			unless ( grep { $_->{label} eq $subitem->{label} &&
				$_->{filename} eq $subitem->{filename} } @$files ) {
					DEBUG "Adding files ", $subitem->{filename};
					$subitem->{href} =
						URI::WithBase->new($subitem->{href},
							$mech->base )->abs->as_string();
					push @$files, $subitem;
				}
		}
	}
	return $files;
}

sub _process_item {
	my $self = shift;
	my $html = shift;
	my $base = shift;

	my $subitems;
	my $tb = HTML::TreeBuilder->new;
	$tb->parse_content($html);
	my $label_el = $tb->look_down ( "class", "label" );
	my $label = $label_el->as_text() if defined $label_el;
	my @links = $tb->look_down ( "_tag", "a" );
	for my $subitem (@links) {
		my $prop;
		$prop->{label} = $label;
		$prop->{'sub-item label'} = $subitem->as_text();
		my $rel_href = $subitem->attr('href');
		my $href = URI::WithBase->new($rel_href, $base)->abs();
		$prop->{href} = $href->as_string;

		my @path_seg = $href->path_segments();
		$prop->{filename} = uri_unescape($path_seg[-1]);

		unless( $prop->{filename} ) {
			# not a file, but a URI
			$prop->{filename} = $prop->{'sub-item label'};
			$prop->{response} = HTTP::Response->new(200, undef, undef, "$href\n");
		} else {
			my (undef, $tmp_fn) = tempfile( OPEN => 0 );
			my $browser = $self->{_mech}->get($prop->{href}, ':content_file' => $tmp_fn);
			while( $browser->{currentState} != PERSIST_STATE_FINISHED ) {
				# TODO: identify download failure
				sleep 1;
			}
			my $content = read_file( $tmp_fn );
			my $response = HTTP::Response->new(200, undef, undef, $content);
			$response->content( $content );
			$response->date(time);	# set date to now
			unlink $tmp_fn;
			if( $response->is_success ) {
				$prop->{response} = $response;
			} else {
				$prop->{response} = undef;
			}
		}
		push @$subitems, $prop;
	}
	return $subitems;
}


1;
