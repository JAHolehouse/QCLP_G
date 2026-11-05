%% ============================================================
%%  rp_decode.pl  --  decode exact-backend (gate-level) results
%%
%%  The statevector simulator only knows qubits: it reports states
%%  such as |...0000000083>. This module maps every state back to the
%%  problem's variables, the way the fast (pcode) simulator does.
%%
%%    run_qasm(+QasmFile)
%%    run_qasm(+QasmFile, +Opts)
%%        Simulate an exported Grover circuit and print decoded
%%        results. The .clp file is taken from the circuit's header
%%        line "// Example: <file>" (written by export/1,2), or from
%%        the option source(ClpFile).
%%
%%  run/2 with backend(exact) uses this automatically.
%%
%%  Options:
%%    source(File)   the .clp file the circuit was exported from
%%    top(N)         assignments listed               [default 10]
%%    shots(N)       also sample N measurements and tally them by
%%                   assignment                       [default: none]
%%    raw(true)      also print the simulator's own undecoded output
%%
%%  For each assignment of the domain registers it reports the exact
%%  probability (summed over all ancilla qubits) and classifies it:
%%    ** solution **    in the declared domains, satisfies every hard
%%                      constraint (what the oracle is meant to mark)
%%    ** wraparound **  satisfies the constraints, but a value lies
%%                      outside its declared domain while still fitting
%%                      the register (e.g. p = 15 for p in 2..14)
%%    (blank)           not a solution
%%  It also checks that every ancilla returned to its starting value
%%  (0, or the constant held in a const_K register): a dirty ancilla
%%  means the oracle's uncompute is wrong.
%% ============================================================

:- module(rp_decode, [run_qasm/1, run_qasm/2, exact_search/2,
                      decode_state/1, decode_state/2, set_decode_context/2]).

:- use_module(library(lists)).
:- use_module(library(random)).
:- use_module(library(apply)).
:- use_module(library(assoc)).
:- use_module(library(pairs)).
:- use_module(rp_spec,  [load_spec/2]).
:- use_module(rp_fd,    [rp_fd_compile/2]).
:- use_module(sv_sim,   [sv_run_qasm/2, sv_sample/4, c_abs_sq/2]).
:- use_module(qasm3_macro_pp, [qasm3_expand_string/2]).

run_qasm(QasmFile) :- run_qasm(QasmFile, []).

run_qasm(QasmFile0, Opts) :-
    resolve_qasm(QasmFile0, QasmFile),
    read_file_to_string(QasmFile, Src, []),
    source_clp(Src, Opts, ClpFile),
    load_spec(ClpFile, Goals),
    rp_fd_compile(Goals, FDSpec),
    FDSpec = fd_spec(Domains, Constraints0),
    exclude(is_cost, Constraints0, Hard),
    format("~n[decode] circuit: ~w~n[decode] problem: ~w~n", [QasmFile, ClpFile]),
    catch(set_decode_context(QasmFile, ClpFile), _, true),
    qasm3_expand_string(Src, Flat),
    atom_string(FlatAtom, Flat),
    sv_run_qasm(FlatAtom, State),
    split_string(Flat, "\n", "", Ls0), maplist(atom_string, Ls, Ls0),
    sv_sim:qasm3_build_regmap(Ls, RegMap, NQ),
    ( memberchk(raw(true), Opts) -> sv_run:display_results(State, NQ, Opts) ; true ),
    var_registers(Domains, RegMap, VarRegs, Fixed),
    ancilla_registers(RegMap, VarRegs, Ancillas),
    describe_layout(VarRegs, Fixed),
    dopt(top(TopN), Opts, 10),
    %% What hardware would give: measured shots, each decoded and checked.
    dopt(shots(Shots), Opts, 100),
    print_shots(State, NQ, Shots, VarRegs, Ancillas, Domains, Fixed, Hard, TopN),
    ( Constraints0 \== Hard ->
        format("  Note: the circuit has no cost oracle; a checked state satisfies the~n"),
        format("        hard constraints, not necessarily a minimum-cost one.~n")
    ; true ),
    %% Simulator-only analysis of the whole final state, on request.
    (   memberchk(analysis(true), Opts)
    ->  format("~n[analysis] simulator only -- the full state is not observable on hardware~n"),
        marginals(State, VarRegs, Ancillas, Marg, Dirty),
        classify_all(Marg, Domains, Fixed, Hard, Rows),
        print_rows(Rows, TopN),
        print_summary(Rows, Dirty)
    ;   true
    ),
    nl.

