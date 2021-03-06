OCaml CSV
=========

The [comma-separated values](http://en.wikipedia.org/wiki/Comma-separated_values)
format — or CSV for short — is a simple tabular format supported by
all major spreadsheets.  This library implements pure OCaml functions
to read and write files in this format (including Excel extensions) as
well as some convenience functions to manipulate such data.

Compile & install
-----------------

The easiest way to install this library is to use
[OPAM](http://opam.ocaml.org/):

    opam install csv

If you prefer to compile by hand, run

    ocaml setup.ml -configure
    ocaml setup.ml -build
    ocaml setup.ml -install

Note that This package uses [oasis](https://github.com/ocaml/oasis) to
generate its configure, build and install scripts.  However, you only
need `oasis` if you want to compile the development version.

Uninstall
---------

With OPAM:

    opam remove csv

Manually (from the source directory):

    ocaml setup.ml -uninstall
