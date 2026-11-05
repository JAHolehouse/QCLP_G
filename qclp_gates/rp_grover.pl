%% ============================================================
%%  rp_grover.pl  --  Structured OpenQASM 3.0 emitter
%%
%%  Produces well-structured QASM 3.0 from an FDSpec:
%%
%%    gate def: gate xor_2bit(a, b, anc) { ... }
%%    gate def: gate phase_neq_zero_2bit(anc, flag) { ... }
%%    gate def: gate oracle_N(c0, c1, c2, ..., flag) { ... }
%%    gate def: gate diffuse_Nbit(c0, c1, ...) { ... }
%%
%%    main program:
%%      h c0; h c1; ...
%%      for int i in [1:K] {
%%          x oracle_flag; h oracle_flag;
%%          oracle_N(c0, c1, ..., oracle_flag);
%%          h oracle_flag; x oracle_flag;
%%          diffuse_Nbit(c0, c1, ...);
%%      }
%%      measure ...
%%
%%  This QASM is the hardware-target output: the named gate calls
%%  (oracle_N, diffuse_Nbit) carry their full definitions and are
%%  ready for expansion by hardware backends.
%%
%%  The fast simulator (qsim_pp_grover.pl, run/1) does NOT read this
%%  QASM. It evaluates the same oracle pcode (rp_fd_oracle_mc/2) that
%%  is compiled into the gate definitions here, in the same register
%%  widths, over the same register space -- so for the same K it gives
%%  the probabilities the gate-level simulation of this QASM gives.
%%
%%  The sv simulator expands gate bodies and simulates gate by gate;
%%  it is used for gate-level verification of flat (non-macro) QASM.
%%
%%  Hardware backends (IBM, Quantinuum) expand gate definitions to
%%  native gates as per the OpenQASM 3.0 specification.
%%
%%  Public API:
%%    rp_grover_qasm(+FDSpec, -Lines)
%%    rp_grover_write(+FDSpec, +File)
%% ============================================================

:- module(rp_grover, [
    rp_grover_qasm/2,
    rp_grover_qasm/3,
    rp_grover_write/3,
    rp_grover_circuit_spec/2,  % +FDSpec, -circuit(CSpec, Bits, NCirc)
    rp_grover_write/2,
    rp_grover_write/2,          % alias: write structured QASM
    rp_grover_info/1,           % print circuit statistics
    rp_grover_iterations/2,     % optimal K for 1 solution
    rp_grover_iterations_m/3    % optimal K for M solutions
]).

:- use_module(library(lists)).
:- use_module(rp_fd, [
    rp_fd_oracle_mc/2,
    fd_domain_bits/2,
    fd_register_bits/2,
    fd_domain_size/2,
    fd_spec_domains/2
]).
:- use_module(rp_namer,  [rp_rename/2]).
:- use_module(rp_gates,  [rp_xor_qasm/5, rp_adder_qasm/5,
                           rp_sub_qasm/5, rp_mul_qasm/5]).
%% Iteration predicates are defined directly below.
:- use_module(rp_demo,   [qasm_path/2, ensure_qasm_dir/0]).


%% ============================================================
%%  Scalar-qubit gate helpers
%%
%%  OpenQASM3 `gate` definitions may only take single-qubit formal
%%  parameters (no arrays, no indexing inside the body) and may not
%%  contain qubit declarations. The gate-body generators throughout
%%  this file (and rp_gates.pl) were written register-style: bodies
%%  reference NAME[INDEX] with a width implied by a Bits parameter,
%%  and some declare their own scratch ancillas inline
%%  ("qubit[W] name;") -- both invalid inside a real `gate` block.
%%
%%  These helpers convert that register-style output into valid
%%  QASM3 mechanically, without touching any of the existing body
%%  generators' actual gate-sequence logic:
%%    - every register formal parameter becomes N separate scalar
%%      parameters (name0, name1, ...)
%%    - every inline "qubit[W] name;" declaration found in a body is
%%      stripped and reported back to the caller as an extra scratch
%%      parameter that specific gate now needs -- the caller is
%%      responsible for declaring it exactly once at whatever scope
%%      actually owns it (top-level main program, or threading it
%%      through as one more of ITS OWN formal parameters if the
%%      caller is itself a gate body) and passing it at every call.
%% ============================================================

%%  safe_reg_name(+Reg, -Safe)
%%  Domain/ancilla/scratch variable names come from the .clp file
%%  (or FD compiler-generated names like fd_anc1) and can collide
%%  with OpenQASM3's standard gate library (stdgates.inc defines
%%  gates literally named x, y, z, h, s, t, ...) -- a domain variable
%%  named "x" (extremely common, e.g. fd_domain(x,0,3)) would clash
%%  with the builtin Pauli-X gate if used as a bare top-level
%%  register identifier. Prefix every wire name unconditionally so
%%  no collision is possible, applied at the one shared point every
%%  register-to-text path already goes through.
safe_reg_name(Reg, Safe) :- format(atom(Safe), "v_~w", [Reg]).

%%  safe_pairs(+Pairs, -SafePairs)
%%  Apply safe_reg_name/2 to every Name in a list of Name-Width pairs
%%  -- used only at the two true top-level call sites (see
%%  call_arg_refs/2's note on why this must NOT happen inside gate
%%  bodies, where scalarize_line already applies it exactly once).
safe_pairs(Pairs, SafePairs) :-
    maplist([N-W, SN-W]>>safe_reg_name(N, SN), Pairs, SafePairs).

scalar_name(Reg, I, Name) :- safe_reg_name(Reg, Safe), format(atom(Name), "~w~w", [Safe, I]).

width_scalars(_Reg, 0, []) :- !.
width_scalars(Reg, Width, Names) :-
    Width > 0,
    W1 is Width - 1, numlist(0, W1, Is),
    maplist(scalar_name(Reg), Is, Names).

%%  parse_decl_line(+Line, -Name-Width)
%%  Recognises "qubit[W] Name;" lines -- the only declaration shape
%%  used by the gate-body generators in this file/rp_gates.pl.
parse_decl_line(Line, Name-Width) :-
    atom_string(Line, S),
    string_concat("qubit[", Rest0, S),
    sub_string(Rest0, BPos, 1, AfterLen, "]"),
    sub_string(Rest0, 0, BPos, _, WidthStr),
    number_string(Width, WidthStr),
    sub_string(Rest0, _, AfterLen, 0, AfterBracket),
    split_string(AfterBracket, " ;", " ;", Parts0),
    exclude(==(""), Parts0, [NameStr]),
    atom_string(Name, NameStr).

is_decl_line(Line) :- parse_decl_line(Line, _), !.

%%  strip_decls(+Lines, -CleanLines, -Decls)
strip_decls(Lines, CleanLines, Decls) :-
    partition(is_decl_line, Lines, DeclLines, CleanLines),
    maplist(parse_decl_line, DeclLines, Decls0),
    list_to_set(Decls0, Decls).

