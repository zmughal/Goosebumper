package App::Goosebumper::SitesHelper;

use strict;
use warnings;

use YAML qw/LoadFile DumpFile/;
use Log::Log4perl qw(:easy);

use WWW::Mechanize::Firefox;
use WWW::Mechanize;

use File::Spec;
use File::Path qw/make_path/;
use IO::File;
use Fcntl qw(:flock);

use Module::Load;
use Carp;

use constant CACHEDIR => '.gbumper';

# NOTE this depends on the namespace
use constant SITES_PACKAGE => 'App::Goosebumper::Sites::';

sub new {
	my ($class, $config) = @_;
	ref($class) and croak "class name needed";
	my $self = {
		config => $config,
		toplevel => $class->_get_toplevel_dir($config),
	};
	bless $self, $class;
}

sub start_screeching {
	my ($self) = @_;
	my $toplevel = $self->{toplevel};
	DEBUG "Toplevel directory \"$toplevel\"";
	make_path($toplevel);
	for my $site (keys %{$self->{config}{sites}}) {
		my $plugin = SITES_PACKAGE.$site;
		DEBUG "Loading plugin: $plugin";
		load $plugin;
		$plugin->new($self)->screech();
	}
	$self->run_exit_handlers();
}

sub strip_sites {
	my $self = shift;
	my $package_name = shift;
	my $sites_prefix = SITES_PACKAGE;
	$package_name =~ s/$sites_prefix//;
	return $package_name;
}

sub start_firefox {
	my ($self) = @_;
	my $mech = WWW::Mechanize::Firefox->new(
		launch => ['firefox','-no-remote','-P','scraper'],
		activate => 1,
		autoclose => 0
	);
	sleep 10;

	my $prefs = $mech->repl->expr(<<'JS');
	Components.classes["@mozilla.org/preferences-service;1"]
	.getService(Components.interfaces.nsIPrefBranch);
JS

	$prefs->setBoolPref("dom.disable_open_during_load", 0);

	if (!$self->{config}{debug}) {
		unless($self->{_set_mech_handler}) {
			$self->{_set_mech_handler} = 1;
			$self->add_exit_handler( sub {
				$mech->repl->expr('window.close()');
			} );
		}
	}
	return $mech;
}

sub credentials {
	my $self = shift;
	my $site_name = shift;
	return $self->{config}{sites}{$site_name};
}

sub read_cache {
	my $self = shift;
	my $site_name = shift;
	make_path($self->_get_cache_dirname());

	my $cache;
	$cache->{file} = $self->_get_cache_fname($site_name);
	$cache->{fh} = IO::File->new( $cache->{file}, O_CREAT|O_WRONLY|O_APPEND );
	if ( flock( $cache->{fh}, Fcntl::LOCK_EX | Fcntl::LOCK_NB ) ) {
		# lock succeeded
		$cache->{content} = LoadFile($cache->{file});
		$cache->{content}{site_name} = $site_name;
	} else {
		# invalid
		die "could not lock file $cache->{file}";
		$cache = undef;
	}

	return $cache;
}

sub write_cache {
	my $self = shift;
	my $cache = shift;
	my $ext = '';
	unless( flock( $cache->{fh} , LOCK_UN ) ) {
		warn "Cannot unlock cache, writing to file with .err extension - $!\n"; # unlock
		$ext = ".err";
	}
	# write anyway to save state
	DumpFile($cache->{file}.$ext, $cache->{content});
	return;
}

sub get_file_list_path {
	my ($self, $file_list, $path) = @_;
	my $c = $file_list; # list of files for the course
	for my $d (@$path) {
		# follow the path from the files in the list
		return undef unless defined $c;
		my @dir = grep { $_->{name} == $d } @$c;
		die "Multiple directories with name $d" if scalar @dir != 1;
		$c = $dir[0]->{child}; # child file list
	}
	$c = [] unless defined $c;
	return $c;
}

sub _get_save_path {
	my ($self, $site_name, $course, $path) = @_;
	my $toplevel = $self->{toplevel};
	my $sfn = _sitename_fname($site_name);
	my $cfn = _course_fname($course);
	return File::Spec->($toplevel, $cfn, $sfn, @$path);
}

