%% ============================================================
%%  rp_commands.pl  --  Clean command interface for RProlog
%%
%%  All predicates are exported to the user module.
%%  Call them directly from the Prolog top-level.
%%
%%  This module knows only about .clp files -- nothing here has
%%  any knowledge of the built-in generators (factor(N), queens(N),
%%  coloring(N), ...). Those live entirely in examples/generators.pl,
%%  a separate tool outside the running application; generate a
%%  file with it first, then run that file here:
%%
%%    ?- ['examples/generators'].
%%    ?- gen_clp(queens(4), 'examples/queens4.clp').
%%    (separately, in this application)
%%    ?- run('examples/queens4.clp').
%%
%%  Commands:
%%    run(File)        Grover search (unknown M) on the fast simulator
%%                     of the circuit's oracle
%%    run(File,Opts)   backend(exact) runs the search on the real gates
%%    solve(File)      Classical reference solver (with costs per solution)
%%    info(File)       Qubit/iteration statistics
%%    show(File)       Deep dive (microcode + QASM preview)
%%    export(File)     Write QASM to qasm/<basename>.qasm
%%    export(File,Out) Write QASM to custom file
%%    top(N)           Show top N states from last simulation
%%    top              Show top 10 states
%%    decode(Text)     Decode simulator output (|...> lines) or an index
%%    decode(Text,F)   ... using circuit/problem file F (.qasm or .clp)
%%    examples         List .clp files found in clp/ and examples/
%%    help             Show command summary
%%    set_qasm_dir(Dir) Change default QASM output directory
%% ============================================================

:- module(rp_commands, [
    run/1, run/2, run_qasm/1, run_qasm/2, solve/1, info/1, show/1,
    export/1, export/2, export/3,
    top/0, top/1,
    decode/1,
    decode/2,
    examples/0,
    help/0,
    set_qasm_dir/1
]).

:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(rp_fd, [
    rp_fd_compile/2, rp_fd_info/1, rp_fd_solve/2, rp_fd_solve/3,
    rp_fd_oracle_mc/2, fd_domain_size/2
]).
:- use_module(rp_grover, [rp_grover_info/1, rp_grover_qasm/2, rp_grover_write/2]).
:- use_module(rp_engine, [rp_show/1]).
:- use_module(rp_namer,  [rp_rename/2]).
:- use_module(rp_spec,   [load_spec/2]).
:- use_module(rp_decode, [run_qasm/1, run_qasm/2, decode_state/1, decode_state/2]).
%% load_spec/2 (rp_spec.pl) is the single place that resolves a
%% Source into a Goals list -- Source must be a path to a .clp
%% file, full stop. It already prints a clear error message and
%% fails cleanly otherwise. solve/1, info/1, show/1 and export/2
%% below call it directly and build their FDSpec on the spot,
%% rather than forwarding to a same-shaped predicate of a
%% different name in another module -- there used to be a
%% separate rp_fd_demo.pl whose entire job was renaming/
%% re-dispatching these four commands (e.g.
%% solve(Example) :- rp_fd(solve(Example))); that module has
%% been folded in here so the real logic lives directly under the
%% name the user calls.
:- use_module(qsim_pp_grover, [grover_top/1]).
:- use_module(rp, [run_pcode/1, run_pcode/2]).
%% rp:run_pcode/1,2 is imported module-qualified, on purpose, and is
%% used only by run/1,2 below. It is NOT also loaded unqualified
%% into `user` (load.pl no longer does that) -- this module is the
%% single route into the FD/Grover pipeline for the end user; rp.pl
%% is internal engine plumbing, not a second command surface.
:- use_module(sv_run, [qsim_run/2]).

%% ============================================================
%%  Default output directory
%% ============================================================

:- dynamic qasm_dir/1.
qasm_dir('qasm/').

set_qasm_dir(Dir) :-
    retractall(qasm_dir(_)),
    assert(qasm_dir(Dir)),
    format("QASM directory set to ~w~n", [Dir]).

%% ============================================================
%%  Help and examples
%% ============================================================

