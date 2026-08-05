/** <module> The command.
 *
 *  `swipl -q -O -g main wolv.pl -- run prog.wol` runs the compiler from
 *  source; `make.sh` saves a state at `bin/wolv` that starts without loading
 *  the tree first.  `main/0` comes from library(main) and is what hands the
 *  arguments over.
 */

:- use_module(library(main)).
:- use_module('src/cli', []).

main(Argv) :- cli:main(Argv).
