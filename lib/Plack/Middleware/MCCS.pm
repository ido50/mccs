package Plack::Middleware::MCCS;

use v5.36;

our $VERSION = "2.001000";
$VERSION = eval $VERSION;

use parent qw/Plack::Middleware/;

use Plack::App::MCCS;
use Plack::Util::Accessor qw/path root defaults types encoding min_cache_dir/;

=head1 NAME

Plack::Middleware::MCCS - Middleware for serving static files with mccs.

=head1 EXTENDS

L<Plack::Middleware>

=head1 SYNOPSIS

	# in your app.psgi:
	use Plack::Builder;

	builder {
		enable 'Plack::Middleware::MCCS',
			path => qr{^/static/},
			root => '/path/to/static_files';
		$app;
	};

=head1 DESCRIPTION

This package allows serving static files with L<mccs> in the form of a L<Plack>
middleware. It allows for more flexibility with regards to which paths are to be
served by C<mccs>, as it can serve requests based on regular expressions rather
than a path prefix.

=head1 CONFIGURATIONS

The only required configuration option is B<path>. You should either provide a
regular expression, or a subroutine to match against requests. For more info
about the C<path> option, look at L<Plack::Middleware::Static>, it's exactly the
same.

Other configuration options are those supported by L<Plack::App::MCCS>. None are
required, but you will mostly provide the C<root> option. If you do not provide
it, the current working directory is assumed. These are the supported options:

=over

=item * root

=item * defaults

=item * types

=item * encoding

=item * min_cache_dir

=item * index_files

=back

Refer to L<Plack::App::MCCS> for a complete explanation of them.

=head1 METHODS

=head2 call( \%env )

Attempts to handle a request by using Plack::App::MCCS.

=cut

sub call ( $self, $env ) {
    my $res = $self->_handle_static($env);

    return $res
      if $res && $res->[0] != 404;

    return $self->app->($env);
}

sub _handle_static ( $self, $env ) {
    return
      unless $self->path;

    my $path = $env->{PATH_INFO};

    for ($path) {
        my $matched =
          ref $self->path eq 'CODE'
          ? $self->path->( $_, $env )
          : $_ =~ $self->path;
        return unless $matched;
    }

    my %opts = ( root => $self->root || '.' );
    foreach (qw/defaults types encoding min_cache_dir/) {
        $opts{$_} = $self->$_
          if defined $self->$_;
    }

    $self->{mccs} ||= Plack::App::MCCS->new(%opts);

    local $env->{PATH_INFO} = $path;    # rewrite PATH

    return $self->{mccs}->call($env);
}

=head1 BUGS AND LIMITATIONS

Please report any bugs or feature requests to
C<bug-Plack-App-MCCS@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Plack-App-MCCS>.

=head1 SEE ALSO

L<mccs>, L<Plack::App::MCCS>.

=head1 AUTHOR

Ido Perlmuter <ido@ido50.net>

=head1 ACKNOWLEDGMENTS

This module is just an adapation of L<Plack::Middleware::Static> by Tatsuhiko
Miyagawa to use L<Plack::App::MCCS> instead.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2011-2023, Ido Perlmuter C<< ido@ido50.net >>.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut

1;
__END__