help :-
    format("~n~`=t~60|~n"),
    format("  QCLP_G commands (available at the Prolog prompt)~n"),
    format("~`=t~60|~n"),
    format("  run(File)           Grover search, number of solutions unknown, on~n"),
    format("                      the fast simulator of the circuit's oracle~n"),
    format("  run(File,Opts)      seed(S), top(N), shots(N), analysis(true),~n"),
    format("                      iterations(K): run K iterations, no search~n"),
    format("                      backend(exact): the search on the real gates~n"),
    format("  run_qasm(Qasm)      run an exported circuit as written: shots,~n"),
    format("  run_qasm(Qasm,Opts) each decoded and checked (shots(N), top(N),~n"),
    format("                      analysis(true) = simulator-only full state)~n"),
    format("  solve(File)         CLASSICAL reference solver (not used by the~n"),
    format("                      quantum paths)~n"),
    format("  info(File)          qubits, register states, default iterations~n"),
    format("  show(File)          deep dive: oracle microcode + QASM preview~n"),
    format("  export(File)        write QASM to qasm/<basename>.qasm~n"),
    format("  export(File,Out)    write QASM to custom file~n"),
    format("  export(File,Out,[iterations(K)])  choose the iteration count~n"),
    format("  top(N)              show top N states from last simulation~n"),
    format("  top                 show top 10 states~n"),
    format("  decode(Text)        decode simulator output, e.g.~n"),
    format("                      decode('  |0000000053>  25/100 (25.0%)')~n"),
    format("  decode(Text,File)   ... for circuit File (.qasm or .clp)~n"),
    format("  examples            list .clp files in clp/ and examples/~n"),
    format("  help                this list~n"),
    format("  set_qasm_dir(Dir)   change QASM output directory~n~n"),
    format("  File is always a path to a .clp file. To generate one from a~n"),
    format("  built-in generator (factor(N), queens(N), coloring(N), ...):~n"),
    format("    ?- ['examples/generators'].~n"),
    format("    ?- gen_clp(queens(4), 'examples/queens4.clp').~n"),
    format("~`=t~60|~n~n").

%% examples/0 -- lists .clp files actually present in clp/ and
%% examples/, rather than a hardcoded list of names. This
%% application has no built-in knowledge of any specific problem;
%% whatever .clp files exist on disk are what can be run.
examples :-
    format("~n.clp files found:~n"),
    ( list_clp_files('clp') ; true ),
    ( list_clp_files('examples') ; true ),
    format("~n  Run any of these with e.g. run('clp/queens4.clp').~n"),
    format("  To generate more from a built-in parametric family~n"),
    format("  (factor(N), queens(N), coloring(N), pythagorean(Max)):~n"),
    format("    ?- ['examples/generators'].~n"),
    format("    ?- gen_clp(queens(6), 'examples/queens6.clp').~n~n").

list_clp_files(Dir) :-
    exists_directory(Dir), !,
    atom_concat(Dir, '/*.clp', Pattern),
    expand_file_name(Pattern, Files),
    ( Files == [] -> true
    ; forall(member(F, Files), format("  ~w~n", [F]))
    ).
list_clp_files(_).

%% ============================================================
%%  Core commands
%%
%%  Each command's real logic lives directly here, under its
%%  final name -- no separate dispatcher module and no term-based
%%  redispatch (there used to be an rp_fd(Cmd) layer in between;
%%  see the note above load_spec/2's import for why it's gone).
%%  run/1,2 is the one exception: it forwards to run_pcode/1,2 (rp.pl)
%%  or, with backend(exact), to rp_decode:exact_search/2.
%% ============================================================

run(Example) :- run(Example, []).

%% run/2 -- Opts:
%%   backend(exact)   use the real gate-level statevector simulator
%%                    (qsim_run/2) instead of the fast pcode-direct
%%                    Grover approximation. Exports QASM first, so
%%                    remaining Opts (shots(N), amplitudes(true),
%%                    output_reg(N), ...) are passed straight to
%%                    qsim_run/2. This replaces what used to be a
%%                    separate top-level predicate, rp_run_fd/1,2 in
%%                    load.pl -- "which simulator" is now one option
%%                    on the one run/2 entry point, not a second
%%                    parallel pipeline.
%%   top(N)           passed through to the default (fast) backend;
%%                    how many states to show after simulation [5]
run(Example, Opts) :-
    ( memberchk(backend(exact), Opts) ->
        exclude(==(backend(exact)), Opts, SimOpts),
        %% Exponential search with unknown M on the gate-level
        %% simulator (rp_decode:exact_search/2). No classical solve.
        rp_decode:exact_search(Example, SimOpts)
    ;   run_pcode(Example, Opts)
    ).

%% solve(Example): classical constraint solve only.
%% For very large search spaces, caps at 20 solutions rather than
%% enumerating the whole space.
solve(Example) :-
    ( var(Example) ->
        format("ERROR: solve(Example) needs a specific example.~n")
    ;   once((
            load_spec(Example, Goals),
            rp_fd_compile(Goals, FDSpec),
            FDSpec = fd_spec(Domains, _),
            maplist(fd_domain_size, Domains, Sizes),
            foldl([S,A,P]>>(P is A*S), Sizes, 1, N),
            ( N > 100_000 ->
                format("~n  Search space: ~w states -- showing first 20 solutions.~n", [N]),
                rp_fd_solve(FDSpec, 20, solutions(Solutions, Flag)),
                length(Solutions, NSols),
                format("  Solutions (~w, ~w):~n", [NSols, Flag])
            ;   rp_fd_solve(FDSpec, Solutions),
                length(Solutions, NSols),
                format("~n  Classical solutions (~w):~n", [NSols])
            ),
            (   rp_fd:has_cost_constraints(FDSpec), Solutions \== []
            ->  %% fd_cost: the cost of each solution, and the minimum
                maplist([Sol, C-Sol]>>(rp_fd:eval_cost(FDSpec, Sol, C)), Solutions, CS),
                forall(member(C-Sol, CS), print_solution_cost(Sol, C)),
                pairs_keys(CS, Cs), min_list(Cs, Min),
                findall(Sol, member(Min-Sol, CS), Best), length(Best, NB),
                format("~n  Minimum cost ~w (~w solution(s)):~n", [Min, NB]),
                maplist(print_solution, Best),
                ( Flag == capped -> format("  (among the solutions listed only)~n") ; true )
            ;   maplist(print_solution, Solutions)
            ),
            nl
        ))
    ).

