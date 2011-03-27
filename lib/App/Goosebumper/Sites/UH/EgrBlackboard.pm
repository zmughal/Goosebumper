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

	DEBUG "Getting cookies";
	my $cookies = $mech->cookies();
	$self->{down_mech} = WWW::Mechanize ->new( cookie_jar => $cookies );
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
		my $course_name = $course_h{$course}->[1]; # name is in second list
		$course_name =~ s/(.+?):.*/$1/;
		my $course_link_text = $course_h{$course}->[0];
		$mech->follow_link( text => $course_link_text );
		sleep 1;	# allow to load
		$self->_process_course($course_name);
		$mech->get($course_list);	# go back to list
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
		DEBUG Dumper $page_find;
	}
	$self->{cache}{content}{courses}{$course_name}{files} = $files;
	DEBUG Dumper $self->{cache}{content}{courses}{$course_name};
}

sub _process_page_items {
	my $self = shift;
	my $files = shift;
	my $mech = $self->{_mech};
	for my $item ($mech->xpath('//img[@alt="Item"]/parent::*/following-sibling::*', frames=>1)) {
		my $subitems = $self->_process_item($item->{innerHTML});
		for my $subitem (@$subitems) {
			DEBUG "Looking at item ", $subitem->{label};
			unless ( grep { $_->{label} eq $subitem->{label} &&
				$_->{filename} eq $subitem->{filename} } @$files ) {
					DEBUG "Adding files ", $subitem->{filename};
					$subitem->{href} =
						URI::WithBase->new($subitem->{href},
							$mech->base())->abs()->as_string();
					push @$files, $subitem;
				}
		}
	}
	return $files;
}

sub _process_item {
	my $self = shift;
	my $html = shift;

	my $subitems;
	my $tb = HTML::TreeBuilder->new;
	$tb->parse_content($html);
	my $label_el = $tb->look_down ( "class", "label" );
	my $label = $label_el->as_text() if defined $label_el;
	my @links = $tb->look_down ( "_tag", "a" );
	for my $subitem (@links) {
		my $prop;
		$prop->{label} = $label;
		$prop->{filename}=$subitem->as_text();
		$prop->{href}=$subitem->attr('href');
		push @$subitems, $prop;
	}
	return $subitems;
}


1;