%%  scalarize_line(+Line, -ScalarLine)
%%  Text-rewrite every occurrence of NAME[INDEX] to NAMEINDEX. Safe
%%  because QASM identifiers can never themselves contain brackets,
%%  so this transformation is unambiguous and fully reversible in
%%  intent (we never need to reverse it -- QASM3 doesn't need it).
scalarize_line(Line, ScalarLine) :-
    atom_codes(Line, Cs),
    scalarize_codes(Cs, Out),
    atom_codes(ScalarLine, Out).

scalarize_codes([], []).
scalarize_codes([C|Cs], Out) :-
    ( ident_start(C) ->
        take_ident([C|Cs], Ident, Rest),
        try_index(Rest, Ident, Merged, Rest4),
        scalarize_codes(Rest4, RestOut),
        append(Merged, RestOut, Out)
    ;   Out = [C|RestOut2], scalarize_codes(Cs, RestOut2)
    ).

try_index(Rest, Ident, Merged, Rest4) :-
    ( Rest = [0'[|Rest1],
      take_digits(Rest1, Digits, Rest2),
      Digits \= [],
      Rest2 = [0']|Rest3]
    -> append([0'v, 0'_], Ident, Prefixed),   %% match safe_reg_name's "v_" prefix
       append(Prefixed, Digits, Merged), Rest4 = Rest3
    ;  Merged = Ident, Rest4 = Rest
    ).

ident_start(C) :- code_type(C, alpha), !.
ident_start(0'_).
take_ident([C|Cs], [C|Rest], Tail) :- ident_char(C), !, take_ident(Cs, Rest, Tail).
take_ident(Cs, [], Cs).
ident_char(C) :- code_type(C, alnum), !.
ident_char(0'_).
take_digits([C|Cs], [C|Rest], Tail) :- code_type(C, digit), !, take_digits(Cs, Rest, Tail).
take_digits(Cs, [], Cs).

scalarize_body(Lines, ScalarLines) :- maplist(scalarize_line, Lines, ScalarLines).

%%  gate_def_lines2(+NameAtom, +RegWidthPairs, +RawBody, -Lines, -ScratchNeeded)
%%    RegWidthPairs: Reg-Width pairs for this gate's OWN declared
%%    formal parameters (before scalar expansion).
%%    RawBody: body lines as produced by the existing register-style
%%    generators (NAME[INDEX] text, possibly with inline
%%    "qubit[W] Name;" scratch declarations).
%%    Lines: the finished, valid "gate name(p0,p1,...) { ... }" block.
%%    ScratchNeeded: Name-Width pairs this gate needs as EXTRA
%%    parameters beyond RegWidthPairs. The caller must thread these
%%    through: declare once at the scope that owns them, and pass at
%%    every call site (see expand_call_args/2 below).
gate_def_lines2(Name, RegWidthPairs, RawBody, Lines, ScratchNeeded) :-
    include([L]>>(L \= ''), RawBody, NonEmpty),
    strip_decls(NonEmpty, CleanBody, ScratchNeeded),
    scalarize_body(CleanBody, ScalarBody),
    append(RegWidthPairs, ScratchNeeded, AllPairs),
    maplist([Reg-W,Names]>>width_scalars(Reg,W,Names), AllPairs, NameLists),
    append(NameLists, AllNames),
    atomic_list_concat(AllNames, ', ', ParamsStr),
    format(atom(Head), "gate ~w ~w {", [Name, ParamsStr]),
    maplist([L, IL]>>(format(atom(IL), "    ~w", [L])), ScalarBody, IndentedBody),
    flatten([Head, IndentedBody, "}"], Lines).

%%  expand_call_args(+ArgWidthPairs, -ArgsStr)
%%    ArgWidthPairs: RealRegAtom-Width for a CALL site. Produces the
%%    comma-separated per-bit indexed reference list, e.g.
%%    "x[0], x[1], y[0], y[1]". Always indexes (even width-1 args),
%%    matching the always-scalar convention on the definition side.
%%    Legal both at the true top level (indexing a real declared
%%    array) and inside another gate's body -- in the latter case
%%    NAME there is that enclosing gate's own formal parameter, and
%%    gate_def_lines2's scalarize_body will rewrite NAME[I] to
%%    NAMEI for us when that enclosing gate itself gets finalised.
expand_call_args(ArgWidthPairs, ArgsStr) :-
    maplist(call_arg_refs, ArgWidthPairs, RefLists),
    append(RefLists, AllRefs),
    atomic_list_concat(AllRefs, ', ', ArgsStr).

call_arg_refs(padded(Reg, RW, Pad)-Width, Refs) :- !,
    %% Zero-extended operand: Reg's own RW bits, then Width-RW bits
    %% taken from the all-|0> pad register Pad.
    call_arg_refs(Reg-RW, RegRefs),
    PW is Width - RW,
    call_arg_refs(Pad-PW, PadRefs),
    append(RegRefs, PadRefs, Refs).
call_arg_refs(Reg-Width, Refs) :-
    %% NOTE: deliberately NOT applying safe_reg_name here. This helper
    %% is used in two different contexts: (1) building call arguments
    %% INSIDE a gate body, where the resulting text will later be
    %% scalarized (by gate_def_lines2/scalarize_line, which applies
    %% the "v_" prefix) when the ENCLOSING gate is finalised -- so
    %% pre-prefixing here would double it; (2) building the two true
    %% top-level call sites (OracleCall/DiffCall), which never get
    %% scalarized, so THOSE callers pre-apply safe_reg_name to the Reg
    %% atoms themselves before calling expand_call_args/2.
    W1 is Width - 1, numlist(0, W1, Is),
    maplist([I,R]>>(format(atom(R), "~w[~w]", [Reg, I])), Is, Refs).


%% ============================================================
%%  Grover iteration count
%% ============================================================

%%  rp_grover_iterations(+N, -K)
%%  Optimal K for 1 solution in N states.
rp_grover_iterations(N, K) :-
    ( N =< 1 -> K = 1
    ;   K is max(1, round((3.14159265 / 4.0) * sqrt(float(N))))
    ).

%%  rp_grover_iterations_m(+N, +M, -K)
%%  Grover iteration count for M solutions in N states.
%%
%%  K MAXIMISES the success probability sin^2((2K+1)*theta),
%%  theta = asin(sqrt(M/N)), over K >= 1, taking the smallest K on a
%%  tie. This one rule is shared, word for word, by QCLP_G
%%  (qclp_gates/rp_grover.pl) and QCLP_Q (grover_sim/rp_grover.pl).
%%
%%  History:
%%    * QCLP_G took the FIRST K >= 1 with P >= 50%, so it could stop
%%      short of the best K (queens4_anchor1: K=3, 59%; K=6, 99.7%).
%%    * QCLP_Q used the closed form round(pi/4*sqrt(N/M) - 1/2) clamped
%%      to K >= 1, which lands in a dead zone when solutions are common
%%      (M=12, N=16: K=1, 0%). Its fix allowed K = 0 instead.
%%    * K = 0 is NOT used here: for a circuit compiler it means an
%%      exported "Grover circuit" with no oracle at all. For moderate
%%      M/N some K >= 1 matches or beats K = 0 (M=12, N=16: K=2, 75%;
%%      M=13, N=16: K=3, 99.996% vs 81%). When nearly every state is a
%%      solution, any iteration lowers P (M=319, N=327: K=0 97.6%, best
%%      K >= 1 79.4%); such problems do not need Grover at all.
%%  M = 0: K = 1 by convention (nothing can be amplified).
rp_grover_iterations_m(_, M, 1) :- M =< 0, !.
rp_grover_iterations_m(N, M, K) :-
    Theta is asin(sqrt(min(1.0, float(M) / float(N)))),
    %% M/N =< 1/2 (theta =< pi/4): one smooth peak, inside the first
    %% period K = 1 .. pi/(2 theta). M/N > 1/2: the period is under two
    %% steps, so P(K) jumps about from one K to the next; search a short
    %% fixed range instead (M=13, N=16: K=2 gives 38%, K=3 gives 99.996%).
    ( Theta =< pi / 4 + 1.0e-12
    ->  KMax is max(1, ceiling(pi / (2.0 * Theta)))
    ;   KMax = 8
    ),
    findall(P, ( between(1, KMax, Ki), P is sin((2*Ki+1)*Theta)**2 ), Ps),
    max_list(Ps, PMax),
    %% smallest K within 1e-9 of the best: same success probability,
    %% shorter circuit
    nth1(K, Ps, PK), PK >= PMax - 1.0e-9, !.


%% ============================================================
%%  Circuit spec: what the exported circuit actually searches
%% ============================================================
%%
%%  rp_grover_circuit_spec(+FDSpec, -circuit(CSpec, Bits, NCirc))
%%
%%  The circuit stores each variable's VALUE directly in an unsigned
%%  register of Bits qubits (the adders, comparators and multiplier all
%%  work on values). Three things follow, and before 1 Oct 2026 none of
%%  them was done, so circuits whose domains did not fit their registers
%%  were wrong (factor21: 0% on the real answer):
%%
%%    1. Registers are wide enough for the largest value
%%       (fd_register_bits/2), not just for the number of values.
%%    2. A clue (one-value domain, e.g. prod = 21) is a constant: it is
%%       substituted into the constraints and gets no register. It used
%%       to get an ordinary register that the circuit put into
%%       superposition.
%%    3. The registers hold 2^Bits values per variable, so the oracle
%%       must reject values outside the declared domain. A test
%%       Low =< V =< High (range_in, phase kind in_range: done on the
%%       register bits, no subtractor, no constant register) is added
%%       for every variable whose register can hold more than its
%%       domain (range_checks/5).
%%       (Gaps inside a list domain are already neq constraints.)
%%       Without this the circuit also marked "wraparound" values such
%%       as p = 15, q = 1 for p, q in 2..14.
%%
%%  CSpec = fd_spec(SearchDomains, HardConstraints) is what the oracle
%%  is compiled from; NCirc = 2^(Bits * #search variables) is the
%%  number of register states the circuit really searches, and is the
%%  N used for its Grover iteration count.
rp_grover_circuit_spec(fd_spec(Domains, Cons),
                       circuit(fd_spec(Search, CCons), Bits, NCirc)) :-
    (   member(dom(V, L, _), Domains), L < 0
    ->  format(string(Msg), "variable ~w has negative values; the circuit backend stores values in unsigned registers", [V]),
        throw(error(domain_error(non_negative_domain, V), context(rp_grover_qasm/2, Msg)))
    ;   true
    ),
    partition([dom(_, L, H)]>>(L =:= H), Domains, ClueDoms, Search),
    (   Search == []
    ->  throw(error(domain_error(search_variable, none),
                    context(rp_grover_qasm/2, "every variable is fixed; there is nothing to search")))
    ;   true
    ),
    findall(V-C, member(dom(V, C, _), ClueDoms), Subst),
    fd_register_bits(Search, Bits),
    exclude([con(cost, _)]>>true, Cons, Hard0),
    maplist(subst_clues(Subst), Hard0, Hard1),
    include(needs_oracle, Hard1, Hard2),
    length(Search, NS),
    NCirc is 1 << (Bits * NS),
    range_checks(Search, Hard2, Bits, NCirc, RangeVars),
    findall(con(range_in, [V, L, H]),
            ( member(V, RangeVars), memberchk(dom(V, L, H), Search) ),
            RangeCons),
    append(Hard2, RangeCons, CCons).

%%  circuit_supported(+FDSpec)
%%  Succeeds if every hard constraint can be compiled into the oracle.
%%  Otherwise prints which cannot, and fails: a circuit (or a fast
%%  simulation of its oracle) that silently leaves a constraint out
%%  marks the wrong states. Used by export, backend(exact) and run.
circuit_supported(fd_spec(Doms, Cons)) :-
    findall(K, ( member(con(K, _), Cons), unsupported_kind(K) ), Ks1),
    %% fd_product_eq(X, Y, Z): the circuit tests the product against a
    %% constant, so Z must be an integer or a clue (one-value domain).
    findall(prod_var, ( member(con(prod_eq, [_, _, Z]), Cons),
                        \+ integer(Z), \+ memberchk(dom(Z, C, C), Doms) ), Ks2),
    %% Registers and constant registers are unsigned: a negative constant
    %% produced wrong marks and an invalid register name (const_-1).
    findall(negconst, ( member(con(K, Args), Cons), K \== cost,
                        sub_term(N, Args), integer(N), N < 0 ), Ks3),
    append([Ks1, Ks2, Ks3], Ks0),
    sort(Ks0, Ks),
    (   Ks == []
    ->  true
    ;   maplist(kind_source_name, Ks, Names),
        atomic_list_concat(Names, ', ', NamesA),
        format("[circuit] ERROR: ~w cannot be compiled into the oracle yet.~n", [NamesA]),
        format("[circuit]   The circuit, and run/1 (which simulates the circuit's oracle),~n"),
        format("[circuit]   would mark the wrong states, so they refuse.~n"),
        format("[circuit]   solve/1 gives the classical answer.~n"),
        fail
    ).

unsupported_kind(K) :- memberchk(K, [abs_diff, min_list, max_list, count, weighted_sum, unknown]).

kind_source_name(abs_diff,     fd_abs_diff).
kind_source_name(min_list,     fd_min).
kind_source_name(max_list,     fd_max).
kind_source_name(count,        fd_count).
kind_source_name(weighted_sum, fd_weighted_sum).
kind_source_name(unknown,      'an unknown constraint').
kind_source_name(prod_var,     'fd_product_eq with a variable product').
kind_source_name(negconst,     'a negative constant (registers are unsigned; e.g. write y + 1 = x for x + (-1) = y)').

%%  range_checks(+Search, +Hard, +Bits, +NCirc, -Vars)
%%  Every variable whose register can hold values outside its declared
%%  domain gets an in-range test. (A version of 1 Oct 2026 chose a
%%  minimal subset by enumerating the register assignments that satisfy
%%  the constraints -- i.e. by solving the problem classically while
%%  compiling it. That is not allowed: compiling must not look at the
%%  answers.)
range_checks(Search, _Hard, Bits, _NCirc, Vars) :-
    Max is (1 << Bits) - 1,
    findall(V, ( member(dom(V, L, H), Search), once((L > 0 ; H < Max)) ), Vars).

subst_clues(Subst, con(K, Args), con(K, Args1)) :-
    subst_term(Subst, Args, Args1).

subst_term(Subst, T, C) :- atom(T), memberchk(T-C, Subst), !.
subst_term(Subst, T, T1) :-
    compound(T), !,
    T =.. [F|As], maplist(subst_term(Subst), As, As1), T1 =.. [F|As1].
subst_term(_, T, T).

%% A constraint left with no variable at all (only clue constants) is
%% decided now: true -> no oracle code; false -> the problem has no
%% solutions, which the caller reports (M = 0).
needs_oracle(con(_, Args)) :-
    term_contains_atom(Args), !.
needs_oracle(C) :-
    \+ catch(rp_fd:check_constraint([], C), _, fail).

term_contains_atom(T) :- atom(T), T \== [], !.
term_contains_atom(T) :- compound(T), T =.. [_|As], member(A, As), term_contains_atom(A), !.

%%  circuit_params(+FDSpec, +Opts, -NDecl, -NCirc, -K, -Bits)
%%  NDecl: declared search space. NCirc: register states the circuit
%%  searches. K: Grover iterations written into the circuit --
%%  iterations(K) if given, otherwise the optimum for ONE marked state
%%  in NCirc. No classical solve: the number of solutions is unknown,
%%  as it would be on real hardware. For unknown M, run the circuit
%%  with the exponential search (run/2 with backend(exact)), which
%%  tries several K and checks each measured candidate.
circuit_params(FDSpec, Opts, NDecl, NCirc, K, Bits) :-
    rp_grover_circuit_spec(FDSpec, circuit(_, Bits, NCirc)),
    fd_spec_domains(FDSpec, Domains),
    maplist(fd_domain_size, Domains, Sizes),
    foldl([S,A,P]>>(P is A*S), Sizes, 1, NDecl),
    (   memberchk(iterations(K0), Opts), integer(K0), K0 >= 0
    ->  K = K0
    ;   rp_grover_iterations_m(NCirc, 1, K)
    ).

%%  rp_grover_info(+FDSpec)
%%  Print circuit statistics (search space, iteration count, qubits).
rp_grover_info(FDSpec) :-
    fd_spec_domains(FDSpec, Domains),
    fd_spec_constraints(FDSpec, Constraints),
    circuit_params(FDSpec, [], N, NCirc, KDef, Bits),
    rp_grover_circuit_spec(FDSpec, circuit(fd_spec(Search, _), _, _)),
    length(Search, NS),
    length(Domains, NVars),
    length(Constraints, NCons),
    NFixed is NVars - NS,
    DomQ is Bits * NS,
    TotalQ is DomQ + 1,
    format("~n~`=t~55|~n"),
    format("  QCLP_G -- Grover Circuit Statistics~n"),
    format("~`=t~55|~n"),
    format("  Variables:          ~w  (~w searched, ~w fixed)~n", [NVars, NS, NFixed]),
    format("  Constraints:        ~w~n", [NCons]),
    format("  Search space N:     ~w~n", [N]),
    format("  Circuit registers:  ~w x ~w qubits = ~w register states~n", [NS, Bits, NCirc]),
    format("  Default iterations: ~w  (optimal if exactly 1 state is marked)~n", [KDef]),
    format("  Domain qubits:      ~w~n", [DomQ]),
    format("  Total qubits:       ~w (+ ancilla)~n", [TotalQ]),
    format("  (The number of solutions is not computed: it is unknown, as on~n"),
    format("   real hardware. run/1,2 search with unknown M.)~n"),
    format("~`=t~55|~n~n").

%% ============================================================
%%  Top-level API
%% ============================================================

%%  const_prep_lines(+Value-Width, -Lines)
%%  X-gate preparation for a constant register, matching Value's
%%  binary pattern (bit 0 = LSB), addressed via its final mangled
%%  top-level name.
const_prep_lines(Value-Width, Lines) :-
    const_reg_name(Value, Name),
    safe_reg_name(Name, SName),
    W1 is Width - 1, numlist(0, W1, Is),
    include([I]>>(1 is (Value >> I) /\ 1), Is, SetIs),
    maplist([I,L]>>(format(atom(L), "x ~w[~w];", [SName, I])), SetIs, Lines).

rp_grover_write(FDSpec, File) :- rp_grover_write(FDSpec, File, []).

rp_grover_write(FDSpec, File, Opts) :-
    ensure_qasm_dir,
    qasm_path(File, Path),
    rp_grover_qasm(FDSpec, Opts, Lines),
    atomic_list_concat(Lines, '\n', Content),
    setup_call_cleanup(
        open(Path, write, Stream),
        write(Stream, Content),
        close(Stream)
    ),
    circuit_params(FDSpec, Opts, N, NCirc, K, _),
    format("Written: ~w  (search space ~w, ~w register states, ~w Grover iterations)~n",
           [Path, N, NCirc, K]).

rp_grover_qasm(FDSpec, Lines) :- rp_grover_qasm(FDSpec, [], Lines).

rp_grover_qasm(FDSpec, Opts, Lines) :-
    %% The circuit searches CSpec: clues substituted, range checks
    %% added, one register width (see rp_grover_circuit_spec/2).
    rp_grover_circuit_spec(FDSpec, circuit(CSpec, Bits, NCirc)),
    fd_spec_domains(CSpec, Domains),

    %% Grover parameters: iterations(K), or the 1-solution optimum.
    %% No classical solve (see circuit_params/6).
    circuit_params(FDSpec, Opts, N, NCirc, K, Bits),

    %% Oracle microcode (renamed to fresh wire names)
    rp_fd_oracle_mc(CSpec, RawMC),
    rp_rename(RawMC, OracleMC),

    %% Identify mul-result vars (need 2*Bits width)
    include([next(_,_)]>>true, OracleMC, NextMC),
    rp_fd:mul_result_vars(NextMC, MulVars),

    %% Per-ancilla register widths (see anc_width_map/3). Stored
    %% globally so effective_bits/4 -- called from a dozen places
    %% below, all within this one emission -- picks them up without
    %% threading a new argument through every helper.
    anc_width_map(NextMC, Bits, AncWidthMap),
    nb_setval(rp_anc_widths, AncWidthMap),
    nb_setval(rp_dom_bits, Bits),

    %% Ancilla sharing (see anc_pool/4): every constraint block computes,
    %% tests and fully uncomputes its ancillas before the next block
    %% starts, so blocks reuse one pool of registers.
    anc_pool(OracleMC, MulVars, Bits, AncPool),

    %% Domain variable names
    maplist([dom(V,_,_), V]>>true, Domains, DVars),

    %% -- Gate definitions ---------------------------------

    %% 1. Per-constraint primitive gates (xor, add, sub, mul, ...)
    findall(GDef,
            ( member(next(Anc, Expr), OracleMC),
              rp_gates:expr_to_op(Expr, Anc, op(OpName, X, Y, _)),
              op_effective_bits(OpName, Anc, MulVars, Bits, EffBits),
              primitive_gate_def(OpName, X, Y, Anc, EffBits, GDef) ),
            PrimDefsDup),
    sort(PrimDefsDup, PrimDefs),

    %% 2. Per-constraint phase gates (neq_zero, eq_zero, eq_const, ...)
    findall(GDef,
            ( member(flag_test(Anc, Kind), OracleMC),
              effective_bits(Anc, MulVars, Bits, EffBits),
              phase_gate_def(Kind, Anc, EffBits, GDef) ),
            PhaseDefsDup),
    sort(PhaseDefsDup, PhaseDefs),

    %% 3. Oracle gate: composes all constraint primitives
    oracle_gate_def(OracleMC, DVars, MulVars, Bits, OracleDef, OracleScratch, OracleConsts),

    %% 4. Diffuser gate
    diffuser_gate_def(DVars, Domains, Bits, DiffuserDef, DiffScratch),

    %% -- Main program -------------------------------------

    %% Register declarations
    maplist([dom(V,_,_), L]>>(
        safe_reg_name(V, SV),
        format(atom(L), "qubit[~w] ~w;", [Bits, SV])
    ), Domains, QubitDecls),
    maplist([dom(V,_,_), L]>>(
        safe_reg_name(V, SV),
        format(atom(L), "bit[~w] m~w;", [Bits, SV])
    ), Domains, BitDecls),

    %% Ancilla register declarations (for oracle)
    maplist([Anc-EffBits, L]>>(
        safe_reg_name(Anc, SAnc),
        format(atom(L), "qubit[~w] ~w;", [EffBits, SAnc])
    ), AncPool, AncQubitDecls),

    %% oracle_flag qubit
    safe_reg_name(oracle_flag, SOracleFlag),
    format(atom(OracleFlagDecl), "qubit[1] ~w;", [SOracleFlag]),

    %% Scratch registers promoted out of gate bodies (carry, diff_ancN,
    %% mcx_ancN, mul_t/mul_g, ...) -- declared once at the top level,
    %% one shared physical register per distinct name, wide enough for
    %% every call site that uses it (dedup_max_width/2 already sized
    %% these correctly). Oracle's and diffuser's scratch lists don't
    %% share names in practice, but dedup again defensively in case a
    %% future gate reuses a name across both.
    append(OracleScratch, DiffScratch, AllScratch0),
    dedup_max_width(AllScratch0, AllScratch),
    maplist([Name-W, L]>>(
        safe_reg_name(Name, SName),
        format(atom(L), "qubit[~w] ~w;", [W, SName])
    ), AllScratch, ScratchDecls),

    %% Constant registers (classical integer operands, e.g. "x - 5" --
    %% OpenQASM3 gate calls only take qubit arguments, so a literal
    %% operand needs a real prepared register). Declared here, but
    %% PREPARED (via X gates matching the value's bits) once before
    %% the Grover loop -- see ConstPrepLines below -- since unlike
    %% ordinary scratch, a constant register must already hold the
    %% right value before the very first oracle call, not start at 0.
    const_name_pairs(OracleConsts, OracleConstNames),
    maplist([Name-W, L]>>(
        safe_reg_name(Name, SName),
        format(atom(L), "qubit[~w] ~w;", [W, SName])
    ), OracleConstNames, ConstDecls),
    maplist(const_prep_lines, OracleConsts, ConstPrepLinesNested),
    flatten(ConstPrepLinesNested, ConstPrepLines),

    %% Uniform superposition
    maplist([dom(V,_,_), L]>>(
        safe_reg_name(V, SV),
        format(atom(L), "h ~w;", [SV])
    ), Domains, HLines),

    %% Oracle gate call: oracle_N(dvar0, ..., anc0, ..., oracle_flag, consts..., scratch...)
    %% NOTE: order here (consts BEFORE scratch) must match
    %% oracle_gate_def/7's own AllParams order below -- see the
    %% comment there for why this matters.
    maplist([V,V-Bits]>>true, DVars, DVarPairs_call),
    AncPairs_call = AncPool,
    oracle_gate_name(OracleMC, DVars, Bits, OracleName),
    append([DVarPairs_call, AncPairs_call, [oracle_flag-1], OracleConstNames, OracleScratch], OracleCallArgs0),
    safe_pairs(OracleCallArgs0, OracleCallArgs),
    expand_call_args(OracleCallArgs, OracleArgsStr),
    format(atom(OracleCall), "    ~w ~w;", [OracleName, OracleArgsStr]),

    %% Diffuser gate call
    diffuser_gate_name(DVars, Bits, DiffName),
    maplist([V,V-Bits]>>true, DVars, DVarPairs_diff),
    append(DVarPairs_diff, DiffScratch, DiffCallArgs0),
    safe_pairs(DiffCallArgs0, DiffCallArgs),
    expand_call_args(DiffCallArgs, DiffArgsStr),
    format(atom(DiffCall), "    ~w ~w;", [DiffName, DiffArgsStr]),

    %% For-loop line
    format(atom(ForLine), "for int i in [1:~w] {", [K]),

    %% Measurement
    maplist([dom(V,_,_), L]>>(
        safe_reg_name(V, SV),
        format(atom(L), "measure ~w -> m~w;", [SV, SV])
    ), Domains, MeasLines),

    %% Notes
    format(atom(NoteN), "// Search space: ~w states", [N]),
    length(Domains, NSearchVars),
    format(atom(NoteR), "// Register states: ~w (~w search registers x ~w qubits)", [NCirc, NSearchVars, Bits]),
    format(atom(NoteK), "// Grover iterations: ~w", [K]),
    ( memberchk(iterations(_), Opts)
    ->  NoteM = "// Iterations set by iterations(K)"
    ;   NoteM = "// Iterations: optimum for one marked state (number of solutions unknown)"
    ),
    ( nb_getval(qsim_current_example, Ex), Ex \= none ->
        format(atom(NoteEx), "// Example: ~w", [Ex])
    ;   NoteEx = "// Example: (unknown)"
    ),

    %% Phase-kickback lines reference the same mangled oracle_flag
    %% register name used everywhere else (SOracleFlag, computed above).
    format(atom(FlagX1), "    x ~w;", [SOracleFlag]),
    format(atom(FlagH1), "    h ~w;", [SOracleFlag]),
    format(atom(FlagH2), "    h ~w;", [SOracleFlag]),
    format(atom(FlagX2), "    x ~w;", [SOracleFlag]),

    flatten([
        "OPENQASM 3.0;",
        "include \"stdgates.inc\";",
        "// Generated by QCLP_G -- structured Grover circuit",
        "", NoteN, NoteR, NoteK, NoteM, NoteEx, "",

        %% Gate definitions
        "// -- Gate definitions ----------------------------",
        "",
        PrimDefs,
        "",
        PhaseDefs,
        "",
        OracleDef,
        "",
        DiffuserDef,
        "",

        %% Main program
        "// -- Main program ---------------------------------",
        "",
        QubitDecls,
        AncQubitDecls,
        OracleFlagDecl,
        ScratchDecls,
        ConstDecls,
        BitDecls,
        "",
        "// Uniform superposition over search register",
        HLines,
        "",
        "// Constant register preparation",
        ConstPrepLines,
        "",
        "// Grover iterations",
        ForLine,
        "    // Phase kickback: oracle_flag -> |->",
        FlagX1,
        FlagH1,
        "    // Oracle",
        OracleCall,
        "    // Restore oracle_flag",
        FlagH2,
        FlagX2,
        "    // Grover diffuser",
        DiffCall,
        "}",
        "",
        "// Measurement",
        MeasLines,
        "// end"
    ], Lines).


%% ============================================================
%%  Primitive gate definitions
%%  One gate def per unique (operation, bit-width) pair.
%% ============================================================

%%  primitive_gate_def(+OpName, +X, +Y, +Z, +Bits, -Lines)
%%  Generates: gate op_Nbit(a0, a1, ..., b0, ..., c0, ..., [scratch]) { <body> }
%%
%%  rev_mul is special-cased: rp_mul_qasm's shift-and-add body writes
%%  a full 2*Bits-wide product into `c` (row I writes c[I..I+Bits-1],
%%  so the last row I=Bits-1 reaches c[2*Bits-1]).  Every other op's
%%  output register is exactly Bits wide, but declaring `c` only
%%  Bits-wide here left c[Bits..2*Bits-1] referenced-but-undeclared,
%%  which the QASM3 macro preprocessor silently could not parse.
primitive_gate_def(rev_mul, _X, _Y, _Z, Bits, Lines) :- !,
    primitive_raw(rev_mul, Bits, Name, RawBody),
    CBits is 2 * Bits,
    gate_def_lines2(Name, [a-Bits, b-Bits, c-CBits], RawBody, Lines, _Scratch).
primitive_gate_def(OpName, _X, _Y, _Z, Bits, Lines) :-
    primitive_raw(OpName, Bits, Name, RawBody),
    gate_def_lines2(Name, [a-Bits, b-Bits, c-Bits], RawBody, Lines, _Scratch).

primitive_gate_def(_, _, _, _, _, []).   %% unknown op: no definition

%%  primitive_raw(+OpName, +Bits, -Name, -RawBody)
%%  Shared by primitive_gate_def/6 (definition) and
%%  primitive_gate_scratch/3 (call-site scratch lookup) so both stay
%%  in sync automatically.
primitive_raw(rev_xor, Bits, Name, Body) :-
    format(atom(Name), "xor_~wbit", [Bits]),
    rp_xor_qasm(a, b, c, Bits, Body).
primitive_raw(rev_add, Bits, Name, Body) :-
    format(atom(Name), "add_~wbit", [Bits]),
    rp_adder_qasm(a, b, c, Bits, Body0),
    %% rp_adder_qasm's carry register is never actually declared
    %% anywhere in the original output (checked: not even inline) --
    %% synthesize the missing declaration so strip_decls/2 picks it
    %% up and promotes it to a proper scratch parameter automatically,
    %% same as every other scratch wire.
    format(atom(CarryDecl), "qubit[~w] carry;", [Bits]),
    Body = [CarryDecl | Body0].
primitive_raw(rev_sub, Bits, Name, Body) :-
    format(atom(Name), "sub_~wbit", [Bits]),
    rp_sub_qasm(a, b, c, Bits, Body0),
    format(atom(CarryDecl), "qubit[~w] carry;", [Bits]),
    Body = [CarryDecl | Body0].
primitive_raw(rev_mul, Bits, Name, Body) :-
    format(atom(Name), "mul_~wbit", [Bits]),
    rp_mul_qasm(a, b, c, Bits, Body).

%%  primitive_gate_scratch(+OpName, +Bits, -ScratchNeeded)
%%  Name-Width pairs this primitive gate needs as extra parameters,
%%  e.g. add/sub need one shared 'carry' register the same width as
%%  their operands. [] for ops with no raw-body match (unknown op).
primitive_gate_scratch(OpName, Bits, ScratchNeeded) :-
    primitive_raw(OpName, Bits, _Name, RawBody), !,
    include([L]>>(L \= ''), RawBody, NonEmpty),
    strip_decls(NonEmpty, _Clean, ScratchNeeded).
primitive_gate_scratch(_, _, []).


%% ============================================================
%%  Phase gate definitions
%%  One gate def per unique (test-kind, bit-width) pair.
%% ============================================================

%%  phase_gate_def(+Kind, +_Anc, +Bits, -Lines)
phase_gate_def(Kind, _Anc, Bits, Lines) :-
    phase_raw(Kind, Bits, Name, RawBody),
    gate_def_lines2(Name, [anc-Bits, flag-1], RawBody, Lines, _Scratch).

%%  phase_raw(+Kind, +Bits, -Name, -RawBody)
%%  Shared by phase_gate_def/4 and phase_gate_scratch/3.
phase_raw(neq_zero, Bits, Name, Body) :-
    format(atom(Name), "phase_neq_zero_~wbit", [Bits]),
    neq_zero_body(Bits, Body).
phase_raw(eq_zero, Bits, Name, Body) :-
    format(atom(Name), "phase_eq_zero_~wbit", [Bits]),
    eq_zero_body(Bits, Body).
phase_raw(eq_const(Val), Bits, Name, Body) :-
    format(atom(Name), "phase_eq_~w_~wbit", [Val, Bits]),
    (   Val >= 1 << Bits
    ->  %% The register cannot hold Val, so the test is never true (it
        %% used to compare only the low Bits bits: x*y = 17 on 4 bits
        %% marked x*y = 1). The flag is left alone; an identity pair
        %% keeps the gate body non-empty.
        Body = ["x flag[0];", "x flag[0];"]
    ;   eq_const_body(Val, Bits, Body)
    ).
phase_raw(gt_zero, Bits, Name, Body) :-
    %% anc > 0  <=>  (sign bit clear) XOR (anc == 0): the zero value
    %% has its sign bit clear, so the second flip cancels exactly that
    %% one case. Previously gt_zero emitted the bare sign-bit test,
    %% identical to ge_zero, so fd_lt/fd_gt behaved as fd_le/fd_ge.
    format(atom(Name), "phase_gt_zero_~wbit", [Bits]),
    ge_zero_body(Bits, GeBody),
    eq_zero_body(Bits, EqBody),
    append(GeBody, EqBody, Body).
phase_raw(ge_zero, Bits, Name, Body) :-
    format(atom(Name), "phase_ge_zero_~wbit", [Bits]),
    ge_zero_body(Bits, Body).
%% Range checks on a domain register against a constant (added by
%% rp_grover_circuit_spec/2). Tested on the register bits directly: no
%% subtractor, no constant register.
phase_raw(in_range(Lo,Hi), Bits, Name, Body) :-
    %% flag ^= (Lo =< anc =< Hi). Out of range = (anc < Lo) OR (anc > Hi);
    %% the two can never both hold and each is a sum of disjoint terms,
    %% so all terms are XOR-ed into the flag and the flag inverted: one
    %% gate, no condition qubits of its own.
    format(atom(Name), "phase_in_~w_~w_~wbit", [Lo, Hi, Bits]),
    Max is (1 << Bits) - 1,
    ( Lo > 0   -> cmp_const_body(lt, Lo, Bits, LtB) ; LtB = [] ),
    ( Hi < Max -> cmp_const_body(gt, Hi, Bits, GtB) ; GtB = [] ),
    append(LtB, GtB, B0),
    partition([L]>>sub_atom(L, 0, _, _, 'qubit['), B0, Decls0, Gates),
    list_to_set(Decls0, Decls),
    append([Decls, Gates, ["x flag[0];"]], Body).

%%  phase_gate_scratch(+Kind, +Bits, -ScratchNeeded)
phase_gate_scratch(Kind, Bits, ScratchNeeded) :-
    phase_raw(Kind, Bits, _Name, RawBody), !,
    include([L]>>(L \= ''), RawBody, NonEmpty),
    strip_decls(NonEmpty, _Clean, ScratchNeeded).
phase_gate_scratch(_, _, []).


%% Body generators for phase gates (using abstract wire 'anc')
neq_zero_body(Bits, Body) :-
    %% OR-reduction: flag flips if any bit of anc is 1.
    %% For 1 bit: cx anc[0], flag[0]
    %% For N bits: OR chain through anc bits into flag
    Bits1 is Bits - 1,
    numlist(0, Bits1, Idxs),
    ( Bits =:= 1 ->
        Body = ["cx anc[0], flag[0];"]
    ;   %% Use the or-reduction pattern: x all bits, MCX, x all bits, x flag
        %% Net: flag flips iff NOT all bits are 0 = at least one bit is 1
        maplist([I,L]>>(format(atom(L), "x anc[~w];", [I])), Idxs, XLines),
        mcx_anc_flag_lines(Bits, MCXLines),
        maplist([I,L]>>(format(atom(L), "x anc[~w];", [I])), Idxs, XLines2),
        flatten([XLines, MCXLines, XLines2, "x flag[0];"], Body)
    ).

eq_zero_body(Bits, Body) :-
    Bits1 is Bits - 1,
    numlist(0, Bits1, Idxs),
    maplist([I,L]>>(format(atom(L), "x anc[~w];", [I])), Idxs, XLines),
    mcx_anc_flag_lines(Bits, MCXLines),
    flatten([XLines, MCXLines, XLines], Body).

eq_const_body(Val, Bits, Body) :-
    Bits1 is Bits - 1,
    numlist(0, Bits1, Idxs),
    include([I]>>( B is (Val >> I) /\ 1, B =:= 0 ), Idxs, ZeroBits),
    maplist([I,L]>>(format(atom(L), "x anc[~w];", [I])), ZeroBits, XLines),
    mcx_anc_flag_lines(Bits, MCXLines),
    flatten([XLines, MCXLines, XLines], Body).

%% cmp_const_body(+Rel, +Val, +Bits, -Body):  flag ^= (anc Rel Val),
%% Rel = gt or lt, anc an unsigned Bits-bit register, Val a constant.
%%   anc > Val  <=>  OR over bits i with Val_i = 0 of
%%                   (anc_i = 1  AND  anc_j = Val_j for every j > i)
%%   anc < Val  <=>  OR over bits i with Val_i = 1 of
%%                   (anc_i = 0  AND  anc_j = Val_j for every j > i)
%% The terms are mutually exclusive (they differ at the highest bit
%% where anc and Val differ), so XOR-ing each term into the flag with
%% its own multi-controlled X computes the OR exactly. Bits that must
%% be 0 are negated with X before and after.
cmp_const_body(Rel, Val, Bits, Body) :-
    Top is Bits - 1,
    ( Rel == gt -> TermBit = 0 ; TermBit = 1 ),
    findall(Term,
            ( between(0, Top, I),
              (Val >> I) /\ 1 =:= TermBit,
              cmp_term(Rel, Val, I, Top, Term) ),
            Terms),
    append(Terms, Lines0),
    partition([L]>>sub_atom(L, 0, _, _, 'qubit['), Lines0, Decls0, Gates),
    list_to_set(Decls0, Decls),
    append(Decls, Gates, Body).

cmp_term(Rel, Val, I, Top, Lines) :-
    I1 is I + 1,
    findall(J, between(I1, Top, J), Higher),
    %% bits that must read 0: the pivot (for lt) and higher bits where Val has 0
    findall(J, (member(J, Higher), (Val >> J) /\ 1 =:= 0), ZeroHigh),
    ( Rel == lt -> Neg = [I|ZeroHigh] ; Neg = ZeroHigh ),
    maplist([J,L]>>format(atom(L), "x anc[~w];", [J]), Neg, XLines),
    mcx_subset_lines([I|Higher], MCX),
    append([XLines, MCX, XLines], Lines).

mcx_subset_lines([B], [L]) :- !, format(atom(L), "cx anc[~w], flag[0];", [B]).
mcx_subset_lines(Bs, Lines) :- mcx_chain_anc(Bs, "flag", 0, Lines).

%% Sign-bit-clear test (anc >= 0 in two's complement).
ge_zero_body(Bits, Body) :-
    Sign is Bits - 1,
    format(atom(X1), "x anc[~w];", [Sign]),
    format(atom(CX),  "cx anc[~w], flag[0];", [Sign]),
    format(atom(X2), "x anc[~w];", [Sign]),
    Body = [X1, CX, X2].

%% MCX from anc[0..Bits-1] into flag[0] using abstract wire names.
%% Uses a linear AND-chain: a0 = anc[B0] AND anc[B1], a1 = a0 AND anc[B2], ...
%% Each ancilla mcx_ancN holds the running AND so far.
mcx_anc_flag_lines(1, ["cx anc[0], flag[0];"]) :- !.
mcx_anc_flag_lines(2, ["ccx anc[0], anc[1], flag[0];"]) :- !.
mcx_anc_flag_lines(Bits, Lines) :-
    Bits > 2,
    Bits1 is Bits - 1,
    numlist(0, Bits1, BitIdxs),
    mcx_chain_anc(BitIdxs, "flag", 0, Lines).

%%  mcx_chain_anc(+BitIdxs, +TargetName, +AncIdx, -Lines)
%%  Compute AND of anc[BitIdxs] into TargetName[0] via linear chain.
%%  After the seed (a0 = anc[B0] AND anc[B1]), each step extends:
%%    a_{k+1}[0] = a_k[0] AND anc[B_{k+2}]
%%  giving: ccx a_k[0], anc[B_{k+2}], a_{k+1}[0]
%%  Full sequence: Decls, Seed, ChainGates, Final, RevChain, Seed.

%% Base: 2 controls -- just one CCX into target
mcx_chain_anc([B0, B1], Target, _AncIdx, [L]) :-
    format(atom(L), "ccx anc[~w], anc[~w], ~w[0];", [B0, B1, Target]).

%% 3 controls: seed into a0, then final CCX a0 anc[B2] -> target
mcx_chain_anc([B0, B1, B2], Target, AncIdx, Lines) :-
    format(atom(A0),    "mcx_anc~w",   [AncIdx]),
    format(atom(Decl),  "qubit[1] ~w;", [A0]),
    format(atom(Seed),  "ccx anc[~w], anc[~w], ~w[0];", [B0, B1, A0]),
    format(atom(Final), "ccx ~w[0], anc[~w], ~w[0];",   [A0, B2, Target]),
    Lines = [Decl, Seed, Final, Seed].

%% N>3 controls: seed into a0, extend chain for remaining bits
mcx_chain_anc([B0, B1 | Rest], Target, AncIdx, Lines) :-
    Rest = [_,_|_],
    NextIdx is AncIdx + 1,
    format(atom(A0),   "mcx_anc~w",   [AncIdx]),
    format(atom(Decl0),"qubit[1] ~w;", [A0]),
    format(atom(Seed), "ccx anc[~w], anc[~w], ~w[0];", [B0, B1, A0]),
    %% Build the chain: each step is ccx PrevAnc[0], anc[Bi], NextAnc[0]
    mcx_extend_chain(A0, Rest, Target, NextIdx, ChainDecls, ChainGates, FinalGate),
    reverse(ChainGates, RevChain),
    flatten([[Decl0 | ChainDecls], Seed, ChainGates, [FinalGate], RevChain, Seed], Lines).

%%  mcx_extend_chain(+PrevAnc, +RemainingBits, +Target, +AncIdx,
%%                   -Decls, -ChainGates, -FinalGate)
%%  PrevAnc is the name of the ancilla holding the running AND so far.
%%  RemainingBits are the anc bit indices not yet consumed.
%%  When only one bit remains, emit the final gate into Target.
%%  When more remain, allocate a new ancilla and recurse.
mcx_extend_chain(Prev, [BLast], Target, _AncIdx, [], [], FinalGate) :-
    format(atom(FinalGate), "ccx ~w[0], anc[~w], ~w[0];", [Prev, BLast, Target]).
mcx_extend_chain(Prev, [B | Rest], Target, AncIdx, [Decl|Decls], [Gate|Gates], Final) :-
    Rest = [_|_],
    NextIdx is AncIdx + 1,
    format(atom(A),    "mcx_anc~w",   [AncIdx]),
    format(atom(Decl), "qubit[1] ~w;", [A]),
    format(atom(Gate), "ccx ~w[0], anc[~w], ~w[0];", [Prev, B, A]),
    mcx_extend_chain(A, Rest, Target, NextIdx, Decls, Gates, Final).


%% ============================================================
%%  Oracle gate definition
%%  Composes all constraint primitive + phase gate calls.
%% ============================================================

%%  oracle_gate_def(+OracleMC, +DVars, +MulVars, +Bits, -Lines, -OracleScratch, -OracleConsts)
%%  OracleScratch: Name-Width pairs (deduped, max width) this gate
%%  needs as extra parameters beyond DVars/AncVars/oracle_flag --
%%  the union of every internal primitive/phase gate call's own
%%  scratch requirements. The caller (rp_grover_qasm/2) must declare
%%  these once at the top level and pass them at the oracle call.
%%  OracleConsts: Value-Width pairs for classical integer operands
%%  (e.g. "X - 5" -- the 5 is not a wire at all in the FD compiler's
%%  microcode, but OpenQASM3 gate calls can only take qubit
%%  arguments, never a bare literal). The caller must declare a
%%  const_V register per entry AND prepare it via X gates (matching
%%  V's binary pattern) ONCE before the Grover loop -- unlike
%%  OracleScratch, which starts at |0> and is restored by each call's
%%  own compute/uncompute pair, a constant register must already
%%  hold the right value before the very first oracle call.
oracle_gate_def(OracleMC, DVars, MulVars, Bits, Lines, OracleScratch, OracleConsts) :-
    oracle_gate_name(OracleMC, DVars, Bits, Name),
    nb_getval(rp_anc_pool, AncPairs),
    maplist([V,V-Bits]>>true, DVars, DVarPairs),

    oracle_body_lines2(OracleMC, MulVars, Bits, BodyLines, OracleScratch0, OracleConsts),

    const_name_pairs(OracleConsts, OracleConstNames),
    %% NOTE: OracleConstNames comes BEFORE OracleScratch0 here,
    %% deliberately. gate_def_lines2/5 below appends its own
    %% auto-detected scratch (AutoScratch -- the multi-constraint
    %% AND-composition's cond_flags/and_scratchK locals; see the
    %% next comment) immediately after AllParams, giving this gate's
    %% DEFINITION header the parameter order
    %%   DVars, AncVars, oracle_flag, Consts, Scratch0, AutoScratch
    %% This MUST match the order the CALL SITE actually passes
    %% arguments in (rp_grover_qasm/2, a few dozen lines up: "append(
    %% [DVarPairs_call, AncPairs_call, [oracle_flag-1],
    %% OracleConstNames, OracleScratch], OracleCallArgs0)", where
    %% OracleScratch = OracleScratch0 ++ AutoScratch) -- OpenQASM3
    %% gate calls are purely positional, so if these two orderings
    %% ever disagree, every formal parameter after the first
    %% mismatch silently binds to the WRONG physical qubit. That is
    %% exactly what happened before this fix: this predicate built
    %% [..., Scratch0, Consts] (then gate_def_lines2 appended
    %% AutoScratch, giving [...,Scratch0,Consts,AutoScratch]) while
    %% the call site built [...,Scratch0,AutoScratch,Consts] --
    %% Consts and AutoScratch (cond_flags/and_scratch) were
    %% transposed. With only one constraint (no cond_flags/AutoScratch
    %% at all) the two empty-vs-nonempty tails happened to coincide,
    %% so every previously-tested single-constraint and
    %% variable-vs-variable example passed regression despite the
    %% bug; it only became observable once a real multi-constraint
    %% AND-composition (cond_flags in play) was combined with any
    %% classical-integer operand (a const_V register in play) --
    %% e.g. two or more fd_neq(Var,Const)-style constraints, or the
    %% anchored-queens .clp files, composed together. Confirmed via
    %% amplitude inspection: the oracle was flipping oracle_flag based
    %% on whatever qubits ended up misaligned into the cond_flags
    %% slots (the real const registers, holding fixed values) rather
    %% than the actual per-constraint condition flags, so the
    %% "solution" states it marked had nothing to do with the actual
    %% constraints.
    append([DVarPairs, AncPairs, [oracle_flag-1], OracleConstNames, OracleScratch0], AllParams),
    %% gate_def_lines2 auto-detects any remaining embedded
    %% "qubit[W] name;" lines in BodyLines (e.g. the multi-constraint
    %% AND-composition's own cond_flags/and_scratchK locals -- see
    %% oracle_body_lines2_multi/8) and promotes them to formal
    %% parameters of THIS gate too. Previously that auto-detected
    %% scratch was discarded here (bound to _), which is exactly why
    %% the gate's own definition ended up with more formal parameters
    %% than its call site supplied arguments for (an arity mismatch)
    %% as soon as the oracle body started containing such locals.
    %% Capture it and fold it into the OracleScratch this predicate
    %% returns, so our caller (rp_grover_qasm/2) declares these at
    %% the top level and passes them at every oracle call site too.
    gate_def_lines2(Name, AllParams, BodyLines, Lines, AutoScratch),
    append(OracleScratch0, AutoScratch, OracleScratch1),
    list_to_set(OracleScratch1, OracleScratch).

oracle_gate_name(OracleMC, DVars, Bits, Name) :-
    length(OracleMC, NEvents),
    length(DVars, NVars),
    format(atom(Name), "oracle_~wvar_~wevent_~wbit",
           [NVars, NEvents, Bits]).

%%  oracle_body_lines2(+OracleMC, +MulVars, +Bits, -Lines, -ScratchOut, -ConstsOut)
%%  Same compute/phase/uncompute structure as before, but every call
%%  is built via expand_call_args/2 (bracket-indexed against this
%%  oracle's OWN formal parameter names) instead of bare register
%%  names, and each called gate's own scratch requirement (from
%%  primitive_gate_scratch/3, phase_gate_scratch/3) is both passed
%%  through at the call and accumulated into ScratchOut. Integer
%%  operands (X or Y bound to a plain number, not a wire atom) are
%%  resolved to a const_V register reference and accumulated into
%%  ConstsOut instead of being emitted as a literal (which OpenQASM3
%%  gate calls cannot take -- only qubit references are legal there).
oracle_body_lines2(OracleMC, MulVars, Bits, Lines, ScratchOut, ConstsOut) :-
    oracle_body_lines2_(OracleMC, MulVars, Bits, Lines, [], ScratchAcc, [], ConstsAcc),
    dedup_max_width(ScratchAcc, ScratchOut),
    dedup_max_width(ConstsAcc, ConstsOut).   %% raw Value-Width pairs

const_reg_name(V, Name) :- format(atom(Name), "const_~w", [V]).

%%  const_name_pairs(+ValueWidthPairs, -NamePairs)
%%  Convert raw Value-Width pairs (as accumulated during body
%%  generation) into Name-Width pairs (as needed anywhere a formal
%%  parameter list or call-argument list gets built -- the same
%%  shape as OracleScratch).
const_name_pairs(Pairs, NamePairs) :-
    maplist([V-W, Name-W]>>const_reg_name(V, Name), Pairs, NamePairs).

%%  resolve_operand(+V, +Bits, -Ref, +ConstsIn, -ConstsOut)
%%  V is either a wire atom (Ref = V unchanged) or a plain integer
%%  (Ref = the constant register's atom "V" itself, tracked as a
%%  V-Bits pair in ConstsOut for the caller to declare/prepare --
%%  const_reg_name/2 is applied later, once, in oracle_body_lines2/6,
%%  so intermediate accumulation just keys on the raw integer value).
resolve_operand(V, Bits, V, ConstsIn, ConstsOut) :-
    integer(V), !,
    ConstsOut = [V-Bits | ConstsIn].
resolve_operand(V, _Bits, V, Consts, Consts).

%% No hard constraint: every state satisfies the (empty) conjunction,
%% so the oracle marks every state (flag flipped unconditionally), as
%% the microcode says. (Marking none gives the same probabilities --
%% they differ by a global phase -- but not the same oracle.)
oracle_body_lines2_([], _MulVars, _Bits, ["x oracle_flag[0];"], SAcc, SAcc, CAcc, CAcc).
oracle_body_lines2_(MCIn, MulVars, Bits, Lines, SAccIn, SAccOut, CAccIn, CAccOut) :-
    %% ------------------------------------------------------------
    %% Multi-constraint AND composition.
    %%
    %% MCIn is a flat sequence of constraint blocks (each a run of
    %% next(...) events followed by one flag_test(...)). The OLD
    %% version of this predicate emitted each block's phase-test
    %% call directly against the shared oracle_flag, one after
    %% another. Since oracle_flag sits in the |-> phase-kickback
    %% state for the whole oracle call, and each phase-test call is
    %% itself a conditional phase-kickback event, running N of them
    %% in sequence against the SAME target composes as the XOR
    %% (parity) of the N conditions, not their AND/conjunction --
    %% i.e. a state satisfying an EVEN number of constraints (zero,
    %% or two, or four, ...) ended up back at +1 (unmarked), and a
    %% state satisfying an ODD number ended up at -1 (marked),
    %% regardless of whether ALL constraints held. For anything but
    %% a single-constraint problem this marks the wrong set of
    %% states entirely (confirmed empirically: coloring(3) amplified
    %% 24 of its 27 states, not its actual 6 solutions).
    %%
    %% Fix: split into constraint blocks up front. For N=1, keep the
    %% original direct-to-oracle_flag behaviour unchanged (already
    %% verified correct, and there is nothing to AND). For N>=2, run
    %% each constraint's compute/phase-test/uncompute block against
    %% its OWN fresh per-constraint condition flag (a qubit that
    %% starts and ends at |0>, in a normal computational-basis
    %% sense -- not phase-kickback), combine all N condition flags
    %% into oracle_flag with exactly ONE multi-controlled-X (so
    %% exactly one phase-kickback event occurs, gated on the AND of
    %% all N flags), then re-run every constraint block a second
    %% time (same compute/phase/uncompute calls, which are each
    %% self-inverse) to restore every condition flag back to |0>.
    split_constraint_blocks(MCIn, Blocks),
    length(Blocks, NBlocks),
    ( NBlocks =< 1 ->
        oracle_body_lines2_single(Blocks, MulVars, Bits, Lines, SAccIn, SAccOut, CAccIn, CAccOut)
    ;
        oracle_body_lines2_multi(Blocks, MulVars, Bits, Lines, SAccIn, SAccOut, CAccIn, CAccOut)
    ).

%%  split_constraint_blocks(+MC, -Blocks)
%%    Blocks is a list of block(NextEvents, FAnc, Kind) terms, one
%%    per constraint (a run of next(...) events plus its flag_test).
%%    Any non-next/non-flag_test entries are skipped, matching the
%%    old code's silent-skip fallback clause.
split_constraint_blocks([], []).
split_constraint_blocks(MCIn, [block(NextEvents,FAnc,Kind)|MoreBlocks]) :-
    MCIn = [next(_,_)|_], !,
    take_next_run(MCIn, NextEvents, [flag_test(FAnc,Kind)|Rest]),
    split_constraint_blocks(Rest, MoreBlocks).
split_constraint_blocks([flag_test(Reg,Kind)|Rest], [block([],Reg,Kind)|MoreBlocks]) :- !,
    %% A test with no arithmetic before it: a range check applied
    %% straight to a domain register (le_const / ge_const).
    split_constraint_blocks(Rest, MoreBlocks).
split_constraint_blocks([_|Rest], Blocks) :-
    split_constraint_blocks(Rest, Blocks).

%%  oracle_body_lines2_single(+Blocks, ...): 0 or 1 constraint --
%%  identical to the original single-block behaviour (direct
%%  compute/phase-into-oracle_flag/uncompute, no AND-combination
%%  needed since there is nothing to combine).
oracle_body_lines2_single([], _MulVars, _Bits, [], SAcc, SAcc, CAcc, CAcc).
oracle_body_lines2_single([block(NextEvents,FAnc,Kind)], MulVars, Bits, Lines,
                           SAccIn, SAccOut, CAccIn, CAccOut) :-
    constraint_block_lines(NextEvents, FAnc, Kind, oracle_flag, MulVars, Bits,
                            ComputeCalls, PhaseCall, UncomputeCalls,
                            SAccIn, SAccOut, CAccIn, CAccOut),
    flatten([ComputeCalls, PhaseCall, UncomputeCalls], Lines).

%%  oracle_body_lines2_multi(+Blocks, ...): 2+ constraints -- the
%%  AND-composition described above.
oracle_body_lines2_multi(Blocks, MulVars, Bits, Lines, SAccIn, SAccOut, CAccIn, CAccOut) :-
    length(Blocks, N),
    CondReg = cond_flags,
    N1 is N - 1, numlist(0, N1, CondIdxs),
    forward_and_backward(Blocks, CondReg, MulVars, Bits, N,
                          FwdLines, BackLines, SAccIn, SAccOut, CAccIn, CAccOut),
    and_chain_lines(CondReg, CondIdxs, oracle_flag, 0, AndLines),
    format(atom(CondDecl), "qubit[~w] ~w;", [N, CondReg]),
    %% cond_flags (declared here) and and_scratchK (declared inside
    %% and_chain_lines) are embedded as ordinary "qubit[W] name;"
    %% lines directly in the body, exactly like the phase gates'
    %% own internal mcx_ancN locals (see mcx_chain_anc/4) -- so
    %% gate_def_lines2 will auto-detect and promote them to the
    %% oracle gate's own formal parameters automatically (the same
    %% mechanism phase_gate_def already relies on for wide-N phase
    %% gates). We do NOT also add them to SAccOut here: that would
    %% double-count them (once via SAcc becoming part of AllParams,
    %% once via gate_def_lines2's own auto-detection of the embedded
    %% decl line), producing a duplicate-parameter arity mismatch
    %% between the gate's definition and its call sites. See
    %% oracle_gate_def/7 below, which now captures and merges
    %% gate_def_lines2's auto-detected scratch into its own returned
    %% OracleScratch instead of discarding it.
    flatten([[CondDecl], FwdLines, AndLines, BackLines], Lines).

%%  forward_and_backward(+Blocks, +CondReg, +MulVars, +Bits, +N,
%%                        -FwdLines, -BackLines, ...)
%%    FwdLines: each constraint I's compute/phase(into CondReg[I])/
%%      uncompute, in constraint order.
%%    BackLines: the SAME per-constraint blocks again, in REVERSE
%%      constraint order (mirroring standard nested uncompute), which
%%      -- since compute/phase/uncompute is self-inverse when re-run
%%      unchanged -- toggles each CondReg[I] back to |0>.
forward_and_backward(Blocks, CondReg, MulVars, Bits, N, FwdLines, BackLines,
                      SAccIn, SAccOut, CAccIn, CAccOut) :-
    N1 is N - 1, numlist(0, N1, CondIdxs),
    pairs_keys_values(Pairs, Blocks, CondIdxs),
    forward_blocks(Pairs, CondReg, MulVars, Bits, FwdLines, SAccIn, SAccMid, CAccIn, CAccMid),
    reverse(Pairs, PairsRev),
    forward_blocks(PairsRev, CondReg, MulVars, Bits, BackLines, SAccMid, SAccOut, CAccMid, CAccOut).

forward_blocks([], _CondReg, _MulVars, _Bits, [], SAcc, SAcc, CAcc, CAcc).
forward_blocks([block(NextEvents,FAnc,Kind)-Idx | Rest], CondReg, MulVars, Bits, Lines,
                SAccIn, SAccOut, CAccIn, CAccOut) :-
    constraint_block_lines(NextEvents, FAnc, Kind, cond_target(CondReg,Idx), MulVars, Bits,
                            ComputeCalls, PhaseCall, UncomputeCalls,
                            SAccIn, SAcc1, CAccIn, CAcc1),
    forward_blocks(Rest, CondReg, MulVars, Bits, RestLines, SAcc1, SAccOut, CAcc1, CAccOut),
    flatten([ComputeCalls, PhaseCall, UncomputeCalls, RestLines], Lines).

%%  constraint_block_lines(+NextEvents, +FAnc, +Kind, +Target,
%%                         +MulVars, +Bits, -ComputeCalls, -PhaseCall,
%%                         -UncomputeCalls, ...)
%%    Target is either the atom `oracle_flag` (single-constraint
%%    case, phase-test writes directly to the real oracle flag) or
%%    cond_target(Reg,Idx) (multi-constraint case, phase-test writes
%%    to Reg[Idx] instead).
constraint_block_lines(NextEvents, FAnc, Kind, Target, MulVars, Bits,
                        ComputeCalls, PhaseCall, UncomputeCalls,
                        SAccIn, SAccOut, CAccIn, CAccOut) :-
    foldl_compute(NextEvents, MulVars, Bits, ComputeCalls, UncomputeCallsRev,
                  SAccIn, SAcc1, CAccIn, CAccOut),
    effective_bits(FAnc, MulVars, Bits, AncBits),
    phase_gate_scratch(Kind, AncBits, PhaseScratch),
    phys_reg(FAnc, PFAnc),
    phase_gate_call_to(Target, Kind, PFAnc, AncBits, PhaseScratch, PhaseCall),
    append(SAcc1, PhaseScratch, SAccOut),
    reverse(UncomputeCallsRev, UncomputeCalls).

%%  phase_gate_call_to(+Target, +Kind, +Anc, +Bits, +Scratch, -Call)
%%    Same as phase_gate_call/5 but the flag argument is parametric:
%%    oracle_flag for the real oracle flag, or CondReg[Idx] for a
%%    per-constraint condition flag.
phase_gate_call_to(oracle_flag, Kind, Anc, Bits, Scratch, Call) :- !,
    phase_gate_call(Kind, Anc, Bits, Scratch, Call).
phase_gate_call_to(cond_target(Reg,Idx), Kind, Anc, Bits, Scratch, Call) :-
    phase_gate_qname(Kind, Bits, QName),
    format(atom(FlagRef), "~w[~w]", [Reg, Idx]),
    expand_call_args([Anc-Bits], AncArgs),
    ( Scratch == [] -> ScratchArgs = "" ; expand_call_args(Scratch, ScratchArgs0), format(atom(ScratchArgs), ", ~w", [ScratchArgs0]) ),
    format(atom(Call), "~w ~w, ~w~w;", [QName, AncArgs, FlagRef, ScratchArgs]).

%% and_chain_lines(+SrcReg, +BitIdxs, +Target, +ScratchStartIdx, -Lines)
%%   Computes Target[0] ^= AND(SrcReg[I] : I in BitIdxs) via a linear
%%   Toffoli ladder with self-cleaning scratch ancillas -- same
%%   structure as mcx_chain_anc/4 (the phase gates' own N-bit
%%   OR-reduction ladder), generalized to an arbitrary source
%%   register name instead of the hardcoded "anc". Classically
%%   verified (Python, all input combinations) for N=2..6 before
%%   being transcribed here; the recursive structure is identical in
%%   shape for larger N.
and_chain_lines(SrcReg, [B0,B1], Target, _Idx, [L]) :- !,
    format(atom(L), "ccx ~w[~w], ~w[~w], ~w[0];", [SrcReg,B0,SrcReg,B1,Target]).
and_chain_lines(SrcReg, [B0,B1,B2], Target, Idx, Lines) :- !,
    format(atom(A0),    "and_scratch~w", [Idx]),
    format(atom(Decl),  "qubit[1] ~w;", [A0]),
    format(atom(Seed),  "ccx ~w[~w], ~w[~w], ~w[0];", [SrcReg,B0,SrcReg,B1,A0]),
    format(atom(Final), "ccx ~w[0], ~w[~w], ~w[0];", [A0,SrcReg,B2,Target]),
    Lines = [Decl, Seed, Final, Seed].
and_chain_lines(SrcReg, [B0,B1|Rest], Target, Idx, Lines) :-
    Rest = [_,_|_],
    NextIdx is Idx + 1,
    format(atom(A0),   "and_scratch~w", [Idx]),
    format(atom(Decl0),"qubit[1] ~w;", [A0]),
    format(atom(Seed), "ccx ~w[~w], ~w[~w], ~w[0];", [SrcReg,B0,SrcReg,B1,A0]),
    and_extend_chain(SrcReg, A0, Rest, Target, NextIdx, ChainDecls, ChainGates, FinalGate),
    reverse(ChainGates, RevChain),
    flatten([[Decl0|ChainDecls], Seed, ChainGates, [FinalGate], RevChain, Seed], Lines).

and_extend_chain(SrcReg, Prev, [BLast], Target, _Idx, [], [], FinalGate) :- !,
    format(atom(FinalGate), "ccx ~w[0], ~w[~w], ~w[0];", [Prev, SrcReg, BLast, Target]).
and_extend_chain(SrcReg, Prev, [B|Rest], Target, Idx, [Decl|Decls], [Gate|Gates], Final) :-
    Rest = [_|_],
    NextIdx is Idx + 1,
    format(atom(A), "and_scratch~w", [Idx]),
    format(atom(Decl), "qubit[1] ~w;", [A]),
    format(atom(Gate), "ccx ~w[0], ~w[~w], ~w[0];", [Prev, SrcReg, B, A]),
    and_extend_chain(SrcReg, A, Rest, Target, NextIdx, Decls, Gates, Final).

%%  take_next_run(+MC, -NextEvents, -Rest)
%%  Split off a maximal leading run of next(_,_) events.
take_next_run([next(A,E)|More], [next(A,E)|MoreEvents], Tail) :-
    More = [next(_,_)|_], !,
    take_next_run(More, MoreEvents, Tail).
take_next_run([next(A,E)|Rest], [next(A,E)], Rest) :- !.

%%  foldl_compute(+NextEvents, +MulVars, +Bits, -ComputeCalls, -UncomputeCallsFwd, ...)
%%  One compute/uncompute call pair per next(Anc,Expr) event, in the
%%  SAME (forward) order for both lists -- the caller reverses
%%  UncomputeCallsFwd itself, since the natural recursion order here
%%  already matches "first step computed first."
foldl_compute([], _MulVars, _Bits, [], [], SAcc, SAcc, CAcc, CAcc).
foldl_compute([next(Anc,Expr)|Rest], MulVars, Bits, [ComputeCall|MoreCC], [UncomputeCall|MoreUC],
              SAccIn, SAccOut, CAccIn, CAccOut) :-
    rp_gates:expr_to_op(Expr, Anc, op(OpName, X0, Y0, _)),
    op_effective_bits(OpName, Anc, MulVars, Bits, OpBits),
    %% OpBits (from op_effective_bits/5) is deliberately the narrower
    %% operand width -- it names/parameterizes the gate itself (e.g.
    %% "mul_4bit" for Bits=4). effective_bits/4 gives the actual
    %% register width of Anc, which for a rev_mul result is 2*Bits,
    %% not Bits. Every other op has AncBits == OpBits, so this is a
    %% no-op change for xor/add/sub call sites.
    effective_bits(Anc, MulVars, Bits, AncBits),
    op_gate_name(OpName, OpBits, GateName),
    resolve_operand(X0, OpBits, X, CAccIn, CAcc1),
    resolve_operand(Y0, OpBits, Y, CAcc1, CAcc2),
    primitive_gate_scratch(OpName, OpBits, PrimScratch),
    const_call_ref(X, XRef), const_call_ref(Y, YRef),
    %% Zero-extend operands narrower than the gate (see anc_width_map/3),
    %% the multiplier's too (its width is that of its widest operand).
    opnd_call_ref(XRef, OpBits, pad_a, XArg, PadA),
    opnd_call_ref(YRef, OpBits, pad_b, YArg, PadB),
    append(PadA, PadB, PadScratch),
    phys_arg(XArg, PXArg), phys_arg(YArg, PYArg), phys_reg(Anc, PAnc),
    expand_call_args([PXArg, PYArg, PAnc-AncBits | PrimScratch], ComputeArgs),
    format(atom(ComputeCall), "~w ~w;", [GateName, ComputeArgs]),
    format(atom(UncomputeCall), "inv @ ~w ~w;", [GateName, ComputeArgs]),
    append([SAccIn, PrimScratch, PadScratch], SAcc1),
    foldl_compute(Rest, MulVars, Bits, MoreCC, MoreUC, SAcc1, SAccOut, CAcc2, CAccOut).

%%  const_call_ref(+V, -Ref): V already resolved by resolve_operand/5
%%  -- if it was an integer, turn it into its const_V register atom
%%  for use as a call argument; otherwise pass the wire atom through.
const_call_ref(V, Ref) :- integer(V), !, const_reg_name(V, Ref).
const_call_ref(V, V).

op_gate_name(rev_xor, Bits, Name) :- format(atom(Name), "xor_~wbit", [Bits]).
op_gate_name(rev_add, Bits, Name) :- format(atom(Name), "add_~wbit", [Bits]).
op_gate_name(rev_sub, Bits, Name) :- format(atom(Name), "sub_~wbit", [Bits]).
op_gate_name(rev_mul, Bits, Name) :- format(atom(Name), "mul_~wbit", [Bits]).
op_gate_name(_, _, "unknown_op").

phase_gate_call(Kind, Anc, Bits, Scratch, Call) :-
    phase_gate_qname(Kind, Bits, QName),
    expand_call_args([Anc-Bits, oracle_flag-1 | Scratch], Args),
    format(atom(Call), "~w ~w;", [QName, Args]).

phase_gate_qname(neq_zero, Bits, Name) :- format(atom(Name), "phase_neq_zero_~wbit", [Bits]).
phase_gate_qname(eq_zero, Bits, Name) :- format(atom(Name), "phase_eq_zero_~wbit", [Bits]).
phase_gate_qname(eq_const(Val), Bits, Name) :- format(atom(Name), "phase_eq_~w_~wbit", [Val, Bits]).
phase_gate_qname(gt_zero, Bits, Name) :- format(atom(Name), "phase_gt_zero_~wbit", [Bits]).
phase_gate_qname(ge_zero, Bits, Name) :- format(atom(Name), "phase_ge_zero_~wbit", [Bits]).
phase_gate_qname(in_range(Lo,Hi), Bits, Name) :- format(atom(Name), "phase_in_~w_~w_~wbit", [Lo, Hi, Bits]).

%%  dedup_max_width(+Pairs, -Out)
%%  Collapse Name-Width pairs to one entry per distinct Name, keeping
%%  the largest Width seen (a shared scratch register must be wide
%%  enough for every call site that uses it).
dedup_max_width(Pairs, Out) :-
    findall(Name, member(Name-_, Pairs), Names0),
    list_to_set(Names0, Names),
    maplist(max_width_for(Pairs), Names, Out).

max_width_for(Pairs, Name, Name-MaxW) :-
    findall(W, member(Name-W, Pairs), Ws),
    max_list(Ws, MaxW).


%% ============================================================
%%  Diffuser gate definition
%% ============================================================

%%  diffuser_gate_def(+DVars, +Domains, +Bits, -Lines, -DiffScratch)
diffuser_gate_def(DVars, Domains, Bits, Lines, DiffScratch) :-
    diffuser_gate_name(DVars, Bits, Name),

    %% All individual qubit references across every domain variable,
    %% e.g. [x[0], x[1], y[0], y[1]] -- H and X must be applied
    %% per-qubit, not broadcast over a bare register name, since
    %% "x"/"y" don't exist as identifiers once this gate's formal
    %% parameters are scalar-expanded (x0, x1, y0, y1, ...).
    maplist(domain_qubit_refs, Domains, QRefLists),
    flatten(QRefLists, AllQRefs),
    maplist([Q, L]>>(format(atom(L), "h ~w;", [Q])), AllQRefs, HLines),
    maplist([Q, L]>>(format(atom(L), "x ~w;", [Q])), AllQRefs, XLines),

    %% MCZ: H on last qubit, MCX all qubits -> last qubit, H
    last(AllQRefs, LastQ),
    format(atom(HLast1), "h ~w;", [LastQ]),
    format(atom(HLast2), "h ~w;", [LastQ]),
    exclude([Q]>>(Q == LastQ), AllQRefs, Controls),
    mcx_qrefs_to_lines(Controls, LastQ, MCXLines),

    flatten([HLines, XLines, [HLast1], MCXLines, [HLast2], XLines, HLines], RawBody),
    maplist([V,V-Bits]>>true, DVars, DVarPairs),
    gate_def_lines2(Name, DVarPairs, RawBody, Lines, DiffScratch).

diffuser_gate_name(DVars, Bits, Name) :-
    length(DVars, N),
    format(atom(Name), "diffuse_~wvar_~wbit", [N, Bits]).

%% Every search register has the shared width Bits (rp_dom_bits). This
%% used each variable's own domain size, so with unequal domains the
%% diffuser reflected only the low qubits of some registers.
domain_qubit_refs(dom(V, _Low, _High), Refs) :-
    nb_getval(rp_dom_bits, Bits),
    Bits1 is Bits - 1,
    numlist(0, Bits1, Idxs),
    maplist([I, R]>>(format(atom(R), "~w[~w]", [V, I])), Idxs, Refs).

mcx_qrefs_to_lines([], Target, [L]) :-
    format(atom(L), "x ~w;", [Target]).
mcx_qrefs_to_lines([C], Target, [L]) :-
    format(atom(L), "cx ~w, ~w;", [C, Target]).
mcx_qrefs_to_lines([C0,C1], Target, [L]) :-
    format(atom(L), "ccx ~w, ~w, ~w;", [C0, C1, Target]).
mcx_qrefs_to_lines(Controls, Target, Lines) :-
    Controls = [_,_,_|_],
    %% Linear AND-chain through diff_anc registers
    length(Controls, NC),
    Needed is NC - 2,
    ( Needed >= 0 ->
        numlist(0, Needed, AncIdxsN),
        maplist([I, D]>>(format(atom(D), "qubit[1] diff_anc~w;", [I])),
                AncIdxsN, AncDecls),
        diff_chain_lines(Controls, Target, 0, ChainLines),
        flatten([AncDecls, ChainLines], Lines)
    ;   Lines = []
    ).

%% diff_chain_lines(+Controls, +Target, +AncIdx, -Lines)
%%   Computes MCX(Controls -> Target) using a linear AND-chain.
%%   Controls is a list of qubit references like "c0[0]", "c0[1]", etc.
%%   Produces: seed, chain gates, final gate, reverse chain, unseed.
diff_chain_lines(Controls, Target, AncIdx, Lines) :-
    diff_chain_fwd(Controls, Target, AncIdx, FwdGates, FinalGate),
    reverse(FwdGates, RevGates),
    flatten([FwdGates, [FinalGate], RevGates], Lines).

%% diff_chain_fwd(+Controls, +Target, +AncIdx, -FwdGates, -FinalGate)
%%  AncIdx: the next FRESH, never-yet-used ancilla index available to
%%  this call. Each clause that needs a new ancilla allocates AncIdx
%%  for itself and passes AncIdx+1 onward as the next-available index
%%  for anything deeper -- so no index is ever allocated twice.
%%
%%  (The previous version independently reconstructed "AName" at each
%%  recursive level using an index the caller had already assigned to
%%  a DIFFERENT register -- e.g. for 5 controls it would produce
%%  "ccx diff_anc1[0], y0, diff_anc1[0]", a self-controlled Toffoli,
%%  because AncIdx=1 got used to name both the incoming accumulator
%%  from the previous step AND a fresh seed register at the next
%%  step. This version instead folds the newly-produced accumulator
%%  directly into the recursive call's own control list, so each
%%  clause's SeedGate is the only place that ever introduces AName,
%%  and AncIdx strictly increases on every step -- provably no reuse.)
diff_chain_fwd([C0, C1], Target, AncIdx, [SeedGate], FinalGate) :-
    format(atom(AName), "diff_anc~w[0]", [AncIdx]),
    format(atom(SeedGate), "ccx ~w, ~w, ~w;", [C0, C1, AName]),
    format(atom(FinalGate), "cx ~w, ~w;", [AName, Target]).
diff_chain_fwd([C0, C1, Last], Target, AncIdx, [SeedGate], FinalGate) :-
    format(atom(AName), "diff_anc~w[0]", [AncIdx]),
    format(atom(SeedGate), "ccx ~w, ~w, ~w;", [C0, C1, AName]),
    format(atom(FinalGate), "ccx ~w, ~w, ~w;", [AName, Last, Target]).
diff_chain_fwd([C0, C1 | Rest], Target, AncIdx, [SeedGate | RestFwd], FinalGate) :-
    Rest = [_,_|_],  %% at least 2 more controls
    format(atom(AName), "diff_anc~w[0]", [AncIdx]),
    format(atom(SeedGate), "ccx ~w, ~w, ~w;", [C0, C1, AName]),
    Rest = [Next | MoreRest],
    NextIdx is AncIdx + 1,
    diff_chain_fwd([AName, Next | MoreRest], Target, NextIdx, RestFwd, FinalGate).


%% ============================================================
%%  Utilities
%% ============================================================

%% ============================================================
%%  Ancilla sharing
%%
%%  anc_pool(+OracleMC, +MulVars, +Bits, -Pool)
%%  The oracle evaluates one constraint block at a time: compute its
%%  arithmetic ancillas, test into a condition flag (or oracle_flag),
%%  uncompute -- every ancilla is back to |0> before the next block
%%  starts (in the AND-composition the blocks are later re-run in
%%  reverse order, again one at a time). So all blocks can share one
%%  pool: the k-th ancilla of every block uses register anc_poolK, as
%%  wide as the widest k-th ancilla. A use narrower than its pool
%%  register simply passes fewer bits (Reg-Width expands to
%%  Reg[0..Width-1]); the unused high bits stay |0>.
%%  Before 1 Oct 2026 every ancilla had its own register: queens4 used
%%  96 ancilla qubits, where 7 suffice.
%%
%%  Widths are still computed per ORIGINAL ancilla name
%%  (rp_anc_widths); only the emitted register names are mapped, by
%%  phys_reg/2 and phys_arg/2, through rp_anc_phys.
%% ============================================================
anc_pool(OracleMC, MulVars, Bits, Pool) :-
    split_constraint_blocks(OracleMC, Blocks),
    findall(Slots,
            ( member(block(Events, _, _), Blocks),
              findall(A, member(next(A, _), Events), As0),
              list_to_set(As0, Slots) ),
            BlockSlots),
    findall(Orig-Phys,
            ( member(Slots, BlockSlots), nth0(K, Slots, Orig), pool_name(K, Phys) ),
            PhysMap),
    findall(K-W,
            ( member(Slots, BlockSlots), nth0(K, Slots, Orig),
              effective_bits(Orig, MulVars, Bits, W) ),
            KWs),
    findall(K, member(K-_, KWs), Ks0), sort(Ks0, Ks),
    findall(Phys-WMax,
            ( member(K, Ks), pool_name(K, Phys),
              aggregate_all(max(W), member(K-W, KWs), WMax) ),
            Pool),
    nb_setval(rp_anc_phys, PhysMap),
    nb_setval(rp_anc_pool, Pool).

pool_name(K, Name) :- format(atom(Name), "anc_pool~w", [K]).

phys_reg(R, P) :-
    ( catch(nb_getval(rp_anc_phys, Map), _, fail), memberchk(R-P0, Map) -> P = P0 ; P = R ).

phys_arg(padded(R, RW, Pad)-W, padded(P, RW, Pad)-W) :- !, phys_reg(R, P).
phys_arg(R-W, P-W) :- !, phys_reg(R, P).
phys_arg(A, A).

effective_bits(Anc, MulVars, Bits, EffBits) :-
    ( catch(nb_getval(rp_anc_widths, Map), _, fail),
      memberchk(Anc-W, Map) ->
        EffBits = W
    ; member(Anc, MulVars) ->
        EffBits is 2 * Bits
    ;   EffBits = Bits
    ).

%%  op_effective_bits(+OpName, +Anc, +MulVars, +Bits, -OpBits)
%%
%%  Bit-width to use when naming/defining/calling the ARITHMETIC gate
%%  for a next(Anc, Expr) event -- as opposed to effective_bits/4,
%%  which gives the width of the Anc REGISTER ITSELF (used for its
%%  qubit[] declaration and for flag_test phase gates).
%%
%%  For rev_mul specifically these two widths must NOT be the same
%%  value: primitive_gate_def(rev_mul, ...)/rp_mul_qasm already takes
%%  Bits-wide operands and produces a 2*Bits-wide product internally
%%  (that's exactly why Anc's own declaration is 2*Bits -- see
%%  effective_bits/4 above). Anc is *always* trivially a member of
%%  MulVars for its own defining multiply event, so calling
%%  effective_bits(Anc, MulVars, Bits, EffBits) for THIS event would
%%  always double Bits and hand mul_<2*Bits>bit(...) plain Bits-wide
%%  operand registers (e.g. p, q) -- indexing past the end of them.
%%  The multiply gate must be parameterised by the base Bits; only
%%  its result register (declared elsewhere) is 2*Bits wide.
%%
%%  For every other op, the normal effective_bits/4 check is correct:
%%  if this op's result is itself derived from a prior multiply, its
%%  OPERANDS (which include that prior mul result) really are 2*Bits
%%  wide, and Anc's membership in MulVars (via mul_result_vars/2's
%%  derived-var propagation) correctly mirrors that.
%% The multiplier is as wide as its widest operand (at least Bits): a
%% constant such as 5 against 2-bit registers needs 3 bits, and was
%% truncated to 1 before 2 Oct 2026. Its product register is twice that.
op_effective_bits(rev_mul, Anc, _MulVars, Bits, OpBits) :- !,
    (   catch(nb_getval(rp_anc_widths, Map), _, fail), memberchk(Anc-W, Map)
    ->  OpBits is W // 2
    ;   OpBits = Bits
    ).
op_effective_bits(_OpName, Anc, MulVars, Bits, EffBits) :-
    effective_bits(Anc, MulVars, Bits, EffBits).

%% ============================================================
%%  anc_width_map(+NextEvents, +Bits, -Map)
%%
%%  Map is a list of Anc-Width pairs giving the register width of
%%  every arithmetic ancilla. Previously every non-multiply ancilla
%%  was exactly Bits wide (the domain width), so add/sub were
%%  computed mod 2^Bits and silently wrapped:
%%    - fd_sum_neq(q1,1,q2) with q1=3, q2=0, 2-bit: 3+1 = 4 = 0 (mod 4)
%%      == q2, so the true 4-queens solution (1,3,0,2) was marked as
%%      a diagonal clash, leaving ZERO marked states in
%%      queens4_anchor1 -- Grover with nothing marked is the identity
%%      on the uniform state, hence "exactly uniform at every K".
%%    - fd_lt/fd_le/fd_gt/fd_ge test the sign bit of a Bits-wide
%%      difference, but a difference of two Bits-wide values needs
%%      Bits+1 bits of two's complement (x=0,y=3: 0-3 = -3 = 01b in
%%      2 bits, sign bit clear).
%%  Rule: an add/sub result is one bit wider than its widest operand,
%%  which is always enough for the exact result (sum of two W-bit
%%  unsigned values < 2^(W+1); difference of two values in
%%  [-2^(W-1), 2^W) fits W+1-bit two's complement), so no chain of
%%  add/sub can wrap. xor keeps its operand width; mul keeps the
%%  existing 2*Bits product width. Integer operands count as their
%%  own bit length. Operands narrower than the op width are
%%  zero-padded at the call site (see foldl_compute/10).
%% ============================================================
anc_width_map(Events, Bits, Map) :-
    foldl(anc_width_step(Bits), Events, [], Map0),
    reverse(Map0, Map).

anc_width_step(Bits, next(Anc, Expr), Acc, [Anc-W|Acc]) :-
    rp_gates:expr_to_op(Expr, Anc, op(Op, X, Y, _)), !,
    operand_width(X, Bits, Acc, WX),
    operand_width(Y, Bits, Acc, WY),
    WMax is max(WX, WY),
    (   Op == rev_mul            -> W is 2 * max(Bits, WMax)   % operands as wide as the widest
    ;   memberchk(Op, [rev_add, rev_sub]) -> W is WMax + 1
    ;   W = WMax
    ).
anc_width_step(Bits, next(Anc, _), Acc, [Anc-Bits|Acc]).
anc_width_step(_, _, Acc, Acc).

operand_width(V, _Bits, _Acc, W) :-
    integer(V), !,
    ( V =< 0 -> W = 1 ; W is msb(V) + 1 ).
operand_width(V, _Bits, Acc, W) :-
    memberchk(V-W, Acc), !.
operand_width(_, Bits, _, Bits).

%%  opnd_call_ref(+Ref, +OpBits, +PadName, -CallRef-OpBits, -PadScratch)
%%    Ref is an operand wire (domain var or earlier ancilla) or an
%%    already-resolved const register. If the wire is narrower than
%%    the gate width, the missing high bits are supplied from a
%%    dedicated all-|0> pad register (PadName), so the gate sees the
%%    zero-extended value. Each operand position gets its OWN pad
%%    register (pad_a / pad_b) -- the adder uses operand a as its
%%    carry chain, so the two pads must never alias.
opnd_call_ref(Ref, OpBits, _Pad, Ref-OpBits, []) :-
    ( is_const_ref(Ref) ; \+ atom(Ref) ), !.
opnd_call_ref(Ref, OpBits, Pad, CallRef-OpBits, PadScratch) :-
    nb_getval(rp_anc_widths, Map),
    nb_getval(rp_dom_bits, DomBits),
    ( memberchk(Ref-RW, Map) -> true ; RW = DomBits ),
    ( RW < OpBits ->
        PW is OpBits - RW,
        CallRef = padded(Ref, RW, Pad),
        PadScratch = [Pad-PW]
    ;   CallRef = Ref, PadScratch = []
    ).

is_const_ref(Ref) :- atom(Ref), sub_atom(Ref, 0, _, _, const_).

%% hd/tl helpers used in mcx_chain_lines (not used in final impl)
hd([H|_], H).
tl([_|T], T).
