# NAME

mccs - Fully-featured static file server.

# SYNOPSIS

        # serve current working directory over HTTP, port 5000
    $ mccs

        # serve a directory on port 80 using Starman
        $ mccs -s Starman --listen :80 /some/directory

        # serve without minification, compression, or etag creation
        $ mccs --no-minify --no-compress --no-etag

# DESCRIPTION

`mccs` is an HTTP static file server that can be used as a standalone
application, or as a [Plack](https://metacpan.org/pod/Plack) component. It features automatic compression and
serving of files; automatic minification of CSS and JavaScript files; and correct
handling of HTTP negotiation and cache headers.

`mccs` retains minified and compressed representations of files so subsequent
requests to the same files will serve them when appropriate, reducing CPU load.
These files are automatically rotated if the originals are modified.

The `mccs` command line application is an extension of [plackup](https://metacpan.org/pod/plackup), and accepts
the same command line flags and options. It is recommended to use an HTTP server
such as [Twiggy](https://metacpan.org/pod/Twiggy) or [Starman](https://metacpan.org/pod/Starman) in a production setting.

For information on how to use `mccs` as a library or in Plack applications, see
[Plack::App::MCCS](https://metacpan.org/pod/Plack%3A%3AApp%3A%3AMCCS) and [Plack::Middleware::MCCS](https://metacpan.org/pod/Plack%3A%3AMiddleware%3A%3AMCCS).

## HOW DOES IT WORK?

When a request is accepted by the server, the following process is initiated:

- 1. Discovery:

    `mccs` attempts to find the requested path in the root directory. If the
    path is not found, `404 Not Found` is returned. If the path exists but
    is a directory, `403 Forbidden` is returned (directory listings are currently
    not supported).

- 2. Examination:

    `mccs` will try to find the content type of the file, either by its extension
    (relying on [Plack::MIME](https://metacpan.org/pod/Plack%3A%3AMIME) for that), or by a specific setting provided
    to the app by the user (will take precedence). If not found (or file has
    no extension), `text/plain` is assumed (which means you should give your
    files proper extensions if possible).

    `mccs` will also determine for how long to allow clients (whether browsers,
    proxy caches, etc.) to cache the file. By default, it will set a representation
    as valid for 86400 seconds (i.e. one day). However, this can be changed either
    by setting a different global validity interval, or by setting a specific value
    for certain file types.

    By default, `mccs` also sets the `public` option for the `Cache-Control`
    header, meaning caches are allowed to save responses even when authentication is
    performed. You can change that the same way.

- 3. Minification

    If the content type is `text/css` or `application/javascript`, `mccs` will
    try to find a pre-minified version of it on disk. If found, and the version is
    younger than the original file, then it will be marked for serving. Otherwise,
    if [CSS::Minifier::XS](https://metacpan.org/pod/CSS%3A%3AMinifier%3A%3AXS) or [JavaScript::Minifier:XS](https://metacpan.org/pod/JavaScript%3A%3AMinifier%3AXS) are installed, `mccs`
    will minify the file, save the minified version to disk, and mark it as the
    version to serve. Future requests to the same file will see the minified version
    and not minify again.

    `mccs` searches for files that end with `.min.css` and `.min.js`, and that's
    how it creates them too. If a request comes to `style.css`, for example, then
    `mccs` will look for `style.min.css`, possibly creating it if not found or
    stale. The request path remains the same (`style.css`) though, even internally.
    If a request comes to `style.min.css` (which you don't really want when
    using `mccs`), the app will not attempt to minify it again (so you won't
    get things like `style.min.min.css`).

    If `min_cache_dir` is specified, it will do all its searching and storing of
    generated minified files within `$root`/`$min_cache_dir` and ignore minified
    files outside that directory.

- 4. Compression

    If the client supports compressed responses (via the gzip, deflate or
    zstd algorithms), as noted by the `Accept-Encoding` header, `mccs` will try to
    find a precompressed version of the file on disk. If found, and is not stale,
    this version is marked for serving. Otherwise, if the appropriate compression
    module is installed, `mccs` will compress the file, save the compressed version
    to disk, and mark it as the version to serve. Future requests to the same file
    will see the compressed version and not compress again.

    `mccs` searches for files that end with the appropriate extension for the
    algorithm (i.e. `.gz`, `.zip`, `.zstd`), and that's how it creates them too.
    If a request comes to `style.css` from a client that prefers gzip responses,
    for example, and the file was minified in the previous step, `mccs` will look
    for `style.min.css.gz`, possibly creating it if not found. The request path
    remains the same (`style.css`) though, even internally.

    `mccs` honors weight values supplied in the `Accept-Encoding` header, and will
    serve using the highest-weighted algorithm it supports.

- 5. Cache Validation

    If the client provided the `If-Modified-Since` header, `mccs` will determine
    if the file we're serving has been modified after the supplied date, and return
    `304 Not Modified` immediately if not.

    If file doesn't have the 'no-store' cache control option, and the client
    provided the `If-None-Match` header, `mccs` will look for a file that has the
    the same name as the file we're going to serve, plus an `.etag` suffix, such
    as `style.min.css.gz.etag`, for example. If found, and not stale, the content
    of this file is read and compared with the provided ETag. If the two values are
    equal, `mccs` will immediately return `304 Not Modified`.

- 6. ETagging

    If an `.etag` file wasn't found in the previous step, and the file we're
    serving doesn't have the 'no-store' cache control option, `mccs` will create
    one from the file's inode, last modification date and size. Future requests
    to the same file will see this ETag file, so it is not created again.

- 7. Headers and Cache-Control

    `mccs` now sets headers, especially cache control headers, as appropriate:

    - `Content-Encoding` is set to the compression algorithm used, if any.
    - `Content-Length` is set with the size of the file in bytes.
    - `Content-Type` is set with the MIME type of the file (if a text file,
    the character string is appended, e.g. `text/css; charset=UTF-8`).
    - `Last-Modified` is set with the last modification date of the file in
    HTTP date format.
    - `Expires` is set with the date on which cached versions should expire—as
    determined in stage 2—in HTTP date format.
    - `Cache-Control` is set with the number of seconds the representation is
    valid for (unless caching of the file is not allowed) and other options, as
    determined in stage 2.
    - `Etag` is set with the ETag value (if exists).
    - `Vary` is set with `Accept-Encoding`.

- 8. Serving

    The selected file is served to the client.

# CAVEATS AND THINGS TO CONSIDER

- You can't tell `mccs` not to minify/compress a specific file type, but
only disable minification/compression altogether.
- Directory listings are not supported.
- Caching middlewares such as [Plack::Middleware::Cache](https://metacpan.org/pod/Plack%3A%3AMiddleware%3A%3ACache) and [Plack::Middleware::Cached](https://metacpan.org/pod/Plack%3A%3AMiddleware%3A%3ACached)
don't rely on Cache-Control headers (or so I understand) for
their expiration values, which makes them less useful for applications that
rely on [Plack::App::MCCS](https://metacpan.org/pod/Plack%3A%3AApp%3A%3AMCCS) or [Plack::Middleware::MCCS](https://metacpan.org/pod/Plack%3A%3AMiddleware%3A%3AMCCS). You'll probably be
better off with an external cache like [Varnish](https://www.varnish-cache.org/)
if you want a cache on your application server. Even without a server cache, your
application should still appear faster for users due to browser caching (and
also CPU load should be decreased).
- `Range` requests are not supported. See [Plack::App::File::Range](https://metacpan.org/pod/Plack%3A%3AApp%3A%3AFile%3A%3ARange) if
you need that.
- The app is mounted on a directory and can't be set to only serve
requests that match a certain regular expression. Use the
[middleware](https://metacpan.org/pod/Plack%3A%3AMiddleware%3A%3AMCCS) for that.

# DIAGNOSTICS

`mccs` doesn't directly throw any exceptions, instead returning HTTP errors
to the client and possibly issuing some `warn`s. The following list should
help you to determine some potential problems with `MCCS`:

- `"Failed compressing %s with %s: %s"`

    This warning is issued when `mccs` fails to compress a file with a certain
    algorithm. When it happens, a compressed representation will not be returned.

- `"Can't open ETag file %s.etag for reading"`

    This warning is issued when `mccs` can't read an ETag file, probably because
    it does not have enough permissions. The request will still be fulfilled,
    but it won't have the `ETag` header.

- `"Can't open ETag file %s.etag for writing"`

    Same as before, but when `mccs` can't write an ETag file.

- `403 Forbidden` is returned for files that exist

    If a request for a certain file results in a `403 Forbidden` error, it
    probably means `mccs` has no read permissions for that file.

# CONFIGURATION AND ENVIRONMENT

`mccs` requires no configuration files or environment variables.

# REQUIREMENTS

`mccs` **requires** the following dependencies:

- [Perl 5.36+](https://www.perl.org/)
- [HTTP::Date](https://metacpan.org/pod/HTTP%3A%3ADate)
- [Plack](https://metacpan.org/pod/Plack)

`mccs` will use the following CPAN modules if they exist:

- [CSS::Minifier::XS](https://metacpan.org/pod/CSS%3A%3AMinifier%3A%3AXS)
- [JavaScript::Minifier::XS](https://metacpan.org/pod/JavaScript%3A%3AMinifier%3A%3AXS)
- [IO::Compress::Zstd](https://metacpan.org/pod/IO%3A%3ACompress%3A%3AZstd)

The following CPAN modules are also recommended:

- [Twiggy](https://metacpan.org/pod/Twiggy) for an event-loop based HTTP server.
- [Starman](https://metacpan.org/pod/Starman) for a preforking HTTP server.

# INCOMPATIBILITIES WITH OTHER MODULES

None reported.

# BUGS AND LIMITATIONS

Please report any bugs or feature requests to `bug-Plack-App-MCCS@rt.cpan.org`,
or through the web interface at
[http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Plack-App-MCCS](http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Plack-App-MCCS).

# SEE ALSO

[Plack::App::MCCS](https://metacpan.org/pod/Plack%3A%3AApp%3A%3AMCCS), [Plack::Middleware::MCCS](https://metacpan.org/pod/Plack%3A%3AMiddleware%3A%3AMCCS), [Plack::Runner](https://metacpan.org/pod/Plack%3A%3ARunner), [plackup](https://metacpan.org/pod/plackup).

# AUTHOR

Ido Perlmuter <ido@ido50.net>

# ACKNOWLEDGMENTS

Some of this application's code is based on [Plack::App::File](https://metacpan.org/pod/Plack%3A%3AApp%3A%3AFile) by Tatsuhiko
Miyagawa and [Plack::Middleware::ETag](https://metacpan.org/pod/Plack%3A%3AMiddleware%3A%3AETag) by Franck Cuny.

Christian Walde contributed new features and fixes for the 1.0.0 release.

# LICENSE AND COPYRIGHT

Copyright (c) 2011-2023, Ido Perlmuter `ido@ido50.net`.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