%% ============================================================
%%  exact_search(+ClpFile, +Opts)
%%
%%  Exponential search with unknown M (Boyer, Brassard, Hoyer, Tapp)
%%  on the GATE-LEVEL simulator. The circuit is generated with one
%%  Grover iteration; its preparation is simulated once, and the
%%  iteration (oracle + diffuser, real gates) is applied as many times
%%  as each round needs, from a cache of states. Each round measures
%%  one shot and checks the decoded candidate classically. Nothing is
%%  solved in advance; the circuit's oracle does the marking.
%% ============================================================
exact_search(ClpFile, Opts) :-
    ( memberchk(seed(Seed), Opts) -> set_random(seed(Seed)) ; true ),
    ( memberchk(budget(B), Opts) -> true ; B = 9 ),
    load_spec(ClpFile, Goals),
    rp_fd_compile(Goals, FDSpec),
    rp_grover:circuit_supported(FDSpec),
    FDSpec = fd_spec(Domains, Constraints0),
    exclude(is_cost, Constraints0, Hard),
    nb_setval(qsim_current_example, ClpFile),
    rp_grover:rp_grover_qasm(FDSpec, [iterations(1)], Lines),
    atomic_list_concat(Lines, '\n', Src),
    qasm3_expand_string(Src, Flat),
    split_string(Flat, "\n", " \t", Ls0), maplist(atom_string, Ls1, Ls0),
    exclude(==(''), Ls1, Ls),
    sv_sim:qasm3_build_regmap(Ls, RegMap, NQ),
    append(Pre, ['// Grover iterations'|Rest], Ls), !,
    append(Body, ['// Measurement'|_], Rest), !,
    sv_sim:qasm3_parse_gates_multi(Pre, RegMap, NQ, PreGates),
    sv_sim:qasm3_parse_gates_multi(Body, RegMap, NQ, BodyGates),
    length(BodyGates, NBody),
    var_registers(Domains, RegMap, VarRegs, Fixed),
    ancilla_registers(RegMap, VarRegs, Ancillas),
    rp_grover:rp_grover_circuit_spec(FDSpec, circuit(_, _, NCirc)),
    format("~n[exact] ~w: ~w qubits, ~w gates per Grover iteration, ~w register states~n",
           [ClpFile, NQ, NBody, NCirc]),
    describe_layout(VarRegs, Fixed),
    Budget is ceiling(B * sqrt(float(NCirc))),
    format("[exact] exponential search (unknown M), budget ~w oracle calls~n", [Budget]),
    sv_sim:state_zero(NQ, S00),
    sv_sim:flat_exec(PreGates, NQ, S00, S0),
    SqrtN is sqrt(float(NCirc)),
    exact_round(1.0, SqrtN, [0-S0], BodyGates, NQ, VarRegs, Ancillas, Domains, Fixed, Hard,
                Budget, 1, 0, Result),
    (   Result = found(A, K, Calls, State)
    ->  assign_text(A, T),
        format("[exact] found ~w after ~w oracle calls (last round K=~w)~n", [T, Calls, K]),
        ( Constraints0 \== Hard ->
            format("  Note: the circuit has no cost oracle; this state satisfies the hard~n"),
            format("        constraints but need not be minimum-cost.~n")
        ; true ),
        (   memberchk(analysis(true), Opts)
        ->  format("~n[analysis] simulator only: final round's state~n"),
            marginals(State, VarRegs, Ancillas, Marg, Dirty),
            classify_all(Marg, Domains, Fixed, Hard, Rows),
            dopt(top(TopN), Opts, 10),
            print_rows(Rows, TopN), print_summary(Rows, Dirty)
        ;   true
        )
    ;   Result = not_found(Calls),
        format("[exact] no solution found within ~w oracle calls (probably none)~n", [Calls])
    ).

