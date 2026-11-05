%% ============================================================
%%  sv_run.pl  --  Quantum circuit simulator driver (was qsim.pl)
%%
%%  Standalone application.  No dependency on RProlog.
%%  Reads a QASM 3.0 file and simulates it.
%%
%%  Usage from the command line:
%%    swipl sv_run.pl -- circuit.qasm
%%    swipl sv_run.pl -- circuit.qasm --shots 1000
%%    swipl sv_run.pl -- circuit.qasm --amplitudes
%%
%%  Usage from the SWI-Prolog REPL:
%%    ?- [sv_run].
%%    ?- qsim_run("circuit.qasm").
%%    ?- qsim_run("circuit.qasm", [shots(100)]).
%%    ?- qsim_run("circuit.qasm", [amplitudes(true)]).
%%    ?- qsim_run("circuit.qasm", [output_reg(2)]).
%%
%%  Options:
%%    shots(N)          -- sample N times and show histogram
%%    amplitudes(true)  -- show full amplitude listing
%%    probabilities(true) -- show probabilities (default)
%%    output_reg(Bits)  -- read Bits-wide result register from
%%                         qubit 0 upward and display its value
%%
%%  The simulator (sv_sim) is a complete statevector engine.
%%  It handles all standard QASM 3.0 gates:
%%    x, h, z, s, t, sdg, tdg, cx, cz, ccx, swap
%%    rx(theta), ry(theta), rz(theta), p(theta)
%%    ctrl @ x, ctrl @ ctrl @ x, ...
%% ============================================================

:- module(sv_run, [
    qsim_run/1,
    qsim_run/2,
    qsim_run_sv/2,
    qsim_run_string/1,
    qsim_run_string/2,
    qasm3_nqubits_from_file/2,
    qasm3_nqubits_from_string/2
]).

%% Sibling modules are loaded relative to THIS file's directory (that
%% is how use_module/1 resolves a relative name), so this works however
%% sv_run is reached: from either package's load.pl, or standalone as
%% `swipl sv_run.pl -- circuit.qasm`. (The previous loader read the
%% global rprolog_dir, threw when it was unset, and fell back to a
%% non-existent module name, sv_sim_util.)
%% qasm3_macro_pp expands gate macros / for-loops before every sv_sim
%% run (see qsim_run_sv/2 below) -- sv_sim's QASM3 reader only
%% understands flat primitive-gate programs.
:- use_module(sv_util).
:- use_module(sv_sim).
:- use_module(qasm3_macro_pp).


:- nb_setval(qsim_current_example, none).

%% ============================================================
%%  Public API
%% ============================================================

%%  qsim_run(+File)
qsim_run(File) :-
    qsim_run(File, []).

%%  qsim_run(+File, +Options)
%%  Gate-level simulation via sv_sim.  Only handles flat QASM
%%  (primitive gates, no gate definitions/macros/for-loops) --
%%  qsim_run_sv/2 always macro-expands (qasm3_macro_pp) before
%%  handing the program to sv_sim, so callers do not need to
%%  pre-flatten files themselves.
%%  For FD/Grover circuits, use qsim_pp_grover:run_fdspec/2
%%  on the FDSpec directly -- the pcode interpreter, not the
%%  compiled QASM, is the simulation input.
qsim_run(File, Opts) :-
    nl,
    qsim_run_sv(File, Opts).

%%  qsim_run_sv(+File, +Opts):
%%  Resolves File, reads it, ALWAYS runs it through the
%%  qasm3_macro_pp expander (unrolling for-loops and inlining gate
%%  macros) and then simulates the expanded program directly from
%%  memory via qsim_run_text/3 -- no intermediate flattened
%%  ".qasm" file is ever written to disk.
qsim_run_sv(File, Opts) :-
    %% Resolve file: check cwd, then qasm/ subdirectory, then fail
    ( exists_file(File) ->
        ResolvedFile = File
    ; atomic_list_concat(['qasm/', File], QasmPath),
      exists_file(QasmPath) ->
        ResolvedFile = QasmPath
    ;
        format("ERROR: file not found: ~w (also tried qasm/~w)~n", [File, File]),
        fail
    ),
    !,   %% commit: no backtracking
    read_file_to_string(ResolvedFile, RawSrc, []),
    qasm3_macro_pp:qasm3_expand_string(RawSrc, FlatSrc),
    qsim_run_text(ResolvedFile, FlatSrc, Opts).

