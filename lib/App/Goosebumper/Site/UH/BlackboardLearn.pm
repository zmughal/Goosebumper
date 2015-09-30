package App::Goosebumper::Site::UH::BlackboardLearn;

use strict;
use warnings;
use App::Goosebumper::Site;
use App::Goosebumper::SiteHelper;

use WWW::Mechanize::Firefox;
use HTML::TreeBuilder::XPath;
use Log::Log4perl qw(:easy);
use HTML::FormatText;
use utf8::all;

use Carp;

# <https://elearning.uh.edu/> redirects to $url using JS
my $course_top_url = "https://elearning.uh.edu/webapps/portal/execute/defaultTab";

sub new {
	my ($class, $site_helper) = @_;
	ref($class) and croak "class name needed";

	my $self = {
		_SiteHelper => $site_helper,
		site_name => $site_helper->strip_site(__PACKAGE__),
	};
	bless $self, $class;
}


sub screech {
	my $self = shift;
	my $site_helper = $self->{_SiteHelper};
	my $site_name = $self->{site_name};
	DEBUG "Entering $site_name";

	my $mech = $self->{_mech} = WWW::Mechanize->new;
	#my $mech = $self->{_mech} = $site_helper->start_firefox;

	$self->_login();

	$self->_visit_courses;
}

sub _check_content_for_login_form {
	my ($self, $content) = @_;
	my $tree = HTML::TreeBuilder::XPath->new_from_content($content);
	my $login_input_xpath = '//input[@name="user_id"]'; # needed to login
	return !!( $tree->findnodes( $login_input_xpath ) );
}

sub _extract_course_info {
	my ($self) = @_;
	my $response = $self->_get_course_listing_data;
	my $courselist_content = $response->decoded_content;

	# All course nodes are inside a <ul>
	#     <ul class="portletList-img courseListing coursefakeclass ">
	#     </ul>
	my $courselist_tree = HTML::TreeBuilder::XPath->new_from_content($courselist_content);
	my $course_info;
	my @course_nodes = $courselist_tree->findnodes('//ul[contains(@class,"courseListing")]/li/a');
	for my $course_node (@course_nodes) {
		my $href = $course_node->attr('href');
		my $abs_href = URI->new_abs( $href, $response->base );
		my $text = $course_node->as_text;

		my $cur_course = {};
		$cur_course->{text} = $text;
		$cur_course->{href} = $abs_href;

		# courses are in the form:
		#
		#     H_20153_BIOL_3324_13593: 2015FA-13593-BIOL3324-Human Physiology
		#                                           [   a  ] [      b       ]
		#
		# where a is the course_id and b is the course_name
		($cur_course->{course_id}, $cur_course->{course_name}) =
			$text =~ /^[^:]+?: \w+-\w+-(?<course_id>\w+)-(?<course_name>.*)$/;

		$cur_course->{course_dirname} =
			$cur_course->{course_id}
			=~ s/
				(?<dept>[A-Z]+)
				(?<course_number>\d+)
			/$+{dept}_$+{course_number}/xr;

		$course_info->{$abs_href} = $cur_course;
	}

	$course_info;
}

sub _visit_courses {
	my $self = shift;
	my $mech = $self->{_mech};

	my $course_info = $self->_extract_course_info;

	for my $course (keys %$course_info) {
		$self->_process_course( $course_info->{$course} )
	}

}

sub _process_course {
	my ($self, $course) = @_;
	my $mech = $self->{_mech};
	DEBUG "Processing course $course->{course_name}";

	my $course_index = $mech->get($course->{href});

	my $tree = HTML::TreeBuilder::XPath->new_from_content( $course_index->decoded_content );
	my @pages = map { $_->as_text } $tree->findnodes('//div[@id = "navigationPane"]//a[@target="_self"]');
	use DDP; p @pages;

	#my $content_form = ( $tree->findnodes('//form[@name="contentForm"]') )[0];
	my $content_list = ( $tree->findnodes('//ul[@id="content_listContainer"]') )[0];
	#use DDP ; p $content_list;
	my $content_list_text = HTML::FormatText->new->format($content_list);
	use DDP; p $content_list_text;

	require Carp::REPL; Carp::REPL->import('repl'); repl();#DEBUG
}

sub _get_course_listing_data {
	my ($self) = @_;
	my $mech = $self->{_mech};

	$mech->post(
		'https://elearning.uh.edu/webapps/portal/execute/tabs/tabAction',
		{
			action => 'refreshAjaxModule',
			modId => '_25_1',
			tabId => '_27_1',
			tab_tab_group_id => '_42_1',
		},
		'X-Requested-With' => 'XMLHttpRequest',
	);
}


sub _login {
	my $self = shift;
	my $site_helper = $self->{_SiteHelper};
	my $site_name = $self->{site_name};
	my $mech = $self->{_mech};

	my $cred = $site_helper->{config}{site}{$site_name};

	$mech->get( $course_top_url );

	if( $self->_check_content_for_login_form( $mech->content ) ) {
		$mech->submit_form( with_fields => {
			user_id => $cred->{username},
			password => $cred->{password},
		});
		DEBUG $mech->title;
		DEBUG "Logged in";
		#print $mech->content;
	}
}
