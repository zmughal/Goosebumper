package App::Goosebumper::Site::UH::VNet;

use strict;
use warnings;
use App::Goosebumper::Site;
use App::Goosebumper::SiteHelper;

use Log::Log4perl qw(:easy);

use Data::Dumper;
use Carp;

use HTML::TreeBuilder;
use URI::Escape;

use 5.010;

my $url = "http://vnet.uh.edu/";

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

	my $mech = $site_helper->start_firefox();
	$self->{_mech} = $mech;

	$mech->get( $url );

	$self->_login();

	DEBUG "Getting cookies";
	my $cookies = $mech->cookies();
	# Transfer the cookies
	# Turn of host verification for SSL
	$self->{down_mech} = WWW::Mechanize ->new( cookie_jar => $cookies ,
		ssl_opts => { verify_hostname => 0 });

	my $files = $self->_visit_courses();
	print Dumper $self->{cache};
	$site_helper->download_cache($self);
	$site_helper->write_cache($self->{cache});
}

sub _login {
	my $self = shift;
	my $site_helper = $self->{_SiteHelper};
	my $site_name = $self->{site_name};
	my $mech = $self->{_mech};

	my $cred = $site_helper->credentials($site_name);
	#{ local $Data::Dumper::Indent = 0; local $Data::Dumper::Terse = 1;
	#DEBUG "We have the credentials ", Dumper $cred; }

	my $login_input_xpath='//input[@value="Login"]'; # needed to login
	if(eval { $mech->xpath($login_input_xpath, any => 1) } )
	{
		$mech->field( username => $cred->{username});
		$mech->field( password => $cred->{password});
		$mech->click( { xpath => $login_input_xpath });
	}
}

sub _visit_courses {
	my $self = shift;
	my $mech = $self->{_mech};

	my %course_h;
	$course_h{$_->{href}} = $_->{innerHTML} for $mech->xpath('//td[@colspan=4]/a');
	#DEBUG Dumper \%course_h;
	for my $course (keys %course_h) {
		my $course_name = $course_h{$course};
		$course_name =~ s/(.+?):.*/$1/;
		$mech->get($course);
		sleep 3;
		$self->_process_course($course_name);
	}
}

sub _process_course {
	my $self = shift;
	my $mech = $self->{_mech};

	my $course_name = shift;
	DEBUG "Processing course $course_name";

	$mech->follow_link( text => 'Documents' );
	$self->_recurse_dirstruct($course_name);
}

sub _recurse_dirstruct {
	my ($self, $course_name) = @_;
	my $files = $self->{cache}{content}{courses}{$course_name}{files} // [];
	$self->{cache}{content}{courses}{$course_name}{files} =	$self->_recurse_dirstruct_h($files);
}

sub _recurse_dirstruct_h {
	my $self = shift;
	my $files = shift;

	my $mech = $self->{_mech};

	my $can_go_up = 0;
	#for my $item ($mech->xpath('//tr[starts-with(@class,"data_folder_")]/td[position()=2]/a')) {
	for my $item ($mech->xpath('//tr[starts-with(@class,"data_folder_")]')) {
		my $row = $item->{innerHTML};
		my $row_tb = HTML::TreeBuilder->new;
		$row_tb->parse_content($row);
		my @columns = $row_tb->look_down("_tag", "td");

		my $name = $columns[1]->as_trimmed_text();
		my $hrefs = $columns[1]->extract_links();
		my($link, $element, $attr, $tag) = @{$hrefs->[0]};
		my $href = $link;

		my $type = $columns[2]->as_trimmed_text();
		$type =~ s/^[\s|\xA0]*//g;

		my $date = $columns[4]->as_trimmed_text();
		$date =~ s/^[\s|\xA0]*//g;

		DEBUG "Looking at file $name";
		if ($name eq '(...)') {
			$can_go_up = 1;
			next;
		}
		if ( $href =~ /resource_id/) {
			# a file
			unless( $name =~ /WATCH/ ) {
					unless( (grep { $_->{label} eq $name } @$files)[0] ) {
						my $hash = { label => $name , href => $href };
						$hash->{type} = $type if $type;
						$hash->{'date created'} = $date if $date;
						push @$files, $hash;
						DEBUG "Adding file $name";
					}
			} else {
				eval {
					$mech->follow_link( { xpath => "//a[contains(normalize-space(.),'$name')]", synchronize => 0 } ); # open pop-over
				};
				if($@) {
					DEBUG "File '$name' not found: $@\n";
					next;
				}

				sleep 2;
				DEBUG "Trying to find movie_player href";
				my $video = $mech->xpath('//a[contains(@href,"show_movie_player")]', single => 1);

				my $down_mech = $self->{down_mech};
				my $r = $down_mech->get( $video->{href} );
				my $html = $r->content();
				my $tb = HTML::TreeBuilder->new;
				$tb->parse_content($html);
				my $video_param = $tb->look_down ( "name", "src" );
				my $video_href = $video_param->attr("value");
				DEBUG Dumper $video_href;

				unless ( grep { $_->{label} eq $name } @$files ) {
					my $hash = { label => $name , href => $video_href };
					$hash->{type} = $type if $type;
					$hash->{'date created'} = $date if $date;
					push @$files, $hash;
					DEBUG "Adding file $name";
				}

				# close pop-over
				$mech->follow_link( { xpath => '//a[@class="closeIcon"]', synchronize =>  0 }  );
				sleep 2;
				#warn;
			}
		} else {
			$mech->get($href);
			my $find = (grep { $_->{label} eq $name } @$files)[0];
			unless ( $find ) {
				my $new_dir = { label => $name };
				$new_dir->{type} = $type if $type;
				$new_dir->{'date created'} = $date if $date;
				push @$files, $new_dir;
				$find = $new_dir;
			}
			my $subfiles = $find->{files} // [];
			$find->{files} = $self->_recurse_dirstruct_h($subfiles);
		}
	}
	$mech->follow_link( text => '(...)' ) if $can_go_up;
	return $files;
}

1;
