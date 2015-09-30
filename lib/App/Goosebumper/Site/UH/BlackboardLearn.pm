package App::Goosebumper::Site::UH::BlackboardLearn;

use strict;
use warnings;
use App::Goosebumper::Site;
use App::Goosebumper::SiteHelper;

use WWW::Mechanize::Firefox;
use HTML::TreeBuilder::XPath;
use Log::Log4perl qw(:easy);
use HTML::FormatText;
use Try::Tiny;
use Path::Tiny;
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
	$self->{cache} = $site_helper->read_cache($self->{site_name});
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

	my @skip_pages = ("Discussions", "Messages", "Tools", "Calendar", "Course Calendar", "My Grades", "Groups");
	my %skip_pages;
	@skip_pages{@skip_pages} = (1)x@skip_pages;

	my $tree = HTML::TreeBuilder::XPath->new_from_content( $course_index->decoded_content );
	my $fmt = HTML::FormatText->new;

	# find the list of pages on the left-hand navbar (e.g. Announcements,
	# Course Information, Course Content, Course Calendar, Messages).
	my @page_nodes = $tree->findnodes('//div[@id = "navigationPane"]//a[@target="_self"]');
	for my $page_node ( @page_nodes ) {
		my $page_name = $page_node->as_trimmed_text;
		my $page_uri = $page_node->attr('href');

		if( exists $skip_pages{$page_name} ) {
			DEBUG "Skipping $page_name.";
			next;
		}

		# download the page
		my $page_response = $mech->get( $page_uri );

		my $page_tree = HTML::TreeBuilder::XPath->new_from_content( $page_response->decoded_content );

		my @page_path_breadcrumbs = $page_tree->findnodes('//div[@id="breadcrumbs"]//div[contains(@class,"path")]//ol/li');
		# we don't need the first item that is the course name
		shift @page_path_breadcrumbs if $page_path_breadcrumbs[0]->attr('class') =~ /root/;
		my @page_path = map { $_->as_trimmed_text } @page_path_breadcrumbs;
		my $page_path_dir = join '/', @page_path;

		my @lists;
		push @lists, $page_tree->findnodes('//ul[contains(@class,"contentList")]');
		push @lists, $page_tree->findnodes('//ul[contains(@class,"announcementList")]');

		my @vtbe = $page_tree->findnodes('//div[contains(@class,"vtbegenerated")]');

		if( @lists ) {
			DEBUG "Found @{[ scalar @lists ]} lists on $page_name";
			#use DDP; p @lists;
			for my $list (@lists) {
				my @list_items = $list->findnodes('./li');
				DEBUG "List @{[ $list->attr('class') ]} contains @{[ scalar @list_items ]} items on $page_name under $page_path_dir";
				for my $item (@list_items) {
					my @links = $item->findnodes('.//a');
					my %links_href = map { ( $_->attr('href') => $_->as_trimmed_text ) } @links;
					#use DDP; p %links_href;#DEBUG
					for my $link (@links) {
						my $link_href = $link->attr('href');
						my $link_href_abs = URI->new_abs( $link->attr('href'), $mech->base );
						my $link_text = $fmt->format($link);
						if( $link_href =~ m|listContent\.jsp| ) {
							# sub-page
							push @page_nodes, $link;
						} elsif( $link_href =~ m|^/bbcswebdav| ) {
							# file to download
							DEBUG "Will need to download: $link_text to $page_path_dir/$link_text";
							my $file_head = $mech->head( $link_href_abs );
							my @path = (@page_path, $file_head->filename);
							my $save_path = path( $self->{_SiteHelper}->_get_save_path( $self->{site_name}, $course->{course_dirname}, \@path) );
							if( -r $save_path ) {
								DEBUG "Already downloaded $link_text to $save_path from before.";
							} else {
								DEBUG "Saving to $save_path";
							}
							my $file_get = $mech->get( $link_href_abs );
							try {
								$save_path->parent->mkpath;
								open( my $fh, '>', $save_path ) or die( "Unable to create $save_path: $!" );
								binmode $fh unless ($file_get->content_type // '' ) =~ m{^text/};
								print {$fh} $file_get->content or die( "Unable to write to $save_path: $!" );
								close $fh or die( "Unable to close $save_path: $!" );
							} catch {
								warn $_;
							};
						}
					}
				}
			}
		} elsif( @vtbe ) {
			DEBUG "Found @{[ scalar @vtbe ]} vtbe paragraphs on $page_name under $page_path_dir";
		} else {
			DEBUG "No lists found on $page_name under $page_path_dir";
		}

	}
	#use DDP; p @pages;




	#my @div_info;
	#for my $div (@divs) {
		#push @div_info, {
			#node => $div,
			#( id => $div->attr('id') )x!!( $div->attr('id')  ),
			#( class => $div->attr('class') )x!!( $div->attr('class')  ),
			#text => $fmt->format($div),
		#};
	#}

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
