%% ============================================================
%%  generators.pl  --  .clp file generators (standalone tool)
%%
%%  This is a separate tool, NOT part of the RProlog application.
%%  The application (qclp_gates/) only ever reads .clp files; it has
%%  no knowledge of factor(N), queens(N), coloring(N) or any other
%%  named problem. This file is where such named / parametric
%%  problems are *defined*, as ordinary Prolog predicates that
%%  compute a list of fd_domain/fd_neq/... goals -- exactly what a
%%  hand-written problem_spec/1 in a .clp file contains -- and
%%  gen_clp/1,2 writes that list out as a .clp file.
%%
%%  Usage (from the project root):
%%
%%    ?- ['examples/generators'].
%%    ?- gen_clp(queens(6)).                  % examples/queens6.clp
%%    ?- gen_clp(factor(91), 'my/f91.clp').   % custom path
%%
%%  then, in the application:
%%
%%    ?- run('examples/queens6.clp').
%%
%%  Public API:
%%    fd_example(+Name, -Goals)   the generator predicates
%%    gen_clp(+Name)              write examples/<name>.clp
%%    gen_clp(+Name, +File)       write to File
%% ============================================================

:- module(generators, [
    fd_example/2,
    gen_clp/1,
    gen_clp/2
]).

:- use_module(library(lists)).

:- discontiguous fd_example/2.
:- dynamic fd_example/2.

%% ============================================================
%%  Built-in FD example programs
%%  fd_example(+Name, -Goals)
%%
%%  All parametric examples guard against uninstantiated args.
%% ============================================================

%% ---- simple_neq: x #\= y, x,y in 0..3 --------------------
fd_example(simple_neq, [
    fd_domain(x, 0, 3),
    fd_domain(y, 0, 3),
    fd_neq(x, y)
]).

%% ---- sum_eq: x + y #= 5, x,y in 0..4 ---------------------
fd_example(sum_eq, [
    fd_domain(x, 0, 4),
    fd_domain(y, 0, 4),
    fd_sum_eq(x, y, 5)
]).

%% ---- pythagorean(Max): a+b=c in 1..Max -------------------
%%  Guard: Max must be a positive integer.
%%  Note: a+b=c is a proxy constraint (not true a^2+b^2=c^2,
%%  which requires multiplier gates not yet in the gate set).
fd_example(pythagorean(Max), Goals) :-
    ( integer(Max), Max > 1 ->
        Goals = [
            fd_domain(a, 1, Max),
            fd_domain(b, 1, Max),
            fd_domain(c, 2, Max),
            fd_sum_eq(a, b, c)
        ]
    ;   format("ERROR: pythagorean(Max) requires integer Max > 1.~n"),
        fail
    ).

%% ---- queens(N): N-queens ------------------------------------
%%  Each queen's column is a variable q0..q(N-1) with domain 0..N-1.
%%  (queen i is in row i, column qi)
%%
%%  Constraints:
%%    - all_different(q0..q(N-1))   -- no two queens share a column
%%    - for each pair (i,j), i<j, on diagonal offset D=j-i:
%%        qj + D != qi   AND   qi + D != qj
%%      (no two queens share a diagonal)
%%
%%  Guard: N must be an integer >= 2.
fd_example(queens(N), Goals) :-
    integer(N), N >= 2,
    N1 is N - 1,
    make_vars(q, N, 0-N1, QVars, DomainGoals),
    DiagCons = fd_all_different(QVars),
    pairwise_diagonals(QVars, DiagPairCons),
    flatten([DomainGoals, DiagCons, DiagPairCons], Goals).

%%  pairwise_diagonals(+Vars, -Cons)
%%  For each pair (Qi, Qj), i<j, with diagonal offset D = j-i,
%%  generate:  Qj + D != Qi   and   Qi + D != Qj
pairwise_diagonals(Vars, Cons) :-
    pairwise_diagonals(Vars, 1, Cons).

pairwise_diagonals([], _, []).
pairwise_diagonals([Qi|Qs], D0, Cons) :-
    diagonal_row(Qi, Qs, D0, RowCons),
    pairwise_diagonals(Qs, D0, RestCons),
    append(RowCons, RestCons, Cons).

%%  diagonal_row(+Qi, +Rest, +StartOffset, -Cons)
%%  Qi paired with each Qj in Rest, offsets StartOffset, StartOffset+1, ...
diagonal_row(_, [], _, []).
diagonal_row(Qi, [Qj|Qs], D,
              [fd_sum_neq(Qj, D, Qi), fd_sum_neq(Qi, D, Qj) | Cons]) :-
    D1 is D + 1,
    diagonal_row(Qi, Qs, D1, Cons).


%% ---- coloring(N): 3-colouring of complete graph K_N --------
%%  Each node gets a colour variable c0..c(N-1) with domain 0..2.
%%  K_N = complete graph, so every pair of nodes is an edge:
%%  no two adjacent nodes may share a colour.
%%
%%  Constraints:
%%    - for each pair (i,j), i<j:  ci != cj
%%
%%  Guard: N must be an integer >= 2.
fd_example(coloring(N), Goals) :-
    integer(N), N >= 2,
    make_vars(c, N, 0-2, CVars, DomainGoals),
    pairwise_neq(CVars, EdgeCons),
    append(DomainGoals, EdgeCons, Goals).

