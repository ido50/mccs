package Plack::App::MCCS;

# ABSTRACT: Minify, Compress, Cache and Serve static files

our $VERSION = "0.001";
$VERSION = eval $VERSION;

use strict;
use warnings;
use parent qw/Plack::Component/;
use File::Spec::Unix;
use Cwd ();
use Plack::Util;
use Plack::MIME;
use HTTP::Date;

use Plack::Util::Accessor qw/root types encoding/;

sub call {
	my ($self, $env) = @_;

	# find the request file (or return error if occured)
	my $file = $self->_locate_file($env->{PATH_INFO});
	return $file if ref $file && ref $file eq 'ARRAY';

	# determine the content type and extension of the file
	my ($content_type, $ext) = $self->_determine_content_type($file);

	# if this is a CSS/JS file, see if a minified representation of
	# it exists
	if ($content_type eq 'text/css' | $content_type eq 'application/javascript') {
		my $new = $file;
		$new =~ s/\.(css|js)$/.min.$1/;
		my $min = $self->_locate_file($new);
		if ($min && !ref $min) {
			# yes, we found it, set min as the new file
			$file = $min;
		}
	}

	# search for a gzipped version of this file
	my $comp = $self->_locate_file($file.'.gz');
	if ($comp && !ref $comp) {
		# good, we found a compressed version
		$file = $comp;
	}

	# okay, time to serve the file
	return $self->_serve_file($file, $content_type);
}

sub _locate_file {
	my ($self, $path) = @_;

	# does request have a sane path?
	$path ||= '';
	return $self->_bad_request_400
		if $path =~ m/\0/;

	my ($full, $path_arr) = $self->_full_path($path);

	# do not allow traveling up in the directory chain
	return $self->_forbidden_403
		if grep { $_ eq '..' } @$path_arr;

	if (-f $full) {
		# this is a file, is it readable?
		return -r $full ? $path : $self->_forbidden_403;
	} elsif (-d $full) {
		# this is a directory, we do not allow directory listing (yet)
		return $self->_forbidden_403;
	} else {
		# not found, return 404
		return $self->_not_found_404;
	}
}

sub _determine_content_type {
	my ($self, $file) = @_;

	# determine extension of the file and see if application defines
	# a content type for this extension (will even override known types)
	my ($ext) = ($file =~ m/(\.[^.]+)$/);
	if ($ext && $self->types && $self->types->{$ext} && $self->types->{$ext}->{content_type}) {
		return ($self->types->{$ext}->{content_type}, $ext);
	}

	# okay, no specific mime defined, let's use Plack::MIME to find it
	# or fall back to text/plain
	return (Plack::MIME->mime_type($file) || 'text/plain', $ext)
}

sub _serve_file {
	my ($self, $path, $content_type) = @_;

	# if we are serving a text file (including JSON/XML/JavaScript), append character
	# set to the content type
	$content_type .= '; charset=' . ($self->encoding || 'UTF-8')
		if $content_type =~ m!^(text/|application/(json|xml|javascript))!;

	# get the full path of the file
	my ($file) = $self->_full_path($path);

	# open the file
	open my $fh, '<:raw', $file
		|| return $self->return_403;

	# get file statistics
	my @stat = stat $file;

	# add ->path attribute to the file handle
	Plack::Util::set_io_path($fh, Cwd::realpath($file));

	# set response headers
	my $headers = [];
	push(@$headers, 'Content-Encoding' => 'gzip') if $path =~ m/\.gz$/;
	push(@$headers, 'Content-Length' => $stat[7]);
	push(@$headers, 'Content-Type' => $content_type);
	push(@$headers, 'Last-Modified' => HTTP::Date::time2str($stat[9]));

	return [200, $headers, $fh];
}

sub _full_path {
	my ($self, $path) = @_;

	my $docroot = $self->root || '.';

	# break path into chain
	my @path = split('/', $path);
	if (@path) {
		shift @path if $path[0] eq '';
	} else {
		@path = ('.');
	}

	return (File::Spec::Unix->catfile($docroot, @path), \@path);
}

sub _bad_request_400 {
	[400, ['Content-Type' => 'text/plain', 'Content-Length' => 11], ['Bad Request']];
}

sub _forbidden_403 {
	[403, ['Content-Type' => 'text/plain', 'Content-Length' => 9], ['Forbidden']];
}

sub _not_found_404 {
	[404, ['Content-Type' => 'text/plain', 'Content-Length' => 9], ['Not Found']];
}

1;
__END__