sub download_cache {
	my ($self, $site) = @_;
	DEBUG "Beginning to download";
	for my $course (keys %{$site->{cache}{content}{courses}}) {
		DEBUG "Download course $course";
		my $down_dir = File::Spec->catfile($self->{toplevel},
			$self->_course_fname($course),
			$self->_sitename_fname($site->{site_name}));
		make_path($down_dir);
		my $files = $site->{cache}{content}{courses}{$course}{files};
		$self->_download_cache_h($site, $down_dir, $files);
	}
}

sub _download_cache_h {
	my ($self, $site, $top, $files) = @_;
	DEBUG "Downloading to $top";
	for my $file (@$files) {
		DEBUG "File ", $file->{label};
		if( $file->{files} ) {
			# is a directory
			my $subtop = File::Spec->catfile($top, $file->{label});
			make_path($subtop);
			$self->_download_cache_h($site, $subtop, $file->{files});
		} elsif ( $file->{href} ) {
			unless ( $file->{downloaded} ) {
				unless ( $file->{href} =~ /\.mov$/ ) {
					# not a video
					my $response;
					my $worked;
					unless( exists $file->{response} ) {
						# TODO: instead of assumming this exists use an interface
						my $down_mech = $site->{down_mech};
						my $href = $file->{href};
						DEBUG "Attempting to download: $href";
						$response = $down_mech->get($href);
						$worked = $down_mech->success();
					} else {
						$response = $file->{response};
						delete $file->{response};
						$worked = defined $response;
					}
					if( $worked ) {
						my $fname = $response->filename;

						unless ($fname) {
							# use the filename given if can not resolve a filename
							# (TODO: when it doesn't exist use href)
							$fname = $file->{filename};
						} else {
							# store the filename
							$file->{filename} = $fname;
						}
						next unless $fname;	# still no filename, so it is not a file

						if ( $response->content_type ) {
							$file->{header}{'Content-Type'} = $response->content_type;
						}
						if( $response->date() )
						{
							$file->{header}{'Date'} = $response->date();
						}
						if( $response->last_modified() ) {
							$file->{header}{'Last-Modified'} = $response->last_modified();
						}
						my $save_path = File::Spec->catfile($top, $fname);
						eval {
							open( my $fh, '>', $save_path ) or die( "Unable to create $save_path: $!" );
							binmode $fh unless ($file->{header}{'Content-Type'} // '' ) =~ m{^text/};
							print {$fh} $response->content or die( "Unable to write to $save_path: $!" );
							close $fh or die( "Unable to close $save_path: $!" );
						};
						if ($@) {
							warn $@;
						} else {
							$file->{downloaded} = 1;
							$file->{path} = $save_path;
							# Read-only
							chmod 0444, $file->{path};
						}
					} else {
						warn "Could not download ", $file->{filename};
					}
				}
			}
		}
	}
}

# find the file(s) in the cache that matches a particular K-V
sub find_file {
	my ($self, $cache, $course, $path, $key, $value) = @_;
	my $file_list = $cache->{content}{courses}{$course}; # list of files for the course
	$file_list = get_file_list_path($file_list, $path);
	return undef if scalar @$file_list == 0; # empty list
	# now at the list of files at the path
	return [ grep { $_->{$key} eq $_->{$value} } @$file_list ];
}

# returns the directory for the cache under the download directory
sub _get_cache_dirname {
	my ($self) = @_;
	return File::Spec->catfile($self->{toplevel}, CACHEDIR);
}

sub get_course_dir {
	my ($self, $config, $course) = @_;
	return File::Spec->catfile( $self->{toplevel}, 
		_course_fname($course) );
}

sub _get_toplevel_dir {
	my ($self, $config) = @_;
	my $dir = scalar glob $config->{download_directory};
	length $dir == 0 and die "no download directory specified";
	return $dir;
}

# get a specific cache file for a site
sub _get_cache_fname {
	my ($self, $site_name) = @_;
	my $cache_dir = $self->_get_cache_dirname();
	my $cache_file = File::Spec->catfile($cache_dir,
		$self->_sitename_fname($site_name).".yml");
	return $cache_file;
}

# turn the plugin name to a something appropriate for a file
sub _sitename_fname {
	my ($self, $site) = @_;
	$site =~ s/::/-/g;
	return $site;
}

# turn the course name into something appropriate for a file
sub _course_fname {
	my ($self, $site) = @_;
	$site =~ s/ /_/g;
	return $site;
}

sub add_exit_handler {
	my ($self, $code) = @_;
	push @{$self->{atexit}}, $code;
}

sub run_exit_handlers {
	my $self = shift;
	$_->() for @{$self->{atexit}};
}


1;
