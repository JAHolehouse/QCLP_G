%% ============================================================
%%  rp_spec.pl  --  File-based FD spec loader for RProlog
%%
%%  Loads .clp files using the same problem_spec/1 format as QCLP.
%%
%%  A .clp file contains:
%%    problem_spec([
%%        fd_domain(x, 0, 3),
%%        fd_neq(x, y),
%%        ...
%%    ]).
%%
%%  This module -- and everything built on it (rp_commands.pl,
%%  rp.pl) -- knows only about .clp files. It has no knowledge of
%%  built-in generator names like factor(N)/queens(N)/coloring(N):
%%  those live entirely in examples/generators.pl, a separate tool
%%  outside the application, whose only connection to the running
%%  system is that gen_clp/2 writes an ordinary .clp file that
%%  load_spec/2 can then read like any other. Generate the file
%%  first, then point the application at it:
%%
%%    ?- ['examples/generators'].
%%    ?- gen_clp(queens(4), 'examples/queens4.clp').
%%    (separately, in the running application)
%%    ?- run('examples/queens4.clp').
%%
%%  Public API:
%%    load_spec(+Source, -Goals)
%%      Source is a path to a .clp file.
%%
%%    spec_to_fdspec(+Goals, -FDSpec)
%%      Compile a Goals list to an fd_spec/2 term.
%%
%%    read_problem_spec(+File, -Goals)
%%      Read problem_spec/1 from a .clp file.
%% ============================================================

:- module(rp_spec, [
    load_spec/2,
    spec_to_fdspec/2,
    read_problem_spec/2
]).

:- use_module(library(lists)).
:- use_module(rp_fd, [rp_fd_compile/2]).

%% ============================================================
%%  load_spec(+Source, -Goals)
%%
%%  Source must be a path to a .clp file. Prints a clear error and
%%  fails cleanly if it isn't one, or if it doesn't parse.
%% ============================================================

load_spec(Source, Goals) :-
    ( atom(Source), file_name_extension(_, clp, Source) ->
        read_problem_spec(Source, Goals)
    ;
        format("[rp] ERROR: not a .clp file: ~q~n", [Source]),
        format("[rp]   The application only runs .clp files. To run a~n"),
        format("[rp]   built-in generator like factor(N) or queens(N),~n"),
        format("[rp]   first generate one with examples/generators.pl:~n"),
        format("[rp]     ?- ['examples/generators'].~n"),
        format("[rp]     ?- gen_clp(~q, 'examples/name.clp').~n", [Source]),
        fail
    ).

%% ============================================================
%%  read_problem_spec(+File, -Goals)
%%
%%  Read a problem_spec/1 term from a .clp file.
%%  Mirrors the QCLP convention exactly.
%% ============================================================

read_problem_spec(File, Goals) :-
    ( exists_file(File) -> true
    ;   format("[rp] ERROR: file not found: ~w~n", [File]), fail
    ),
    setup_call_cleanup(
        open(File, read, Stream),
        read_spec_from_stream(Stream, Goals),
        close(Stream)
    ).

read_spec_from_stream(Stream, Goals) :-
    read_terms_from_stream(Stream, Terms),
    ( member(problem_spec(Goals), Terms) -> true
    ;   format("[rp] ERROR: no problem_spec/1 found in file~n"), fail
    ),
    (   ground(Goals) -> true
    ;   format("[rp] ERROR: problem_spec contains an anonymous variable '_'; give every variable a name~n"),
        fail
    ).

%%  Each term is read with its variable names, and every named Prolog
%%  variable is bound to its own name as an atom. QCLP files may write
%%  variable names capitalised (StartA, M, N); Prolog reads those as
%%  logic variables, which no constraint could then refer to by name
%%  (previously bestcost/test5/test6 silently had 0 solutions). Now
%%  StartA simply becomes the name 'StartA'.
read_terms_from_stream(Stream, Terms) :-
    read_term(Stream, T, [module(user), variable_names(Names)]),
    maplist([Name=Var]>>(Var = Name), Names),
    ( T == end_of_file -> Terms = []
    ;   Terms = [T|Rest],
        read_terms_from_stream(Stream, Rest)
    ).

%% ============================================================
%%  spec_to_fdspec(+Goals, -FDSpec)
%%
%%  Thin wrapper around rp_fd_compile/2.
%% ============================================================

spec_to_fdspec(Goals, FDSpec) :-
    rp_fd_compile(Goals, FDSpec).