exact_round(M, SqrtN, Cache, Body, NQ, VarRegs, Ancs, Domains, Fixed, Hard, Budget, Round, Calls0, Result) :-
    (   Calls0 >= Budget
    ->  Result = not_found(Calls0)
    ;   KMax is max(1, ceiling(M)), KTop is KMax - 1,
        random_between(0, KTop, K),
        state_after(K, Cache, Body, NQ, State, Cache1),
        sv_sample(State, NQ, 1, [Idx]),
        Calls1 is Calls0 + K,
        decode_shot(Idx, VarRegs, Fixed, A),
        assign_text(A, T),
        (   clean_ancillas(Idx, Ancs), shot_ok(A, Domains, Hard)
        ->  format("[exact]   round ~w: K=~w, measured ~w: checked, a solution~n", [Round, K, T]),
            Result = found(A, K, Calls1, State)
        ;   format("[exact]   round ~w: K=~w, measured ~w: checked, not a solution~n", [Round, K, T]),
            M1 is min(M * 6 / 5, SqrtN), Round1 is Round + 1,
            exact_round(M1, SqrtN, Cache1, Body, NQ, VarRegs, Ancs, Domains, Fixed, Hard,
                        Budget, Round1, Calls1, Result)
        )
    ).

%% state after K iterations, extending the cache of computed states
state_after(K, Cache, _, _, S, Cache) :- memberchk(K-S, Cache), !.
state_after(K, Cache, Body, NQ, S, [K-S|Cache1]) :-
    K0 is K - 1,
    state_after(K0, Cache, Body, NQ, S0, Cache1),
    sv_sim:flat_exec(Body, NQ, S0, S).

decode_shot(Idx, VarRegs, Fixed, A) :-
    findall(V-X, ( member(V-reg(_,B,Sz), VarRegs), reg_value(Idx, B, Sz, X) ), A0),
    append(A0, Fixed, A).

clean_ancillas(Idx, Ancs) :-
    forall(member(anc(_,B,S,E), Ancs), reg_value(Idx, B, S, E)).

shot_ok(A, Domains, Hard) :-
    forall(member(dom(V,L,H), Domains), (memberchk(V-X, A), X >= L, X =< H)),
    catch(forall(member(C, Hard), rp_fd:check_constraint(A, C)), _, fail).

dopt(Opt, Opts, Default) :-
    ( memberchk(Opt, Opts) -> true ; arg(1, Opt, Default) ).
dopt(Opt, Opts) :- memberchk(Opt, Opts).

is_cost(con(cost, _)).

resolve_qasm(F, F) :- exists_file(F), !.
resolve_qasm(F, G) :- atom_concat('qasm/', F, G), exists_file(G), !.
resolve_qasm(F, _) :-
    format("[decode] ERROR: QASM file not found: ~w~n", [F]), fail.

%% The .clp is given as source(File), else read from the header line
%% "// Example: File" that export/1,2 writes.
source_clp(_, Opts, Clp) :- memberchk(source(Clp), Opts), !.
source_clp(Src, _, Clp) :-
    split_string(Src, "\n", "", Lines),
    member(L, Lines),
    string_concat("// Example: ", Rest, L), !,
    normalize_space(atom(Clp), Rest),
    ( Clp \== '(unknown)', exists_file(Clp) -> true
    ;   format("[decode] ERROR: the circuit header names no usable .clp file (~w).~n", [Clp]),
        format("[decode]   Pass it explicitly: run_qasm(File, [source('path/problem.clp')]).~n"),
        fail
    ).
source_clp(_, _, _) :-
    format("[decode] ERROR: no \"// Example:\" header line in the circuit.~n"),
    format("[decode]   Pass it explicitly: run_qasm(File, [source('path/problem.clp')]).~n"),
    fail.

%% Each domain variable V lives in register v_V. A variable with a
%% one-value domain (a clue) may have no register: it is fixed.
var_registers([], _, [], []).
var_registers([dom(V,L,H)|Ds], RegMap, VRs, Fixed) :-
    atom_concat(v_, V, R),
    (   memberchk(reg(R, Base, Size), RegMap)
    ->  VRs = [V-reg(R,Base,Size)|VRs1], Fixed = Fixed1
    ;   L =:= H
    ->  VRs = VRs1, Fixed = [V-L|Fixed1]
    ;   format("[decode] ERROR: no register ~w for variable ~w.~n", [R, V]), fail
    ),
    var_registers(Ds, RegMap, VRs1, Fixed1).

%% Every other register is an ancilla. It must end where it started:
%% 0, except const_K registers, which hold K.
ancilla_registers(RegMap, VarRegs, Ancs) :-
    pairs_values(VarRegs, Used),
    findall(anc(R,Base,Size,Expect),
            ( member(reg(R,Base,Size), RegMap),
              \+ memberchk(reg(R,Base,Size), Used),
              expected_value(R, Expect) ),
            Ancs).

