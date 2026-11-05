%% ============================================================
%%  qclp_gates/load.pl  --  QCLP_G core (formerly RProlog)
%%
%%  Loads the core quantum compiler, FD constraint system,
%%  gate library, and statevector simulator.
%%
%%  Usage:
%%    swipl --stack_limit=256M
%%    ?- [load].
%%
%%  rp_commands is the supported interface -- everything below
%%  is available directly at the Prolog prompt once loaded:
%%    ?- help.
%%    ?- examples.                        % list .clp files available
%%    ?- run('clp/queens4.clp').
%%    ?- solve('clp/queens4.clp').
%%    ?- export('clp/queens4.clp').       % -> qasm/queens4.qasm
%%    ?- run('clp/tiny_neq.clp', [backend(exact)]).  % real gate-level sim
%%                                                 % instead of the fast
%%                                                 % pcode-direct Grover
%%                                                 % approximation
%%
%%  The application only ever runs .clp files. To create one from a
%%  named/parametric problem (factor(N), queens(N), ...), use the
%%  separate generator tool -- it is not loaded here:
%%    ?- ['examples/generators'].
%%    ?- gen_clp(queens(6)).             % writes examples/queens6.clp
%%
%%  rp_commands.pl is the ONLY supported route into this. The
%%  engine modules behind it (rp.pl, rp_fd.pl, rp_grover.pl, ...)
%%  are internal and not meant to be called directly.
%%
%%  Statevector simulator:
%%    ?- qsim_run("qasm/simple_neq.qasm").
%%
%%  Test suite:
%%    ?- rp_test.
%%    ?- rp_test(full).
%% ============================================================

:- prolog_load_context(directory, Dir), nb_setval(rprolog_dir, Dir).
rp_dir(Dir) :- nb_getval(rprolog_dir, Dir).

load_rp_module(Name) :-
    rp_dir(Dir),
    atomic_list_concat([Dir,'/',Name,'.pl'], Path),
    ( exists_file(Path)
    ->  use_module(Path)
    ;   format("  WARNING: ~w.pl not found~n", [Name])
    ).

%% --- Core meta-interpreter and arithmetic ---
:- load_rp_module(rp_engine).
:- load_rp_module(rp_namer).
:- load_rp_module(rp_arith).
:- load_rp_module(rp_fold).
:- load_rp_module(rp_ite).

%% --- Gate library ---
:- load_rp_module(rp_gates).
:- load_rp_module(rp_costs).

%% --- Structured QASM emitter (hardware-target output) ---
:- load_rp_module(rp_grover).

%% --- FD constraint compiler + Grover circuit generator ---
:- load_rp_module(rp_fd).

%% --- Macro post-processors (loaded after their dependencies) ---
%%     qsim_pp_grover needs rp_fd
:- load_rp_module(qsim_pp_grover).

%% --- Pcode interpreter + tests ---
:- load_rp_module(rp_pcode).
:- load_rp_module(rp_pcode_test).

%% --- Supporting modules ---
:- load_rp_module(rp_demo).
:- load_rp_module(rp_ui).

%% --- Statevector simulator ---
:- load_rp_module(sv_util).
:- load_rp_module(sv_sim).
:- load_rp_module(sv_run).
:- load_rp_module(qasm3_macro_pp).

%% --- Test suite ---
:- load_rp_module(rp_test).

%% --- File-based spec loader ---
%%     rp.pl (the FD pipeline engine) is loaded automatically as a
%%     dependency of rp_commands.pl below, module-qualified -- it is
%%     deliberately NOT loaded here with load_rp_module/1, which
%%     would import its run_pcode/1,2 unqualified into `user` and
%%     reopen a second, parallel route to the same functionality
%%     alongside rp_commands' run/1,2.
:- load_rp_module(rp_spec).

%% ============================================================
%%  Command interface
%%
%%  rp_commands is the ONLY supported way to interact with
%%  QCLP_G interactively. The old REPL (rp_repl.pl / ?- repl.)
%%  has been removed; use the predicates below directly at the
%%  Prolog prompt instead (run/1,2, solve/1, info/1, show/1,
%%  export/1,2, top/0,1, decode/1, examples/0, help/0).
%% ============================================================
:- load_rp_module(rp_commands).
:- use_module(rp_commands, [
    run/1, run/2, run_qasm/1, run_qasm/2, solve/1, info/1, show/1,
    export/1, export/2, export/3,
    top/0, top/1,
    decode/1,
    examples/0,
    help/0,
    set_qasm_dir/1
]).
:- format("~nQCLP_G loaded.  Type  info.  for more information.~n").