%%  qsim_run_string(+QasmText)
%%  qsim_run_string(+QasmText, +Opts)
%%  Simulate QASM 3.0 source text that is ALREADY IN MEMORY (an
%%  atom or string) -- e.g. the output of qasm3_macro_pp's
%%  expander, or hand-written QASM a caller already has loaded.
%%  Always macro-expands first, then simulates directly via
%%  sv_sim. No file is read or written -- this never produces an
%%  intermediate flattened file on disk.
qsim_run_string(QasmText) :-
    qsim_run_string(QasmText, []).
qsim_run_string(QasmText, Opts) :-
    nl,
    qasm3_macro_pp:qasm3_expand_string(QasmText, FlatSrc),
    qsim_run_text('<in-memory text>', FlatSrc, Opts).

%%  qsim_run_text(+Label, +FlatText, +Opts)
%%  Shared tail end of the pipeline: FlatText is already fully
%%  macro-expanded QASM 3.0 source (an atom or string). Simulates
%%  it directly via sv_sim, entirely in memory -- no file I/O.
qsim_run_text(Label, FlatText, Opts) :-
    ( Label == '<in-memory text>' -> true
    ; format("[qsim] Loading: ~w~n", [Label])
    ),
    atom_string(QasmAtom, FlatText),
    sv_run_qasm(QasmAtom, FinalState),
    qasm3_nqubits_from_string(FlatText, NQ),
    format("[qsim] ~w qubits simulated~n~n", [NQ]),
    display_results(FinalState, NQ, Opts).

%% ============================================================
%%  Result display
%% ============================================================

display_results(State, NQ, Opts) :-
    ( member(shots(N), Opts), integer(N), N > 0 ->
        format("Shot results (~w samples):~n", [N]),
        sv_sample(State, NQ, N, Outcomes),
        tally_outcomes(Outcomes, NQ, Tally),
        forall(member(Idx-Count, Tally), (
            Pct is Count * 100.0 / N,
            format("  |~`0t~w~*|>  ~w/~w (~1f%)~n",
                   [Idx, NQ, Count, N, Pct])
        ))
    ;
        true
    ),
    ( member(amplitudes(true), Opts) ->
        sv_amplitudes(State, NQ)
    ;
        true
    ),
    ( \+ member(shots(_), Opts),
      \+ member(amplitudes(true), Opts) ->
        sv_probabilities(State, NQ)
    ;
        true
    ),
    ( member(output_reg(Bits), Opts) ->
        read_output_register(State, NQ, Bits)
    ;
        true
    ).

tally_outcomes(Outcomes, _NQ, Sorted) :-
    msort(Outcomes, Sorted0),
    pack_run_length(Sorted0, Tally0),
    sort(2, @>=, Tally0, Sorted).   %% sort by count descending

pack_run_length([], []).
pack_run_length([X|Xs], [X-N|Rest]) :-
    partition(=(X), Xs, Same, Other),
    length(Same, N0), N is N0 + 1,
    pack_run_length(Other, Rest).

read_output_register(State, NQ, Bits) :-
    sv_most_probable(State, NQ, BestIdx, BestProb),
    Bits1 is Bits - 1,
    numlist(0, Bits1, Offsets),
    foldl([Off, Acc, NewAcc]>>(
        Bit is (BestIdx >> Off) /\ 1,
        NewAcc is Acc \/ (Bit << Off)
    ), Offsets, 0, Value),
    Pct is BestProb * 100.0,
    format("~nOutput register (~w bits from q[0]): ~w  (~1f% probability)~n",
           [Bits, Value, Pct]).