expected_value(R, K) :-
    ( atom_concat(v_const_, KA, R) ; atom_concat(const_, KA, R) ),
    atom_number(KA, K), integer(K), !.
expected_value(_, 0).

describe_layout(VarRegs, Fixed) :-
    format("[decode] variables: "),
    forall(member(V-reg(_,B,S), VarRegs),
           ( Hi is B+S-1, format("~w = qubits ~w..~w  ", [V,B,Hi]) )),
    forall(member(V-C, Fixed), format("~w = ~w (fixed)  ", [V,C])),
    nl.

reg_value(Idx, Base, Size, V) :- V is (Idx >> Base) /\ ((1 << Size) - 1).

%% Sum |amplitude|^2 over the ancillas, keyed by the values of the
%% domain registers; Dirty is the probability with any ancilla off.
marginals(State, VarRegs, Ancs, Marg, Dirty) :-
    state_pairs(State, Pairs),
    foldl(acc_state(VarRegs, Ancs), Pairs, t-0.0, Assoc-Dirty),
    assoc_to_list(Assoc, Marg).

acc_state(VarRegs, Ancs, Idx-Amp, A0-D0, A-D) :-
    c_abs_sq(Amp, P),
    ( P < 1.0e-15 -> A = A0, D = D0
    ;   maplist([_-reg(_,B,S), Val]>>reg_value(Idx,B,S,Val), VarRegs, Key),
        ( get_assoc(Key, A0, P0) -> P1 is P0 + P ; P1 = P ),
        put_assoc(Key, A0, P1, A),
        ( forall(member(anc(_,B,S,E), Ancs), reg_value(Idx,B,S,E)) -> D = D0
        ; D is D0 + P )
    ).

state_pairs(sparse(_, Assoc), Pairs) :- !, assoc_to_list(Assoc, Pairs).
state_pairs(State, Pairs) :-
    functor(State, _, N), N1 is N - 1,
    findall(I-A, (between(0, N1, I), J is I+1, arg(J, State, A)), Pairs).

classify_all(Marg, Domains, Fixed, Hard, Rows) :-
    maplist(classify(Domains, Fixed, Hard), Marg, Rows0),
    sort(1, @>=, Rows0, Rows).

classify(Domains, Fixed, Hard, Key-P, P-row(Assign, Class)) :-
    regvars(Domains, Fixed, Vars),
    pairs_keys_values(RegAssign, Vars, Key),
    append(RegAssign, Fixed, Assign),
    classify_assignment(Assign, Domains, Hard, Class).

regvars(Domains, Fixed, Vars) :-
    findall(V, (member(dom(V,_,_), Domains), \+ memberchk(V-_, Fixed)), Vars).

classify_assignment(Assign, Domains, Hard, Class) :-
    (   catch(forall(member(C, Hard), rp_fd:check_constraint(Assign, C)), _, fail)
    ->  ( forall(member(dom(V,L,H), Domains), (memberchk(V-X, Assign), X >= L, X =< H))
        -> Class = solution ; Class = wraparound )
    ;   Class = other
    ).

class_label(solution,   "** solution **").
class_label(wraparound, "** wraparound ** (solves it, outside declared domain)").
class_label(other,      "").

print_rows(Rows, TopN) :-
    length(Rows, NAll), Show is min(TopN, NAll),
    format("~nExact probabilities by assignment (~w distinct, top ~w):~n", [NAll, Show]),
    length(Top, Show), append(Top, _, Rows),
    forall(member(P-row(A, C), Top),
           ( Pct is P*100, class_label(C, Lbl),
             assign_text(A, T),
             format("  ~t~4f~10|%  ~w  ~s~n", [Pct, T, Lbl]) )).

assign_text(A, T) :-
    maplist([V-X, S]>>format(atom(S), "~w=~w", [V,X]), A, Ss),
    atomic_list_concat(Ss, ',', Body), format(atom(T), "[~w]", [Body]).

