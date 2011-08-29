package App::Goosebumper::Site::UH::EgrBlackboard;

use strict;
use warnings;
use App::Goosebumper::Site;
use App::Goosebumper::SiteHelper;

use Log::Log4perl qw(:easy);

use WWW::Scripter;
use HTML::TreeBuilder::XPath;
use HTML::FormatText;

use Data::Dumper;
use Carp;

use HTML::Entities;
use URI::WithBase;
use URI::Escape;
use File::Temp qw/ tempfile /;
use File::Slurp;

# From <https://developer.mozilla.org/en/XPCOM_Interface_Reference/nsIWebBrowserPersist>
use constant PERSIST_STATE_FINISHED => 3;

my $url = "http://blackboard.egr.uh.edu/";

sub new {
	my ($class, $site_helper) = @_;
	ref($class) and croak "class name needed";

	my $self = {
		_SiteHelper => $site_helper,
		site_name => $site_helper->strip_site(__PACKAGE__)
	};
	$self->{cache} = $site_helper->read_cache($self->{site_name});
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

	$self->_visit_courses();
	$site_helper->download_cache($self);
	$site_helper->write_cache($self->{cache});
}

sub _login {
	my $self = shift;
	my $site_helper = $self->{_SiteHelper};
	my $site_name = $self->{site_name};
	my $mech = $self->{_mech};

	my $cred = $site_helper->{config}{site}{$site_name};
	#{ local $Data::Dumper::Indent = 0; local $Data::Dumper::Terse = 1;
	#DEBUG "We have the credentials ", Dumper $cred; }

	$mech->follow_link( text => 'User Login' );

	my $login_input_xpath='//input[@name="Login"]'; # needed to login
	if(eval { HTML::TreeBuilder::XPath->new_from_content($mech->content)
			->findnodes($login_input_xpath) } )
	{
		$mech->submit_form( with_fields => {
			user_id => $cred->{username},
			password => $cred->{password},
		});
		DEBUG $mech->title;
		DEBUG "Logged in";
	}
}

sub _visit_courses {
	my $self = shift;
	my $mech = $self->{_mech};
	$mech->frames->[0]->follow_link( text => 'Courses' );

	my %course_h;
	push @{$course_h{$_->attr('href')}}, $_->as_trimmed_text(extra_chars => '\xA0')
		for HTML::TreeBuilder::XPath
			->new_from_content($mech->frames->[1]->content)
			->findnodes('//th//a');
	DEBUG Dumper \%course_h;

	my $course_list = $mech->base;
	for my $course (keys %course_h) {
		# $course is an href
		my $course_name = $course_h{$course}->[1]; # name is in second list
		$course_name =~ s/(.+?):.*/$1/;
		$course_name =~ s,/,__,g;
		decode_entities($course_name);
		my $course_link_text = $course_h{$course}->[0];
		$mech->get( $course );
		$self->_process_course($course_name);
	}


}

sub _process_course {
	my $self = shift;
	my $course_name = shift;
	my $mech = $self->{_mech};
	DEBUG "Processing course $course_name";

	my $course_home = $mech->base;
	my @pages = ( 'Course Information', 'Course Documents', 'Assignments',);
			#'Staff Information'
	my $files = $self->{cache}{content}{courses}{$course_name}{files} // [];
	for my $page (@pages) {
		DEBUG "Looking at page $page";
		$mech->frames->[1]->frames->[0]->follow_link( text => $page );
		my $page_find = (grep { $_->{label} eq $page } @$files)[0];
		unless ( $page_find ) {
			my $new_page = { label => $page };
			push @$files, $new_page;
			$page_find = $new_page;
		}
		$page_find->{files} = $self->_process_page_items($page_find->{files});
		$mech->get($course_home);
	}
	$self->{cache}{content}{courses}{$course_name}{files} = $files;
}

sub _process_page_items {
	my $self = shift;
	my $files = shift;
	my $mech = $self->{_mech};
	for my $item
		(HTML::TreeBuilder::XPath->new_from_content($mech->frames->[1]->frames->[1]->content)
			->findnodes('//img[@alt="Item"]/parent::*/following-sibling::*')) {
		my $subitems = $self->_process_item($item->as_HTML, $mech->base );
		for my $subitem (@$subitems) {
			DEBUG "Looking at item ", $subitem->{label};
			unless ( grep { $_->{label} eq $subitem->{label} &&
				$_->{filename} eq $subitem->{filename} } @$files ) {
					DEBUG "Adding file ", $subitem->{filename};
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
	my $info_text = HTML::FormatText->new->format($tb);
	my @links = $tb->look_down ( "_tag", "a" );
	if( !@links and $label and $info_text) {
		my $prop;
		$prop->{label} = $label;
		$prop->{filename} = $label;
		$prop->{text} = $info_text;
		$prop->{html} = $html;
		$prop->{response} = HTTP::Response->new(200, undef, undef, "$info_text\n");
		push @$subitems, $prop;
	}
	for my $subitem (@links) {
		my $prop;
		$prop->{label} = $label;
		$prop->{text} = $info_text if $info_text;
		$prop->{html} = $html;
		$prop->{'sub-item label'} = $subitem->as_text();
		my $rel_href = $subitem->attr('href');
		my $href = URI::WithBase->new($rel_href, $base)->abs();
		$prop->{href} = $href->as_string;
		$prop->{href} =~ s,^(http://[^/]+):80/,$1/,; # Blackboard returns 400 if you include :80

		my @path_seg = $href->path_segments();
		$prop->{filename} = uri_unescape($path_seg[-1]);

		unless( $prop->{filename} ) {
			# not a file, but a URI
			$prop->{filename} = $prop->{'sub-item label'};
			$prop->{response} = HTTP::Response->new(200, undef, undef, "$href\n");
		} else {
			my (undef, $tmp_fn) = tempfile( OPEN => 0 );
			my $response = $self->{_mech}->get($prop->{href});
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