%%  qasm3_nqubits_from_file(+File, -NQ)
%%  Counts declared qubits directly from a file on disk.
qasm3_nqubits_from_file(File, NQ) :-
    read_file_to_string(File, Str, []),
    qasm3_nqubits_from_string(Str, NQ).

%%  qasm3_nqubits_from_string(+QasmText, -NQ)
%%  Counts declared qubits from QASM source text already in memory
%%  (an atom or string) -- used by the no-intermediate-file path so
%%  the qubit count matches the MACRO-EXPANDED program (which may
%%  declare more qubits than the raw source, e.g. per-call-site
%%  ancilla renaming inside unrolled for-loops).
qasm3_nqubits_from_string(Text, NQ) :-
    atom_string(TextAtom, Text),
    split_string(TextAtom, "\n", "", Lines),
    maplist(string_to_atom, Lines, AtomLines),
    include(is_qubit_line, AtomLines, QLines),
    ( QLines = [] ->
        NQ = 0
    ;   maplist(qubit_line_size, QLines, Sizes),
        sumlist(Sizes, NQ)
    ).

is_qubit_line(L) :-
    ( atom_concat('qubit[', _, L)
    ; atom_concat('qreg ',  _, L)
    ).

qubit_line_size(L, N) :-
    ( atom_concat('qubit[', R, L) ->
        ( sub_atom(R, Bef, 1, _, ']'),
          sub_atom(R, 0, Bef, _, NS),
          atom_number(NS, N) -> true ; N = 0 )
    ; atom_concat('qreg q[', R, L) ->
        ( ( atom_concat(NS, '];', R) ; atom_concat(NS, ']', R) ),
          atom_number(NS, N) -> true ; N = 0 )
    ; N = 0
    ).

%% ============================================================
%%  Command-line entry point
%%
%%  swipl sv_run.pl -- circuit.qasm [--shots N] [--amplitudes]
%% ============================================================

%% The command-line entry point is registered ONLY when this file is
%% the one swipl was launched with (swipl sv_run.pl -- circuit.qasm).
%% A bare `:- initialization(main, main).` also fired whenever sv_run
%% was loaded as a library by a script: `swipl load.pl` printed this
%% usage text and exited before the prompt, and every scripted
%% `swipl -g ... -t halt` run ended with it.
:- (   current_prolog_flag(associated_file, F),
       file_base_name(F, 'sv_run.pl')
   ->  initialization(main, main)
   ;   true
   ).

main :-
    current_prolog_flag(argv, Args),
    ( parse_args(Args, File, Opts) ->
        qsim_run(File, Opts)
    ;
        print_usage
    ).

parse_args(Args, File, Opts) :-
    Args = [File | Rest],
    atom(File),
    \+ atom_concat('--', _, File),
    parse_opts(Rest, Opts).

parse_opts([], []).
parse_opts(['--shots', NAtom | Rest], [shots(N)|Opts]) :- !,
    atom_number(NAtom, N),
    parse_opts(Rest, Opts).
parse_opts(['--amplitudes' | Rest], [amplitudes(true)|Opts]) :- !,
    parse_opts(Rest, Opts).
parse_opts(['--output-reg', BAtom | Rest], [output_reg(B)|Opts]) :- !,
    atom_number(BAtom, B),
    parse_opts(Rest, Opts).
parse_opts([_ | Rest], Opts) :-
    parse_opts(Rest, Opts).

print_usage :-
    format("Usage: swipl sv_run.pl -- <circuit.qasm> [options]~n"),
    format("~n"),
    format("Options:~n"),
    format("  --shots N        sample N times, show histogram~n"),
    format("  --amplitudes     show full amplitude listing~n"),
    format("  --output-reg B   read B-bit result from q[0..B-1]~n"),
    format("~n"),
    format("REPL usage:~n"),
    format("  ?- [sv_run].~n"),
    format("  ?- qsim_run(\"circuit.qasm\").~n"),
    format("  ?- qsim_run(\"circuit.qasm\", [shots(1000)]).~n").