%%  pairwise_neq(+Vars, -Cons)
%%  fd_neq(Vi, Vj) for every pair (i,j), i<j.
pairwise_neq([], []).
pairwise_neq([V|Vs], Cons) :-
    maplist([W, fd_neq(V,W)]>>true, Vs, RowCons),
    pairwise_neq(Vs, RestCons),
    append(RowCons, RestCons, Cons).


%% ---- make_vars: shared variable/domain generator -------------
%%
%%  make_vars(+Prefix, +N, +Low-High, -Vars, -DomainGoals)
%%
%%  Prefix:  atom prefix for variable names (e.g. c, q, x)
%%  N:       number of variables to create
%%  Low-High: domain bounds, inclusive (e.g. 0-2 or 0-7)
%%  Vars:    [Prefix0, Prefix1, ..., Prefix(N-1)]
%%  DomainGoals: [fd_domain(Prefix0,Low,High), ...]
make_vars(Prefix, N, Low-High, Vars, DomainGoals) :-
    N1 is N - 1,
    numlist(0, N1, Idxs),
    maplist(make_var(Prefix, Low, High), Idxs, Vars, DomainGoals).

make_var(Prefix, Low, High, I, V, fd_domain(V, Low, High)) :-
    format(atom(V), "~w~w", [Prefix, I]).

%% ---- send_more_money ----------------------------------------
%%  SEND + MORE = MONEY (units column constraint as proxy).
fd_example(send_more_money, [
    fd_domain(s, 1, 9),
    fd_domain(e, 0, 9),
    fd_domain(n, 0, 9),
    fd_domain(d, 0, 9),
    fd_domain(m, 1, 9),
    fd_domain(o, 0, 9),
    fd_domain(r, 0, 9),
    fd_domain(y, 0, 9),
    fd_all_different([s,e,n,d,m,o,r,y]),
    fd_sum_eq(e, d, y)   %% units column: E + D = Y (mod 10 carry omitted)
]).

%% ---- factor(N): find p,q such that p*q = N -----------------
%%  Uses fd_product_eq to search for factor pairs via Grover.
%%  This is a Grover search -- quadratic speedup, not Shor.
%%  For optimal quantum factoring use shor(factor(N)).
%%  Guard: N must be a composite integer > 1.
fd_example(factor(N), Goals) :-
    ( integer(N), N > 1 ->
        High is N - 1,
        Goals = [
            fd_domain(p, 2, High),
            fd_domain(q, 2, High),
            fd_product_eq(p, q, N)
        ]
    ;   format("ERROR: factor(N) requires composite integer N > 1.~n"),
        fail
    ).

%% ============================================================
%%  gen_clp/1,2  --  write a generator's Goals out as a .clp file
%%
%%  gen_clp(+Name)        default file: examples/<name>.clp
%%  gen_clp(+Name, +File) explicit path
%%
%%  Looks Name up via fd_example/2 and writes a problem_spec/1 term
%%  in the exact format the application's read_problem_spec/2
%%  (qclp_gates/rp_spec.pl) reads back. The written file is an
%%  ordinary .clp file: from then on the application treats it
%%  exactly like one written by hand.
%% ============================================================

gen_clp(Name) :-
    default_clp_file(Name, File),
    gen_clp(Name, File).

gen_clp(Name, File) :-
    ( catch(fd_example(Name, Goals), _, fail) ->
        ensure_dir_for_file(File),
        setup_call_cleanup(
            open(File, write, Stream),
            write_problem_spec(Stream, Name, Goals),
            close(Stream)
        ),
        length(Goals, N),
        format("[gen] .clp written: ~w  (~w goal(s))~n", [File, N])
    ;   format("[gen] Unknown generator: ~q~n", [Name]),
        fail
    ).

%% default_clp_file(+Name, -File): queens(4) -> 'examples/queens4.clp'
default_clp_file(Name, File) :-
    term_to_atom(Name, Atom),
    atom_codes(Atom, Codes),
    include([C]>>( code_type(C, alnum) ; C == 95 ), Codes, Clean),
    atom_codes(Base, Clean),
    atomic_list_concat(['examples/', Base, '.clp'], File).

write_problem_spec(Stream, Name, Goals) :-
    format(Stream, "%% Generated by examples/generators.pl: gen_clp(~q).~n~n", [Name]),
    format(Stream, "problem_spec([~n", []),
    write_goals(Stream, Goals),
    format(Stream, "]).~n", []).

write_goals(_, []).
write_goals(Stream, [G]) :- !,
    format(Stream, "    ~q~n", [G]).
write_goals(Stream, [G|Gs]) :-
    format(Stream, "    ~q,~n", [G]),
    write_goals(Stream, Gs).

%% ensure_dir_for_file(+File)
%%   Create File's directory component if it doesn't exist yet,
%%   (make_directory only creates one level).
ensure_dir_for_file(File) :-
    file_directory_name(File, Dir),
    ( ( Dir == '' ; Dir == '.' ) -> true
    ; exists_directory(Dir) -> true
    ; catch(
          ( make_directory(Dir),
            format("  [created ~w directory]~n", [Dir]) ),
          _,
          true)
    ).
