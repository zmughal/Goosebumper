package App::Goosebumper::Site::UH::BlackboardLearn;

use strict;
use warnings;
use App::Goosebumper::Site;
use App::Goosebumper::SiteHelper;

use WWW::Mechanize::Firefox;
use HTML::TreeBuilder::XPath;
use Log::Log4perl qw(:easy);
use utf8::all;

use Carp;

# <https://elearning.uh.edu/> redirects to $url using JS
my $url = "https://elearning.uh.edu/webapps/portal/execute/defaultTab";

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

	my $mech = $self->{_mech} = $site_helper->start_firefox;

	$mech->get( $url );

	$self->_login();

	$self->_visit_courses;
}

sub _visit_courses {
	my $self = shift;
	my $mech = $self->{_mech};

	# All course nodes are inside a <ul>
	#     <ul class="portletList-img courseListing coursefakeclass ">
	#     </ul>
	my $courselist_tree = HTML::TreeBuilder::XPath->new_from_content($mech->content);
	my $course_info;
	my @course_nodes = $courselist_tree->findnodes('//ul[contains(@class,"courseListing")]/li/a');
	for my $course_node (@course_nodes) {
		my $href = $course_node->attr('href');
		my $abs_href = URI->new_abs( $href, $mech->base );
		my $text = $course_node->as_text;

		my $cur_course = {};
		$cur_course->{text} = $text;

		# courses are in the form:
		#
		#     H_20153_BIOL_3324_13593: 2015FA-13593-BIOL3324-Human Physiology
		#                                           [   a  ] [      b       ]
		#
		# where a is the course_id and b is the course_name
		($cur_course->{course_id}, $cur_course->{course_name}) =
			$text =~ /^[^:]+?: \w+-\w+-(?<course_id>\w+)-(?<course_name>.*)$/;


		$course_info->{$abs_href} = $cur_course;
	}
	require Carp::REPL; Carp::REPL->import('repl'); repl();
}


sub _login {
	my $self = shift;
	my $site_helper = $self->{_SiteHelper};
	my $site_name = $self->{site_name};
	my $mech = $self->{_mech};

	my $cred = $site_helper->{config}{site}{$site_name};

#curl 'https://elearning.uh.edu/webapps/portal/execute/tabs/tabAction'
	#-H 'Host: elearning.uh.edu' -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:38.0) Gecko/20100101 Firefox/38.0 Iceweasel/38.1.0'
	#-H 'Accept: text/javascript, text/html, application/xml, text/xml, */*'
	#-H 'Accept-Language: en-US,en;q=0.5' --compressed
	#-H 'X-Requested-With: XMLHttpRequest'
	#-H 'X-Prototype-Version: 1.7'
	#-H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8'
	#-H 'Referer: https://elearning.uh.edu/webapps/portal/execute/tabs/tabAction?tab_tab_group_id=_42_1'
	#-H 'Cookie: JSESSIONID=1F14C1D728E6F0351B0FD77A506AF97E; WT_FPC=id=129.7.17.210-429430192.30138273:lv=1313766009687:ss=1313765734969; NSC_fmfbsojoh.vi.fev-wt-iuuqt=ffffffffaf1d26b845525d5f4f58455e445a4a4229a1; _ga=GA1.2.130375019.1442506897; JSESSIONID=5B31C74E1DB6CC18246CFA66E75EB4BE; session_id=E4807C9B6CCF4DF81EF641784FC50189; s_session_id=3A27517595A8B79567C7D2D69F6A0DC5; web_client_cache_guid=b4d7780d-917f-4126-a2ca-52318b30cf31'
	#-H 'Connection: keep-alive'
	#-H 'Pragma: no-cache'
	#-H 'Cache-Control: no-cache'
	#--data 'action=refreshAjaxModule&modId=_25_1&tabId=_27_1&tab_tab_group_id=_42_1'
	#https://elearning.uh.edu/webapps/portal/execute/tabs/tabAction?tab_tab_group_id=_42_1
	my $login_input_xpath='//input[@name="user_id"]'; # needed to login
	if(eval { $mech->xpath($login_input_xpath, any => 1) } ) {
		$mech->submit_form( with_fields => {
			user_id => $cred->{username},
			password => $cred->{password},
		});
		DEBUG $mech->title;
		DEBUG "Logged in";
		#print $mech->content;
	}
}
