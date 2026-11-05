%% ============================================================
%%  rp.pl  --  FD pipeline engine (internal)
%%
%%  This is the engine that rp_commands.pl's run/1,2 delegates to:
%%  Grover search with an unknown number of solutions on the fast
%%  simulator, whose oracle is the circuit's own microcode (pcode)
%%  over the circuit's register space (qsim_pp_grover.pl). It does
%%  NOT solve the problem classically first.
%%
%%  NOT a user-facing entry point. rp_commands.pl is the only
%%  supported way to control the application -- this module's
%%  run_pcode/1,2 (then called rprolog/1,2) used to also be loaded unqualified into `user`
%%  (a second, parallel route into the same functionality, with
%%  its own separate and partly broken help/list/solve/export
%%  surface -- rprolog(help) told users to call a nonexistent
%%  rp/2 predicate, and rprolog(solve, Source) silently misfired
%%  against the wrong clause before backtracking into the right
%%  one). All of that has been removed. rp_commands.pl now
%%  imports only run_pcode/1,2 directly, module-qualified, and nothing
%%  here is reachable from the top level any other way.
%% ============================================================

:- module(rp, [run_pcode/1, run_pcode/2]).

:- use_module(rp_spec,    [load_spec/2]).
:- use_module(rp_fd,      [rp_fd_compile/2]).
:- use_module(rp_grover,  []).
:- use_module(qsim_pp_grover, [grover_search/3, grover_show/1]).
:- use_module(library(lists)).

%% ============================================================
%%  run_pcode/1,2  --  Grover search on the fast simulator
%%  (named rprolog/1,2 before 1 Oct 2026)
%%
%%  Opts: top(N) [5], seed(S), budget(B), iterations(K), shots(N),
%%        analysis(true) -- see qsim_pp_grover.pl
%% ============================================================

run_pcode(Source) :- run_pcode(Source, []).

run_pcode(Source, Opts) :-
    %% load_spec/2 already prints its own diagnostic and fails
    %% cleanly for an unknown example or missing/malformed file --
    %% no need to print a second, generic message on top of it.
    %% Still catch genuinely unexpected exceptions so they get a
    %% proper report instead of an uncaught crash.
    catch(load_spec(Source, Goals), Error,
          (print_message(error, Error), fail)),
    rp_fd_compile(Goals, FDSpec),
    rp_run_spec(Source, FDSpec, Opts).

%% ============================================================
%%  rp_run_spec/3  --  run the pipeline on a compiled FDSpec
%% ============================================================

%% Largest number of register states run/1,2 will simulate (the fast
%% simulator works over the circuit's register space; see
%% qsim_pp_grover.pl). Same limit as QCLP_Q's gsim.
run_max_n(100000).

rp_run_spec(Source, FDSpec, Opts) :-
    format("~n[rp] ~w~n", [Source]),
    (   catch(rp_grover:rp_grover_circuit_spec(FDSpec, circuit(_, _, NCirc)), _, fail),
        run_max_n(MaxN), NCirc > MaxN
    ->  format("[rp] ERROR: the circuit has ~w register states; run/1,2 simulates at most ~w.~n", [NCirc, MaxN]),
        format("[rp]   info/1 and export/1,2,3 still work.~n"),
        format("[rp]   Tip: reduce domain sizes (the widest domain sets every register's width).~n"),
        fail
    ;   true
    ),
    grover_search(FDSpec, Opts, Result),
    %% decode/1 refers to this problem (keep a .qasm layout of the same
    %% problem if one is already set: it also checks the ancillas)
    (   catch(nb_getval(rp_decode_context, ctx(L, _, _, _, _, _, _)), _, fail),
        sub_atom(L, _, _, _, Source)
    ->  true
    ;   catch(rp_decode:set_decode_context(none, Source), _, true)
    ),
    (   ( Result = found(_, _, _) ; Result = fixed(_) )
    ->  grover_show(Opts)
    ;   Result \== refused
    ).

%% ============================================================
%%  Helpers
%% ============================================================

get_opt(Key, Opts, Default, Value) :-
    Opt =.. [Key, V],
    ( member(Opt, Opts) -> Value = V ; Value = Default ).
