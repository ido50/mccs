package Plack::App::MCCS;

# ABSTRACT: Minify, Compress, Cache-control and Serve static files

our $VERSION = "0.001";
$VERSION = eval $VERSION;

use strict;
use warnings;
use parent qw/Plack::Component/;

use Cwd ();
use Fcntl qw/:flock/;
use File::Spec::Unix;
use HTTP::Date;
use Plack::MIME;
use Plack::Util;

use Plack::Util::Accessor qw/root defaults types encoding/;

sub call {
	my ($self, $env) = @_;

	# find the request file (or return error if occured)
	my $file = $self->_locate_file($env->{PATH_INFO});
	return $file if ref $file && ref $file eq 'ARRAY'; # error occured

	# determine the content type and extension of the file
	my ($content_type, $ext) = $self->_determine_content_type($file);

	# determine cache control for this extension
	my ($valid_for, $cache_control) = $self->_determine_cache_control($ext);

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

	# okay, time to serve the file (or not, depending on whether cache
	# validations exist in the request and are fulfilled)
	return $self->_serve_file($env, $file, $content_type, $valid_for, $cache_control);
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

sub _determine_cache_control {
	my ($self, $ext) = @_;

	# MCCS default values
	my $valid_for = 86400; # expire in 1 day by default
	my $cache_control = ['public']; # allow authenticated caching by default

	# user provided default values
	$valid_for = $self->defaults->{valid_for}
		if $self->defaults && defined $self->defaults->{valid_for};
	$cache_control = $self->defaults->{cache_control}
		if $self->defaults && defined $self->defaults->{cache_control};

	# user provided extension specific settings
	if ($ext) {
		$valid_for = $self->types->{$ext}->{valid_for}
			if $self->types && $self->types->{$ext} && defined $self->types->{$ext}->{valid_for};
		$cache_control = $self->types->{$ext}->{cache_control}
			if $self->types && $self->types->{$ext} && defined $self->types->{$ext}->{cache_control};
	}

	# unless cache control has no-store, prepend max-age to it
	my $cache = 1;
	foreach (@$cache_control) {
		if ($_ eq 'no-store') {
			undef $cache;
			last;
		}
	}
	unshift(@$cache_control, 'max-age='.$valid_for)
		if $cache;

	return ($valid_for, $cache_control);
}

sub _serve_file {
	my ($self, $env, $path, $content_type, $valid_for, $cache_control) = @_;

	# if we are serving a text file (including JSON/XML/JavaScript), append character
	# set to the content type
	$content_type .= '; charset=' . ($self->encoding || 'UTF-8')
		if $content_type =~ m!^(text/|application/(json|xml|javascript))!;

	# get the full path of the file
	my ($file) = $self->_full_path($path);

	# get file statistics
	my @stat = stat $file;

	# try to find the file's etag
	my $etag;
	if (-f "${file}.etag" && -r "${file}.etag") {
		if (open(ETag, '<', "${file}.etag")) {
			flock(ETag, LOCK_SH);
			$etag = <ETag>;
			chomp($etag);
			close ETag;
		} else {
			warn "Can't open ${file}.etag for reading";
		}
	} elsif (-f "${file}.etag") {
		warn "Can't open ${file}.etag for reading";
	}

	# did the client send cache validations?
	if ($env->{HTTP_IF_MODIFIED_SINCE}) {
		# okay, client wants to see if resource was modified

		# IE sends wrong formatted value (i.e. "Thu, 03 Dec 2009 01:46:32 GMT; length=17936")
		# - taken from Plack::Middleware::ConditionalGET
		$env->{HTTP_IF_MODIFIED_SINCE} =~ s/;.*$//;
		my $since = HTTP::Date::str2time($env->{HTTP_IF_MODIFIED_SINCE});

		# if file was modified on or before $since, return 304 Not Modified
		return $self->_not_modified_304
			if $stat[9] <= $since;
	}
	if ($etag && $env->{HTTP_IF_NONE_MATCH} && $etag eq $env->{HTTP_IF_NONE_MATCH}) {
		return $self->_not_modified_304;
	}

	# okay, we need to serve the file
	# open it first
	open my $fh, '<:raw', $file
		|| return $self->return_403;

	# add ->path attribute to the file handle
	Plack::Util::set_io_path($fh, Cwd::realpath($file));

	# did we find an ETag file earlier? if not, let's create one
	unless ($etag) {
		# following code based on Plack::Middleware::ETag by Franck Cuny

		# if the file was modified less than one second before the request
		# it may be modified in a near future, so we return a weak etag
		$etag = $stat[9] == time - 1 ? 'W/' : '';

		# add inode to etag
		$etag .= join('-', sprintf("%x", $stat[2]), sprintf("%x", $stat[9]), sprintf("%x", $stat[7]));

		# save etag to a file
		if (open(ETag, '>', "${file}.etag")) {
			flock(ETag, LOCK_EX);
			print ETag $etag;
			close ETag;
		} else {
			undef $etag;
			warn "Can't open ETag file ${file}.etag for writing";
		}
	}

	# set response headers
	my $headers = [];
	push(@$headers, 'Content-Encoding' => 'gzip') if $path =~ m/\.gz$/;
	push(@$headers, 'Content-Length' => $stat[7]);
	push(@$headers, 'Content-Type' => $content_type);
	push(@$headers, 'Last-Modified' => HTTP::Date::time2str($stat[9]));
	push(@$headers, 'Expires' => $valid_for >= 0 ? HTTP::Date::time2str($stat[9]+$valid_for) : HTTP::Date::time2str(0));
	push(@$headers, 'Cache-Control' => join(', ', @$cache_control));
	push(@$headers, 'ETag' => $etag) if $etag;
	push(@$headers, 'Vary' => 'Accept-Encoding');

	# respond
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

sub _not_modified_304 {
	[304, [], []];
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