print_solution_cost(Assignment, C) :-
    format("    "),
    maplist([V-Val]>>(format("~w=~w  ", [V, Val])), Assignment),
    format(" cost ~w~n", [C]).

%% info(Example): qubit/iteration stats only.
info(Example) :-
    ( var(Example) ->
        format("ERROR: info(Example) needs a specific example.~n")
    ;   once((
            load_spec(Example, Goals),
            rp_fd_compile(Goals, FDSpec),
            rp_fd_info(FDSpec),
            rp_grover_info(FDSpec),
            %% say now if run/export will refuse the problem
            ignore(rp_grover:circuit_supported(FDSpec))
        ))
    ).

%% show(Example): deep dive -- info + oracle microcode + solutions
%% + QASM preview (first 40 lines).
show(Example) :-
    ( var(Example) ->
        format("ERROR: show(Example) needs a specific example.~n")
    ;   once(show_(Example))
    ).

show_(Example) :-
    load_spec(Example, Goals),   %% prints its own error and fails if unknown
    rp_fd_compile(Goals, FDSpec),
    rp_fd_info(FDSpec),
    rp_grover_info(FDSpec),
    %% No microcode or QASM for a problem the circuit cannot compile
    %% (it used to print an oracle that left the constraint out).
    rp_grover:circuit_supported(FDSpec),
    %% The circuit's oracle: clues substituted, range checks added
    rp_grover:rp_grover_circuit_spec(FDSpec, circuit(CSpec, _, _)),
    rp_fd_oracle_mc(CSpec, RawMC),
    rp_rename(RawMC, OracleMC),
    format("~n-- Oracle Microcode (circuit) --~n"),
    rp_show(OracleMC),
    format("~n-- Grover QASM (first 40 lines) --~n"),
    rp_grover_qasm(FDSpec, Lines),
    length(Lines, Total),
    ( Total > 40 ->
        length(Head, 40),
        append(Head, _, Lines),
        maplist(writeln, Head),
        More is Total - 40,     % was printed unevaluated: "(296-40 more lines"
        format("  ... (~w more lines, use export(...) for full file)~n",
               [More])
    ;   maplist(writeln, Lines)
    ).

print_solution(Assignment) :-
    format("    "),
    maplist([V-Val]>>(format("~w=~w  ", [V, Val])), Assignment),
    nl.

%% export/1 and /2
export(Example) :-
    default_filename(Example, qasm_dir, '.qasm', File),
    export(Example, File).

export(Example, File) :- export(Example, File, []).

%% export(+File, +Out, +Opts): Opts may hold iterations(K), the number
%% of Grover iterations written into the circuit. Default: the optimum
%% for one marked state (the number of solutions is not computed).
export(Example, File, Opts) :-
    ( var(Example) ->
        format("ERROR: export(Example,File) needs a specific example.~n")
    ;   once(export_(Example, File, Opts))
    ).

export_(Example, File, Opts) :-
    load_spec(Example, Goals),
    rp_fd_compile(Goals, FDSpec),
    rp_grover:circuit_supported(FDSpec),
    %% Record the source file so rp_grover_qasm can annotate the
    %% generated QASM with a "// Example: ..." header comment.
    nb_setval(qsim_current_example, Example),
    rp_grover:rp_grover_write(FDSpec, File, Opts),
    %% decode/1 now refers to this circuit
    rp_demo:qasm_path(File, Path),
    catch(rp_decode:set_decode_context(Path, Example), _, true).

%% Post-simulation commands
top(N) :- catch(grover_top(N), _, format("No simulation result available. Run a simulation first.~n")).
top    :- top(10).

%% decode(Text), decode(Text, File): see rp_decode:decode_state/1,2.
decode(Text) :- once(decode_state(Text)).
decode(Text, File) :- once(decode_state(Text, File)).

%% ============================================================
%%  Helpers
%% ============================================================

%% default_filename(+File, +DirPred, +Ext, -Out)
%%  DirPred is a predicate like qasm_dir/1 that gives the directory.
%%  File is always a .clp path (see load_spec/2); Out's basename is
%%  derived from it.
default_filename(File, DirPred, Ext, Out) :-
    call(DirPred, Dir),
    file_base_name(File, Base0),
    file_name_extension(Base1, _, Base0),
    atom_codes(Base1, Codes),
    include([C]>>( code_type(C, alnum) ; C == 95 ), Codes, CleanCodes),
    atom_codes(Base, CleanCodes),
    atomic_list_concat([Dir, Base, Ext], Out).

%% ============================================================
%%  Load-time announcement
%% ============================================================

:- format("~nQCLP_G commands loaded. Type help. for usage.~n").