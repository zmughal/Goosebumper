package App::Goosebumper;

use warnings;
use 5.010;
use strict;
use utf8;

use YAML qw/LoadFile/;
use File::Path qw/make_path/;
use File::Spec;
use Data::Dumper;
use Log::Log4perl qw(:easy);
use App::Goosebumper::SitesHelper;

use constant CONFIG_DIR => "$ENV{HOME}/.goosebumper";

sub run {
	my $config_file = File::Spec->catfile(CONFIG_DIR,'config.yml');
	my $error_file = File::Spec->catfile(CONFIG_DIR, 'error_log');
	my $hash_config = LoadFile($config_file);

	if ($hash_config->{debug}) {
		Log::Log4perl->easy_init(
		        { file  => ">> $error_file", level => $ERROR, },
		        { file  => "STDERR", level => $DEBUG, }
		);
	} else {
		Log::Log4perl->easy_init(
		        { file  => ">> $error_file", level => $OFF, },
		        { file  => "STDERR", level => $OFF, }
		);
	}

	DEBUG "Loaded configuration: $config_file";
	App::Goosebumper::SitesHelper->new($hash_config)->start_screeching();
}

1;
