#!perl

use Test::More;
use Plack::Test;
use Plack::App::MCCS;
use HTTP::Request;
use Data::Dumper;

# named params
test_psgi
	app => Plack::App::MCCS->new(
		root => 't/rootdir',
		types => {
			'.less' => {
				content_type => 'text/stylesheet-less',
			},
		},
	)->to_app,
	client => sub {
		my $cb = shift;

		# let's request mccs.png and see we're getting it
		my $req = HTTP::Request->new(GET => '/mccs.png');
		my $res = $cb->($req);
		is($res->code, 200, 'Found mccs.png');
		is($res->header('Content-Type'), 'image/png', 'Received proper content type for mccs.png');
		ok(!$res->header('Content-Encoding'), 'mccs.png is not gzipped');
		is($res->header('Content-Length'), 44152, 'Received proper content length for mccs.png');
		ok($res->header('Last-Modified'), 'Received a last-modified header for mccs.png');

		# let's request style.css and see we're getting a minified, gzipped version
		$req = HTTP::Request->new(GET => '/style.css');
		$res = $cb->($req);
		is($res->code, 200, 'Found style.css');
		is($res->header('Content-Type'), 'text/css; charset=UTF-8', 'Received proper content type for style.css');
		is($res->header('Content-Encoding'), 'gzip', 'Received gzipped representation of style.css');
		is($res->header('Content-Length'), 152, 'Received proper content length for style.css');

		# let's request script.js and see we're getting a gzipped version
		$req = HTTP::Request->new(GET => '/script.js');
		$res = $cb->($req);
		is($res->code, 200, 'Found script.js');
		is($res->header('Content-Type'), 'application/javascript; charset=UTF-8', 'Received proper content type for script.js');
		is($res->header('Content-Encoding'), 'gzip', 'Received gzipped representation of script.js');

		# let's request style.less and see we're getting a proper content type (even though it's fake)
		$req = HTTP::Request->new(GET => '/style2.less');
		$res = $cb->($req);
		is($res->code, 200, 'Found style2.less');
		is($res->header('Content-type'), 'text/stylesheet-less; charset=UTF-8', 'Received proper content type for style2.less');
		is($res->content, <<LESS
body {
	width: 100%;
	height: 100%;

	> header {
		height: 130px;
		background-color: #000;
	}

	> article {
		color: lighten('#fff', 100%); // a dumb way to get #000
	}

	> footer {
		a {
			color: #999;
			text-decoration: none;

			&:hover {
				text-decoration: underline;
			}
		}
	}
}
LESS
		, 'Received proper content for style2.less');

		# let's request a file that does not exist
		$req = HTTP::Request->new(GET => '/i_dont_exist.txt');
		$res = $cb->($req);
		is($res->code, 404, 'Non-existant file returns 404');

		# let's try to trick the server into letting us view other directories
		$req = HTTP::Request->new(GET => '/../../some_important_file_with_password');
		$res = $cb->($req);
		is($res->code, 403, 'Forbidden to climb up the tree');

		# let's see the app falls back to text/plain when file has
		# no extension
		$req = HTTP::Request->new(GET => '/text');
		$res = $cb->($req);
		is($res->code, 200, 'Found text file');
		is($res->header('Content-Type'), 'text/plain; charset=UTF-8', 'text file has proper text/plain content type');

		# let's try to get a directory and see we're getting 403 Forbidden
		$req = HTTP::Request->new(GET => '/dir');
		$res = $cb->($req);
		is($res->code, 403, 'Not allowed to get directories');

		# let's get a file in a subdirectory
		$req = HTTP::Request->new(GET => '/dir/subdir/smashingpumpkins.txt');
		$res = $cb->($req);
		is($res->code, 200, 'Found file in a subdirectory');
		is($res->content, "The Smashing Pumpkins\n", 'file in a subdirectory has correct content');
	};

done_testing();