print_summary(Rows, Dirty) :-
    sum_class(Rows, solution, PS, NS),
    sum_class(Rows, wraparound, PW, NW),
    sum_class(Rows, other, PO, _),
    format("~nSummary:~n"),
    format("  solutions in declared domain   ~t~2f~42|%   (~w assignments)~n", [PS*100, NS]),
    ( NW > 0, PW >= 5.0e-5 ->   % only when it shows as >= 0.01%
        format("  wraparound solutions           ~t~2f~42|%   (~w assignments)~n", [PW*100, NW])
    ; true ),
    format("  non-solutions                  ~t~2f~42|%~n", [PO*100]),
    ( Dirty < 1.0e-9 ->
        format("  ancillas: all returned to their starting values (uncompute OK)~n")
    ;   DP is Dirty*100,
        format("  ancillas: WARNING ~4f% of the probability has an ancilla not restored~n", [DP])
    ).

sum_class(Rows, C, P, N) :-
    findall(Pi, member(Pi-row(_,C), Rows), Ps),
    sum_list(Ps, P), length(Ps, N).

print_shots(State, NQ, Shots, VarRegs, Ancs, Domains, Fixed, Hard, TopN) :-
    sv_sample(State, NQ, Shots, Outcomes),
    include([I]>>( \+ clean_ancillas(I, Ancs) ), Outcomes, DirtyShots),
    length(DirtyShots, NDirty),
    maplist([Idx, Key]>>maplist([_-reg(_,B,S), Val]>>reg_value(Idx,B,S,Val), VarRegs, Key),
            Outcomes, Keys),
    msort(Keys, Sorted), clumped(Sorted, Counts0),
    maplist([K-N, N-K]>>true, Counts0, Counts1),
    sort(1, @>=, Counts1, Counts),
    length(Counts, ND), Show is min(TopN, ND),
    format("~nShot results (~w samples, ~w distinct assignments, top ~w; each checked):~n", [Shots, ND, Show]),
    length(Top, Show), append(Top, _, Counts),
    forall(member(N-Key, Top),
           ( classify(Domains, Fixed, Hard, Key-0, _-row(A, C)),
             class_label(C, Lbl), assign_text(A, T),
             Pct is N*100/Shots,
             format("  ~t~w~6|/~w (~1f%)  ~w  ~s~n", [N, Shots, Pct, T, Lbl]) )),
    ( NDirty =:= 0 ->
        format("  ancillas: clean in every shot (uncompute OK)~n")
    ;   format("  ancillas: WARNING ~w of ~w shots had an ancilla not restored~n", [NDirty, Shots])
    ).

%% ============================================================
%%  decode_state(+Text)          decode/1 at the prompt
%%  decode_state(+Text, +File)   decode/2: File is a .qasm or .clp
%%
%%  Decodes simulator output by hand. Text is a state index (integer)
%%  or text copied from the simulator: one line or a whole block, e.g.
%%      '  |00000000000000000000000000000053>  25/100 (25.0%)'
%%  Every |...> in it is read as the (decimal, zero-padded) state index
%%  that qsim_run/2 and qasm3_expand_and_run/2 print, and decoded to
%%  the problem's variables, checked, and (with a .qasm) its ancillas
%%  checked. The rest of each line (counts, percentages) is kept.
%%
%%  The layout comes from File, or else from the last circuit used:
%%  export/1,2,3, run_qasm/1,2, run/1,2 or an earlier decode/2.
%%  With only a .clp file the registers are laid out as the exporter
%%  lays them out (search variables first, from qubit 0); ancillas can
%%  only be checked with the .qasm file.
%% ============================================================

decode_state(Text, File) :-
    (   file_name_extension(_, qasm, File)
    ->  resolve_qasm(File, Q),
        read_file_to_string(Q, Src, []),
        source_clp(Src, [], Clp),
        set_decode_context(Q, Clp)
    ;   set_decode_context(none, File)
    ),
    decode_state(Text).

decode_state(Text) :-
    (   catch(nb_getval(rp_decode_context, Ctx), _, fail), Ctx \== none
    ->  true
    ;   format("[decode] No circuit known yet. Name one:~n"),
        format("[decode]   decode(Text, 'qasm/factor15.qasm')  or  decode(Text, 'examples/factor15.clp')~n"),
        fail
    ),
    Ctx = ctx(Label, VarRegs, Fixed, Ancs, Domains, Hard, NQ),
    format("[decode] layout from ~w~n", [Label]),
    (   ( integer(Text) ; compound(Text), catch(_ is Text, _, fail) )
    ->  Idx is Text, decode_one(Ctx, Idx, "")
    ;   text_to_string(Text, S),
        split_string(S, "\n", "", Lines),
        findall(L, ( member(L, Lines), sub_string(L, _, _, _, "|") ), KetLines),
        (   KetLines == []
        ->  format("[decode] no |...> state found in the text~n"), fail
        ;   forall(member(L, KetLines), decode_line(Ctx, L))
        )
    ),
    _ = VarRegs-Fixed-Ancs-Domains-Hard-NQ.

