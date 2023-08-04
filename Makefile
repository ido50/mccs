.PHONY: fmt
fmt: bin/mccs lib/Plack/App/MCCS.pm lib/Plack/Middleware/MCCS.pm
	carton exec perltidy -b -bext='/' -ce bin/mccs lib/Plack/App/MCCS.pm lib/Plack/Middleware/MCCS.pm