decode_line(Ctx, Line) :-
    (   sub_string(Line, B, _, _, "|"), B1 is B + 1,
        sub_string(Line, B1, _, 0, After),
        sub_string(After, E, _, _, ">"),
        sub_string(After, 0, E, _, Digits0),
        normalize_space(string(Digits), Digits0),
        number_string(Idx, Digits), integer(Idx)
    ->  E1 is E + 1, sub_string(After, E1, _, 0, Rest0),
        normalize_space(string(Rest), Rest0),
        decode_one(Ctx, Idx, Rest)
    ;   normalize_space(string(L), Line),
        format("  ~w   (not a state index)~n", [L])
    ).

decode_one(ctx(_, VarRegs, Fixed, Ancs, Domains, Hard, NQ), Idx, Rest) :-
    (   NQ \== none, Idx >= 1 << NQ
    ->  format("  |~w>  is out of range for a ~w-qubit circuit~n", [Idx, NQ])
    ;   decode_shot(Idx, VarRegs, Fixed, A),
        classify_assignment(A, Domains, Hard, Class),
        class_label(Class, Lbl0),
        ( Lbl0 == "" -> Lbl = "not a solution" ; Lbl = Lbl0 ),
        assign_text(A, T),
        anc_text(Idx, VarRegs, Ancs, AncT),
        ( Rest == "" -> RestT = "" ; format(string(RestT), "   ~w", [Rest]) ),
        format("  |~w>  ~w  ~s  ~s~s~n", [Idx, T, Lbl, AncT, RestT])
    ).

anc_text(Idx, VarRegs, Ancs, T) :-
    Ancs \== unknown, !,
    findall(R=V, ( member(anc(R,B,S,E), Ancs), reg_value(Idx, B, S, V), V =\= E ), Bad),
    foldl([_-reg(_,B,S), M0, M]>>(M is max(M0, B+S)), VarRegs, 0, Top),
    (   Bad == [] -> T = "(ancillas clean)"
    ;   Idx >> Top =:= 0
    ->  %% only the variable registers given (e.g. a register-state index
        %% from run/1): constant registers read 0 here, which is not a fault
        T = "(register bits only; ancillas not checked)"
    ;   format(string(T), "(ANCILLAS NOT RESTORED: ~w)", [Bad])
    ).
anc_text(Idx, VarRegs, unknown, T) :-
    foldl([_-reg(_,B,S), M0, M]>>(M is max(M0, B+S)), VarRegs, 0, Top),
    (   Idx >> Top =:= 0
    ->  T = "(higher qubits all 0)"
    ;   T = "(higher qubits not all 0: give the .qasm file to check the ancillas)"
    ).

%% set_decode_context(+QasmOrNone, +ClpFile)
set_decode_context(Qasm, Clp) :-
    load_spec(Clp, Goals),
    rp_fd_compile(Goals, FDSpec),
    FDSpec = fd_spec(Domains, Cons),
    exclude(is_cost, Cons, Hard),
    (   Qasm == none
    ->  rp_grover:rp_grover_circuit_spec(FDSpec, circuit(fd_spec(Search, _), Bits, _)),
        findall(V-reg(V, B, Bits), nth0_reg(Search, Bits, V, B), VarRegs),
        findall(V-C, member(dom(V, C, C), Domains), Fixed),
        Ancs = unknown, NQ = none, Label = Clp
    ;   read_file_to_string(Qasm, Src, []),
        qasm3_expand_string(Src, Flat),
        split_string(Flat, "\n", " \t", Ls0), maplist(atom_string, Ls, Ls0),
        sv_sim:qasm3_build_regmap(Ls, RegMap, NQ),
        var_registers(Domains, RegMap, VarRegs, Fixed),
        ancilla_registers(RegMap, VarRegs, Ancs),
        format(atom(Label), "~w (~w)", [Qasm, Clp])
    ),
    nb_setval(rp_decode_context, ctx(Label, VarRegs, Fixed, Ancs, Domains, Hard, NQ)).

nth0_reg(Search, Bits, V, B) :-
    nth0(I, Search, dom(V, _, _)), B is I * Bits.
