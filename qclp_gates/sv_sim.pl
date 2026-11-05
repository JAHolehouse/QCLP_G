/* ============================================================
   sv_sim.pl  --  Statevector quantum circuit simulator.

   A complete, self-contained statevector simulator.
   No submodule dependencies.  Handles QASM 3.0 ctrl @ notation.

   State representation:
     N-qubit state = list of 2^N complex amplitudes c(Re, Im).
     Basis state |b_{N-1}...b_1 b_0> has index
       I = sum_k b_k * 2^k   (b_0 = LSB = qubit 0).

   Gate application:
     For a k-qubit gate acting on wires W = [w0,...,w_{k-1}]:
       output_amp[out_idx] = sum_{in_combo} M[out_row][in_combo]
                              * input_amp[in_idx(in_combo)]
     where out_row and in_idx are derived by extracting and
     replacing bits at positions W in the full index.
     No full 2^N x 2^N matrix is ever constructed.

   Public API:
     %% Circuit IR execution
     sv_run(+Circuit, +NQIn, -FinalState)
     sv_run_print(+Circuit, +NQIn)

     %% QASM 3.0 execution
     sv_run_qasm(+QASMAtom, -FinalState)
     sv_run_file(+Filename, -FinalState)
     sv_run_qasm_print(+QASMAtom)
     sv_run_file_print(+Filename)

     %% State analysis
     sv_probabilities(+State, +NQubits)
     sv_amplitudes(+State, +NQubits)
     sv_sample(+State, +NQubits, +NShots, -Outcomes)
     sv_most_probable(+State, +NQubits, -Index, -Prob)
     sv_measure(+Wire, +NQubits, +StateIn, -Outcome, -StateOut)
   ============================================================ */

:- module(sv_sim, [
    sv_run/3,
    sv_run_print/2,
    sv_run_qasm/2,
    sv_run_file/2,
    sv_run_qasm_print/1,
    sv_run_file_print/1,
    sv_probabilities/2,
    sv_amplitudes/2,
    sv_sample/4,
    sv_most_probable/4,
    sv_measure/5,
    sv_get/3,          %% O(1) state amplitude access
    state_prob/3,      %% amplitude -> probability
    c_abs_sq/2,        %% complex abs squared
    collect_wires/2,   %% circuit wire enumeration
    build_wire_map/4   %% wire -> qubit index mapping
]).

:- use_module(sv_util).
:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(pairs)).
:- use_module(library(random)).
:- use_module(library(assoc)).

%% Allow sparse and dense clauses to be non-contiguous:
:- discontiguous state_zero/2, sv_get/3, state_prob/3, apply_gate/5.
:- discontiguous prob_loop/4, print_notable_loop/4, most_prob_loop/7.
:- discontiguous state_norm_sq/2.


/* ============================================================
   Complex arithmetic
   ============================================================ */

c_add(c(R1,I1), c(R2,I2), c(R,I))  :- R is R1+R2, I is I1+I2.
c_mul(c(R1,I1), c(R2,I2), c(R,I))  :- R is R1*R2-I1*I2, I is R1*I2+I1*R2.
c_scale(F, c(R,I), c(SR,SI))        :- SR is F*R, SI is F*I.
c_abs_sq(c(R,I), S)                 :- S is R*R+I*I.
c_zero(c(0.0,0.0)).
c_one(c(1.0,0.0)).


/* ============================================================
   State construction and access
   ============================================================ */

%%  State vector is a compound sv(A0, A1, ..., AN-1).
%%  This gives O(1) deterministic access via arg/3.

%%  state_zero/2 -- defined later with sparse/dense dispatch

%%  state_prob/3 -- defined later with sparse/dense dispatch

%%  sv_get(+State, +Idx, -Amp): O(1) deterministic amplitude access.
%%  sv_get/3 -- defined later with sparse/dense dispatch

state_norm_sq(State, NSq) :-
    functor(State, sv, Size), !,
    state_norm_sq_loop(State, 1, Size, 0.0, NSq).

state_norm_sq_loop(_, I, Size, Acc, Acc) :- I > Size, !.
state_norm_sq_loop(State, I, Size, Acc, NSq) :-
    arg(I, State, Amp), c_abs_sq(Amp, P),
    Acc1 is Acc + P, I1 is I+1,
    state_norm_sq_loop(State, I1, Size, Acc1, NSq).

state_normalise(State, Normed) :-
    state_norm_sq(State, NSq),
    ( NSq < 1.0e-15 -> throw(error(zero_norm, state_normalise/2))
    ; F is 1.0/sqrt(NSq),
      functor(State, sv, Size),
      sv_map_scale(F, State, 1, Size, [], RevAmps),
      reverse(RevAmps, Amps),
      Normed =.. [sv | Amps]
    ).

sv_map_scale(_, _, I, Size, Acc, Acc) :- I > Size, !.
sv_map_scale(F, State, I, Size, Acc, Result) :-
    arg(I, State, Amp), c_scale(F, Amp, Scaled),
    I1 is I+1,
    sv_map_scale(F, State, I1, Size, [Scaled|Acc], Result).


/* ============================================================
   Gate matrices

   gate_mat(+Op, -Matrix)
   Single-qubit gates: 2x2.  Two-qubit: 4x4.  Etc.
   c(Re, Im) complex entries.
   ============================================================ */

%%  Single-qubit
gate_mat(i,   [[c(1.0,0.0),c(0.0,0.0)],[c(0.0,0.0),c(1.0,0.0)]]) :- !.
gate_mat(x,   [[c(0.0,0.0),c(1.0,0.0)],[c(1.0,0.0),c(0.0,0.0)]]) :- !.
gate_mat(y,   [[c(0.0,0.0),c(0.0,-1.0)],[c(0.0,1.0),c(0.0,0.0)]]) :- !.
gate_mat(z,   [[c(1.0,0.0),c(0.0,0.0)],[c(0.0,0.0),c(-1.0,0.0)]]) :- !.
gate_mat(s,   [[c(1.0,0.0),c(0.0,0.0)],[c(0.0,0.0),c(0.0,1.0)]]) :- !.
gate_mat(sdg, [[c(1.0,0.0),c(0.0,0.0)],[c(0.0,0.0),c(0.0,-1.0)]]) :- !.
gate_mat(h,   [[c(H,0.0),c(H,0.0)],[c(H,0.0),c(NH,0.0)]]) :- !,
    H is 1.0/sqrt(2.0), NH is -H.
gate_mat(t,   [[c(1.0,0.0),c(0.0,0.0)],[c(0.0,0.0),c(CT,ST)]]) :- !,
    CT is cos(pi/4), ST is sin(pi/4).
gate_mat(tdg, [[c(1.0,0.0),c(0.0,0.0)],[c(0.0,0.0),c(CT,ST)]]) :- !,
    CT is cos(pi/4), ST is -sin(pi/4).

%%  Parametric single-qubit
gate_mat(rx(T), [[c(C,0.0),c(0.0,NS)],[c(0.0,NS),c(C,0.0)]]) :- !,
    C is cos(T/2), NS is -sin(T/2).
gate_mat(ry(T), [[c(C,0.0),c(NS,0.0)],[c(S,0.0),c(C,0.0)]]) :- !,
    C is cos(T/2), S is sin(T/2), NS is -S.
gate_mat(rz(T), [[c(CR,NI),c(0.0,0.0)],[c(0.0,0.0),c(CR,PI)]]) :- !,
    CR is cos(T/2), NI is -sin(T/2), PI is sin(T/2).
gate_mat(phase(T), [[c(1.0,0.0),c(0.0,0.0)],[c(0.0,0.0),c(CT,ST)]]) :- !,
    CT is cos(T), ST is sin(T).

%%  Two-qubit (basis: |00>=0, |01>=1, |10>=2, |11>=3)
gate_mat(cx, [[c(1.0,0.0),c(0.0,0.0),c(0.0,0.0),c(0.0,0.0)],
              [c(0.0,0.0),c(1.0,0.0),c(0.0,0.0),c(0.0,0.0)],
              [c(0.0,0.0),c(0.0,0.0),c(0.0,0.0),c(1.0,0.0)],
              [c(0.0,0.0),c(0.0,0.0),c(1.0,0.0),c(0.0,0.0)]]) :- !.
gate_mat(cz, [[c(1.0,0.0),c(0.0,0.0),c(0.0,0.0),c(0.0,0.0)],
              [c(0.0,0.0),c(1.0,0.0),c(0.0,0.0),c(0.0,0.0)],
              [c(0.0,0.0),c(0.0,0.0),c(1.0,0.0),c(0.0,0.0)],
              [c(0.0,0.0),c(0.0,0.0),c(0.0,0.0),c(-1.0,0.0)]]) :- !.
gate_mat(swap,[[c(1.0,0.0),c(0.0,0.0),c(0.0,0.0),c(0.0,0.0)],
               [c(0.0,0.0),c(0.0,0.0),c(1.0,0.0),c(0.0,0.0)],
               [c(0.0,0.0),c(1.0,0.0),c(0.0,0.0),c(0.0,0.0)],
               [c(0.0,0.0),c(0.0,0.0),c(0.0,0.0),c(1.0,0.0)]]) :- !.

%%  Three-qubit: identity_8 with rows 6,7 swapped (Toffoli)
gate_mat(ccx, M) :- !, identity_mat(8, Id), swap_rows(Id, 6, 7, M).
gate_mat(ccz, M) :- !, identity_mat(8, Id), negate_diag(Id, 7, M).

%%  General n-controlled X:  identity_2n with last two rows swapped.
%%  NQubits is the TOTAL qubit count (controls + target).
gate_mat(cnx(NQubits), M) :- !,
    NQubits >= 2,
    Size is 2^NQubits,
    identity_mat(Size, Id),
    Last1 is Size-2, Last2 is Size-1,
    swap_rows(Id, Last1, Last2, M).

%%  Controlled single-qubit gate.
gate_mat(ctrl_op(Op, NControls), M) :- !,
    NQ is NControls + 1,
    Size is 2^NQ,
    identity_mat(Size, Id),
    gate_mat(Op, [[A,B],[C,D]]),
    Last2 is Size-2, Last1 is Size-1,
    replace_2x2(Id, Last2, Last1, A, B, C, D, M).


/* ============================================================
   Gate engine

   apply_gate(+Op, +GateWires, +NQubits, +StateIn, -StateOut)

   GateWires: qubit indices this gate acts on (0 = LSB).
   Computes new amplitudes directly without constructing
   the full 2^N x 2^N tensor product matrix.
   ============================================================ */



/* ============================================================
   Bit manipulation
   ============================================================ */

extract_bits(_, [], []).
extract_bits(I, [P|Ps], [B|Bs]) :-
    B is (I >> P) /\ 1, extract_bits(I, Ps, Bs).

replace_bits(I, [], [], I).
replace_bits(I, [P|Ps], [B|Bs], R) :-
    Mask is \(1 << P),
    Cleared is I /\ Mask,
    Set is Cleared \/ (B << P),
    replace_bits(Set, Ps, Bs, R).

bits_to_int_msb(Bits, I) :-
    foldl(bits_to_int_step, Bits, 0, I).

int_to_bits_msb(I, N, Bits) :-
    N1 is N-1, numlist(0, N1, Ps),
    reverse(Ps, RevPs),
    maplist(extract_bit_sv(I), RevPs, Bits).


/* ============================================================
   Matrix helpers
   ============================================================ */

identity_mat(Size, M) :-
    Size1 is Size-1, numlist(0, Size1, Rows),
    maplist(identity_row(Size1), Rows, M).

swap_rows(M, I, J, M2) :-
    nth0(I, M, RI), nth0(J, M, RJ),
    length(M, Len), Len1 is Len-1, numlist(0, Len1, Idxs),
    maplist(swap_row(I, J, RI, RJ, M), Idxs, M2).

negate_diag(M, I, M2) :-
    nth0(I, M, Row),
    nth0(I, Row, c(R,Im)),
    NR is -R, NIm is -Im,
    replace_list(Row, I, c(NR,NIm), NewRow),
    replace_list(M, I, NewRow, M2).

replace_list([_|T], 0, V, [V|T]) :- !.
replace_list([H|T], I, V, [H|T2]) :-
    I > 0, I1 is I-1, replace_list(T, I1, V, T2).

replace_2x2(M0, I, J, A, B, C, D, M) :-
    nth0(I, M0, RI0), nth0(J, M0, RJ0),
    replace_list(RI0, I, A, RI1), replace_list(RI1, J, B, RI),
    replace_list(RJ0, I, C, RJ1), replace_list(RJ1, J, D, RJ),
    length(M0, Len), Len1 is Len-1, numlist(0, Len1, Idxs),
    maplist(replace_row(I, J, RI, RJ, M0), Idxs, M).



/* ============================================================
   apply_gate(+Op, +GateWires, +NQubits, +StateIn, -StateOut)

   Public entry point for flat gate list execution (QASM path).
   GateWires = list of qubit indices.
   ============================================================ */

%%  apply_gate/5 -- defined later with sparse/dense dispatch

%%  bg_base(+BgJ, +BgStrides, +BgK, -Base)
bg_base(_, _, 0, 0) :- !.
bg_base(BgJ, BgStrides, BgK, Base) :-
    BgK1 is BgK - 1,
    numlist(0, BgK1, Js),
    foldl([J, Acc, New]>>(
        nth0(J, BgStrides, S),
        B is (BgJ >> J) /\ 1,
        New is Acc + B * S
    ), Js, 0, Base).

%%  precompute_bg_bases(+BgWires, +BgSize, +BgBases)
%%  For each BgJ (0..BgSize-1), compute the state-vector base offset
%%  contributed by background qubits.  BgWires[j] = qubit index for bit j of BgJ.
%%  No nth0/list alloc in inner loop.
precompute_bg_bases(BgWires, BgSize, BgBases) :-
    BgSize1 is BgSize - 1,
    forall(between(0, BgSize1, BgJ),
        ( bg_base_wires(BgJ, BgWires, 0, 0, Base),
          BgJ1 is BgJ+1, nb_setarg(BgJ1, BgBases, Base)
        )
    ).

%%  bg_base_wires(+BgJ, +BgWires, +BitIdx, +Acc, -Base)
bg_base_wires(_, [], _, Acc, Acc) :- !.
bg_base_wires(BgJ, [W|Ws], BitIdx, Acc, Base) :-
    B is (BgJ >> BitIdx) /\ 1,
    S is 1 << W,
    Acc1 is Acc + B * S,
    BitIdx1 is BitIdx + 1,
    bg_base_wires(BgJ, Ws, BitIdx1, Acc1, Base).

%%  apply_gate_block(+BgBase, +GateOffsets, +GateArr, +GS, +Sin, +Sout)
%%
%%  GateOffsets: precomputed state-vector offsets for each of 2^K gate combos
%%               (MSB ordering, indexed 0..GateSize-1).
%%  GateArr:     gate matrix as a compound mat/N for O(1) arg access.
%%
%%  1. Read InAmps from state vector using GateOffsets.
%%  2. For each output combo, compute matrix row dot product, write to StateOut.
apply_gate_block(BgBase, GateOffsets, GateArr, GateSize, StateIn, StateOut) :-
    %%  Read input amplitudes into a compound amp/GateSize for O(1) arg access
    functor(InAmps, amp, GateSize),
    GateSize1 is GateSize - 1,
    forall(between(0, GateSize1, InJ),
        ( InJ1 is InJ + 1,
          arg(InJ1, GateOffsets, GOff),
          SIdx is BgBase + GOff + 1,
          arg(SIdx, StateIn, Amp),
          nb_setarg(InJ1, InAmps, Amp)
        )
    ),
    %%  Compute output amplitudes
    forall(between(0, GateSize1, OutJ),
        ( OutJ1 is OutJ + 1,
          arg(OutJ1, GateOffsets, OutOff),
          OutSIdx is BgBase + OutOff + 1,
          %%  Dot product of row OutJ with InAmps
          RowBase is OutJ * GateSize,
          dot_fast(GateSize1, RowBase, GateArr, InAmps, c(0.0,0.0), NewAmp),
          nb_setarg(OutSIdx, StateOut, NewAmp)
        )
    ).

%%  dot_fast(+Last, +RowBase, +GateArr, +InAmps, +Acc, -Result)
dot_fast(J, _, _, _, Acc, Acc) :- J < 0, !.
dot_fast(J, RowBase, GateArr, InAmps, Acc, Result) :-
    J >= 0,
    FlatJ is RowBase + J + 1,
    J1c is J + 1,
    arg(FlatJ,  GateArr,  M),
    arg(J1c,    InAmps,   A),
    c_mul(M, A, Term),
    c_add(Acc, Term, Acc1),
    J1 is J - 1,
    dot_fast(J1, RowBase, GateArr, InAmps, Acc1, Result).

%%  gate_offset_msb(+J, +BitPos, +Acc, +WireList, -Offset)
%%  Compute state-vector offset for gate combo J using MSB ordering.
%%  BitPos counts down from K-1 to 0; WireList[i] gives the qubit for bit i.
%%  No list allocation: walks WireList recursively.
gate_offset_msb(_, _, Acc, [], Acc) :- !.
gate_offset_msb(J, BitPos, Acc, [W|Ws], Offset) :-
    B is (J >> BitPos) /\ 1,
    S is 1 << W,
    Acc1 is Acc + B * S,
    BitPos1 is BitPos - 1,
    gate_offset_msb(J, BitPos1, Acc1, Ws, Offset).

%%  int_to_bits_lsb(+N, +K, -Bits)  LSB first, K bits
int_to_bits_lsb(_, 0, []) :- !.
int_to_bits_lsb(N, K, Bits) :-
    K > 0,
    K1 is K-1, numlist(0, K1, Ps),
    maplist([P,B]>>(B is (N>>P)/\1), Ps, Bits).

%%  bits_lsb_to_int(+Bits, -N)  Bits are LSB-first
bits_lsb_to_int([], 0) :- !.
bits_lsb_to_int(Bits, N) :-
    length(Bits, K), K > 0, K1 is K-1, numlist(0, K1, Ps),
    pairs_keys_values(Pairs, Ps, Bits),
    foldl([P-B, Acc, New]>>(New is Acc + B*(1<<P)), Pairs, 0, N).

apply_gate_legacy(_, _, _) :- true.   %% placeholder, old loop removed


%%  Sum over all InCombo values (0..GateSize-1) to get output amplitude at OutIdx.
%%  Uses nb_getval/nb_setval to accumulate without growing the Prolog stack.
sum_input_combos(0, GateSize, GateWires, GateRow, StateIn, OutIdx, _Init, Result) :-
    length(GateWires, K),
    nb_setval(sv_amp_acc, c(0.0, 0.0)),
    GateSize1 is GateSize - 1,
    forall(
        between(0, GateSize1, J),
        ( int_to_bits_msb(J, K, InBits),
          replace_bits(OutIdx, GateWires, InBits, InIdx),
          InIdx1 is InIdx+1, arg(InIdx1, StateIn, InAmp),
          nth0_det(J, GateRow, MElem),
          c_mul(MElem, InAmp, Term),
          nb_getval(sv_amp_acc, Acc),
          c_add(Acc, Term, Acc1),
          nb_setval(sv_amp_acc, Acc1)
        )
    ),
    nb_getval(sv_amp_acc, Result).

%%  nth0_det/3: deterministic nth0 -- eliminates the choice point nth0 leaves.
nth0_det(0, [H|_], H) :- !.
nth0_det(N, [_|T], E) :- N > 0, !, N1 is N-1, nth0_det(N1, T, E).

c_add_step(T, Acc, Out) :- !, c_add(Acc, T, Out).

/* ============================================================
   Circuit IR execution
   ============================================================ */

%%  sv_run(+Circuit, +NQIn, -FinalState)
%%
%%  Execute a qoracle circuit IR term.
%%  NQIn = number of input register qubits (for wire map).

sv_run(Circuit, NQIn, FinalState) :-
    collect_wires(Circuit, AllWires),
    sort(AllWires, Sorted),
    build_wire_map(Sorted, NQIn, WireMap, NQubits),
    state_zero(NQubits, S0),
    ir_exec(Circuit, NQubits, WireMap, S0, FinalState).

sv_run_print(Circuit, NQIn) :-
    sv_run(Circuit, NQIn, FinalState),
    collect_wires(Circuit, AllWires),
    sort(AllWires, Sorted),
    build_wire_map(Sorted, NQIn, _WireMap, NQubits),
    print_results(FinalState, NQubits).


%%  ir_exec: walk circuit IR, applying gates to state

ir_exec(empty,          _,  _,  S, S) :- !.
ir_exec(init(_, 0),     _,  _,  S, S) :- !.   %% |0> is the default state
ir_exec(init(W, 1),    NQ, WM, S0, S1) :- !,  %% flip wire to |1>
    wire_idx(W, WM, I), apply_gate(x, [I], NQ, S0, S1).
ir_exec(init(_,_),      _,  _,  S, S) :- !.   %% other values: no-op
ir_exec(discard(_),     _,  _,  S, S) :- !.

ir_exec(gate(Op, [W]), NQ, WM, S0, S1) :- !,
    wire_idx(W, WM, I),
    apply_gate(Op, [I], NQ, S0, S1).

ir_exec(ctrl(Cs, gate(x, [T])), NQ, WM, S0, S1) :- !,
    maplist(wire_idx_pair(WM), Cs, CIs),
    wire_idx(T, WM, TI),
    append(CIs, [TI], AllWires),
    length(AllWires, NArity),
    cnx_op(NArity, Op),
    apply_gate(Op, AllWires, NQ, S0, S1).

ir_exec(ctrl(Cs, gate(Op, [T])), NQ, WM, S0, S1) :- !,
    maplist(wire_idx_pair(WM), Cs, CIs),
    wire_idx(T, WM, TI),
    length(Cs, NCs),
    append(CIs, [TI], AllWires),
    apply_gate(ctrl_op(Op, NCs), AllWires, NQ, S0, S1).

ir_exec(ctrl(_, Body), NQ, WM, S0, S1) :- !,
    ir_exec(Body, NQ, WM, S0, S1).

ir_exec(seq(A, B), NQ, WM, S0, S2) :- !,
    ir_exec(A, NQ, WM, S0, S1),
    ir_exec(B, NQ, WM, S1, S2).

cnx_op(2, cx).
cnx_op(3, ccx).
cnx_op(N, cnx(N)) :- N > 3.


/* ============================================================
   QASM 3.0 execution
   ============================================================ */

%%  sv_run_qasm(+QASMAtom, -FinalState)
%%
%%  Extended to handle multi-register QASM as generated by RProlog(FD):
%%    - Multiple named qubit registers: qubit[N] name;  (anywhere in file)
%%    - Whole-register gates: h x;  x y;  (expanded to per-qubit gates)
%%    - Named wire references: cx x[0], fd_anc1[0]  (mapped to flat indices)
%%    - Mid-circuit qubit declarations are hoisted and assigned offsets
%%    - Classical bit/creg declarations and measurement assignments skipped
sv_run_qasm(QASM, FinalState) :-
    atom_string(QASM, QASMStr),
    split_string(QASMStr, "\n", "", Lines),
    maplist(string_to_atom, Lines, AtomLines),
    %% Build register map: assigns a flat base index to every named register
    qasm3_build_regmap(AtomLines, RegMap, NQubits),
    format("[sv] registers: ~w  total qubits: ~w~n", [RegMap, NQubits]),
    qasm3_parse_gates_multi(AtomLines, RegMap, NQubits, FlatGates),
    length(FlatGates, NGates),
    format("[sv] ~w qubits, ~w gates~n", [NQubits, NGates]),
    state_zero(NQubits, S0),
    flat_exec(FlatGates, NQubits, S0, FinalState).

%%  sv_run_file(+Filename, -FinalState)
sv_run_file(File, FinalState) :-
    read_file_to_string(File, Str, []),
    atom_string(QASM, Str),
    sv_run_qasm(QASM, FinalState).

sv_run_qasm_print(QASM) :-
    sv_run_qasm(QASM, State),
    qasm3_nqubits_from_atom(QASM, NQ),
    print_results(State, NQ).

sv_run_file_print(File) :-
    read_file_to_string(File, Str, []),
    atom_string(QASM, Str),
    sv_run_qasm_print(QASM).

%%  For print path: derive NQ from new multi-register map
qasm3_nqubits_from_atom(QASM, NQ) :-
    atom_string(QASM, S), split_string(S,"\n","",Lines),
    maplist(string_to_atom, Lines, As),
    ( qasm3_build_regmap(As, _, NQ) -> true
    ; qasm3_parse_nqubits(As, NQ)   %% fallback to old single-reg path
    ).


%%  flat_exec: execute a list of gate(Op, Wires) terms.
%%  Iterative via nb_setval to avoid stack growth with long gate lists.
flat_exec(Gates, NQ, S0, FinalState) :-
    nb_setval(sv_state, S0),
    nb_setval(sv_key_cache, no_cache),  %% initialise sparse key cache
    maplist(exec_one_gate(NQ), Gates),
    nb_getval(sv_state, FinalState).

exec_one_gate(_, gate(measure, _)) :- !.   %% deferred measurement -- skip
exec_one_gate(NQ, gate(Op, Wires)) :- !,
    nb_getval(sv_state, S0),
    apply_gate(Op, Wires, NQ, S0, S1),
    nb_setval(sv_state, S1).
exec_one_gate(_, Other) :-
    format("[sv] WARNING: skipping ~w~n", [Other]).


/* ............................................................
   Multi-register QASM support
   
   Builds a register map: list of reg(Name, Base, Size) entries
   in declaration order (including mid-circuit qubit declarations).
   All named[idx] wire references are resolved to flat indices.
   Whole-register gate lines (h x; x y;) are expanded.
   ............................................................ */

%%  qasm3_build_regmap(+Lines, -RegMap, -TotalQubits)
%%  Collects ALL qubit declarations (anywhere in file), assigns offsets.
qasm3_build_regmap(Lines, RegMap, Total) :-
    include(is_qubit_decl, Lines, DeclLines),
    build_regmap_acc(DeclLines, 0, RegMap, Total).

is_qubit_decl(L) :-
    atom_string(L, S),
    ( string_concat("qubit[", _, S)
    ; string_concat("qreg ",  _, S)
    ).

build_regmap_acc([], Total, [], Total).
build_regmap_acc([L|Ls], Offset, [reg(Name,Offset,N)|Rest], Total) :-
    parse_qreg_named(L, Name, N), !,
    Next is Offset + N,
    build_regmap_acc(Ls, Next, Rest, Total).
build_regmap_acc([_|Ls], Offset, Rest, Total) :-
    build_regmap_acc(Ls, Offset, Rest, Total).

%%  parse_qreg_named(+Line, -Name, -N)
%%  Accepts:  qubit[N] regname;
%%            qubit[N] regname;  // comment
%%            qubit[N] regname   (no semicolon)
%%            qreg q[N];
parse_qreg_named(L, Name, N) :-
    atom_string(L, S),
    ( string_concat("qubit[", R, S)
    ->  %% find closing ']'
        sub_string(R, BracPos, 1, _, "]"),
        sub_string(R, 0, BracPos, _, NStr),
        number_string(N, NStr),
        After is BracPos + 1,
        sub_string(R, After, _, 0, AfterBrac),
        string_trim(AfterBrac, AfterTr),
        %% Strip comment first (// and everything after)
        ( sub_string(AfterTr, ComPos, 2, _, "//")
        ->  sub_string(AfterTr, 0, ComPos, _, WithoutComment)
        ;   WithoutComment = AfterTr ),
        string_trim(WithoutComment, WithoutComTr),
        %% Strip trailing semicolon
        ( string_concat(NamePart, ";", WithoutComTr) -> true ; NamePart = WithoutComTr ),
        string_trim(NamePart, NameTr),
        atom_string(Name, NameTr)
    ; string_concat("qreg q[", R, S),
      ( string_concat(NStr, "];", R) ; string_concat(NStr, "]", R) ),
      number_string(N, NStr),
      Name = q
    ).

%%  regmap_lookup(+RegMap, +Name, +Idx, -FlatIdx)
regmap_lookup([reg(Name,Base,Size)|_], Name, Idx, Flat) :-
    !,
    ( integer(Idx), Idx >= 0, Idx < Size
    -> Flat is Base + Idx
    ;  format("[sv] WARNING: index ~w out of range for register ~w (size ~w)~n",
              [Idx, Name, Size]),
       fail
    ).
regmap_lookup([_|Rest], Name, Idx, Flat) :-
    regmap_lookup(Rest, Name, Idx, Flat).

%%  regmap_size(+RegMap, +Name, -Size)
regmap_size([reg(Name,_,Size)|_], Name, Size) :- !.
regmap_size([_|Rest], Name, Size) :- regmap_size(Rest, Name, Size).

%%  regmap_base(+RegMap, +Name, -Base)
regmap_base([reg(Name,Base,_)|_], Name, Base) :- !.
regmap_base([_|Rest], Name, Base) :- regmap_base(Rest, Name, Base).

%%  known_register(+RegMap, +Name)
known_register(RegMap, Name) :- member(reg(Name,_,_), RegMap), !.

%%  qasm3_parse_gates_multi(+Lines, +RegMap, +NQ, -Gates)
%%  Like qasm3_parse_gates but uses RegMap for wire resolution and
%%  expands whole-register operations.
%%
%%  Pre-processing:
%%   1. Split each input line on ';' to separate multi-gate lines
%%      (the Cuccaro adder emits several gates per line).
%%   2. Strip inline comments (// ...) from each sub-line.
%%   3. Apply the standard gate-line filter.
%%   4. Expand each line to gate terms.
qasm3_parse_gates_multi(Lines, RegMap, NQ, Gates) :-
    maplist(split_semicolons, Lines, SubLists),
    flatten(SubLists, SubLines),
    maplist(strip_inline_comment, SubLines, CleanLines),
    include(qasm3_gate_line_multi, CleanLines, GLines),
    maplist(qasm3_expand_line(RegMap, NQ), GLines, GateLists),
    flatten(GateLists, Gates).

%%  split_semicolons(+Line, -SubLines)
%%  "cx a[0],b[0]; cx c[0],d[0];" -> ["cx a[0],b[0]", "cx c[0],d[0]"]
split_semicolons(Line, SubLines) :-
    atom_string(Line, S),
    split_string(S, ";", "", Parts),
    maplist([P,A]>>(string_trim(P,T), atom_string(A,T)), Parts, As),
    include([A]>>(A \= ''), As, SubLines).

%%  strip_inline_comment(+Line, -Stripped)
%%  "x fd_anc101[0]; // comment" -> "x fd_anc101[0]"
%%  Works on atoms that have already been split on ';'.
strip_inline_comment(Line, Stripped) :-
    atom_string(Line, S),
    ( sub_string(S, Pos, 2, _, "//")
    ->  sub_string(S, 0, Pos, _, Pre),
        string_trim(Pre, PreT),
        atom_string(Stripped, PreT)
    ;   Stripped = Line
    ).

%%  Filter: skip declarations, classical regs, comments, barriers, measure assignments
qasm3_gate_line_multi(L) :-
    atom_string(L, S),
    \+ string_concat("//",      _, S),
    \+ S = "",
    \+ string_concat("OPENQASM",_, S),
    \+ string_concat("include", _, S),
    \+ string_concat("gate ",   _, S),
    \+ string_concat("}",       _, S),
    \+ string_concat("qubit",   _, S),
    \+ string_concat("qreg",    _, S),
    \+ string_concat("creg",    _, S),
    \+ string_concat("bit",     _, S),
    \+ string_concat("barrier", _, S),
    \+ string_concat("measure", _, S),
    %% skip classical assignment lines like: c_x = measure x;
    \+ ( sub_string(S, _, _, _, " = ") ).

%%  qasm3_expand_line(+RegMap, +NQ, +Line, -GateList)
%%  Parses one gate line and returns a list of gate/2 terms.
%%  Whole-register operands (h x; x y;) are expanded to one gate per qubit.
qasm3_expand_line(RegMap, NQ, Line, GateList) :-
    atom_string(Line, LS),
    ( string_concat(Body, ";", LS) -> true ; Body = LS ),
    string_trim(Body, Trimmed),
    count_ctrl(Trimmed, NCtrl, Rest),
    ( sub_string(Rest, Bef, 1, _, " ")
    ->  sub_string(Rest, 0, Bef, _, GStr),
        Aft is Bef+1, sub_string(Rest, Aft, _, 0, WStr)
    ;   GStr = Rest, WStr = ""
    ),
    atom_string(GName, GStr),
    %% Parse wire groups - broadcast expands to multiple gate(Op,[W]) terms
    parse_wire_groups(WStr, RegMap, NQ, WireGroupsList),
    !,
    maplist([Wires, gate(Op,Wires)]>>(
        length(Wires, NW),
        qasm3_op(GName, NCtrl, NW, Op),
        check_wires_ok(Wires, NQ)
    ), WireGroupsList, GateList).
qasm3_expand_line(_, _, Line, []) :-
    format("[sv] WARNING: could not parse line: ~w~n", [Line]).

%%  parse_wire_groups(+WStr, +RegMap, +NQ, -WireGroupsList)
%%  For indexed wires (normal case): [[W1,W2,...]]  -- single gate
%%  For bare register name (broadcast): [[B],[B+1],...] -- one gate per qubit
parse_wire_groups(WStr, RegMap, NQ, WireGroupsList) :-
    string_trim(WStr, WStrT),
    split_string(WStrT, ",", " ", RawParts),
    maplist(string_trim, RawParts, Parts),
    include([P]>>(P \= ""), Parts, NParts),
    ( NParts = [Single],
      atom_string(RegName, Single),
      \+ sub_string(Single, _, _, _, "["),
      known_register(RegMap, RegName)
    ->  %% Whole-register broadcast: expand to per-qubit singleton lists
        regmap_size(RegMap, RegName, Size),
        regmap_base(RegMap, RegName, Base),
        ( Size > 0 -> (Last is Size-1, numlist(0, Last, Offsets)) ; Offsets = [] ),
        maplist([Off, [FlatIdx]]>>(FlatIdx is Base + Off), Offsets, WireGroupsList)
    ;   %% Normal case: resolve each part to a flat index
        maplist(resolve_wire_multi(RegMap, NQ), NParts, Wires),
        ( Wires = [] -> WireGroupsList = [[]] ; WireGroupsList = [Wires] )
    ).

resolve_wire_multi(RegMap, _NQ, Part, Idx) :-
    %% Named register with index: name[N]  or  q[N]
    sub_string(Part, Bef, 1, Aft, "["),
    Aft > 0,
    sub_string(Part, 0, Bef, _, RegNameS),
    sub_string(Part, _, Aft, 0, IdxRest),
    sub_string(IdxRest, 0, _, 1, IdxS),
    number_string(IdxNum, IdxS),
    atom_string(RegName, RegNameS),
    ( known_register(RegMap, RegName)
    -> regmap_lookup(RegMap, RegName, IdxNum, Idx)
    ;  Idx = IdxNum   %% fallback: old-style q[N] raw index
    ), !.
resolve_wire_multi(_RegMap, _NQ, Part, Idx) :-
    %% Plain integer (old-style)
    number_string(Idx, Part), !.


/* ............................................................
   QASM 3.0 parser  (original single-register path, kept for
   backward compatibility with bell_test/parity_test style QASM)

   Handles:
     qubit[N] q;              register declaration
     h q[I];                  single-qubit gates
     rz(angle) q[I];          parametric gates
     ctrl @ x q[C], q[T];     controlled gates
     ctrl @ ctrl @ x ...      multi-controlled
   ............................................................ */

qasm3_parse_nqubits(Lines, NQ) :-
    ( member(L, Lines), parse_qreg(L, NQ) -> true
    ; throw(error(no_qubit_register, qasm3_parse_nqubits/2))
    ).

parse_qreg(L, N) :-
    atom_concat('qubit[', R, L),
    ( atom_concat(NS, '] q;', R) ; atom_concat(NS, '] q', R) ),
    atom_number(NS, N), !.
parse_qreg(L, N) :-
    atom_concat('qreg ', R, L),
    atom_concat('q[', R2, R),
    ( atom_concat(NS, '];', R2) ; atom_concat(NS, ']', R2) ),
    atom_number(NS, N).

qasm3_parse_gates(Lines, NQ, Gates) :-
    include(qasm3_gate_line, Lines, GLines),
    maplist(qasm3_parse_line(NQ), GLines, Gates).

qasm3_gate_line(L) :-
    \+ atom_concat('//',     _, L),
    \+ L = '',
    \+ atom_concat('OPENQASM',  _, L),
    \+ atom_concat('include',   _, L),
    \+ atom_concat('gate ',     _, L),
    \+ atom_concat('}',         _, L),
    \+ atom_concat('qubit',     _, L),
    \+ atom_concat('qreg',      _, L),
    \+ atom_concat('creg',      _, L),
    \+ atom_concat('bit',       _, L),
    \+ atom_concat('barrier',   _, L).

qasm3_parse_line(NQ, Line, gate(Op, Wires)) :-
    atom_string(Line, LS),
    ( string_concat(Body, ";", LS) -> true ; Body = LS ),
    string_trim(Body, Trimmed),
    count_ctrl(Trimmed, NCtrl, Rest),
    ( sub_string(Rest, Bef, 1, _, " ")
    ->  sub_string(Rest, 0, Bef, _, GStr),
        Aft is Bef+1, sub_string(Rest, Aft, _, 0, WStr)
    ;   GStr = Rest, WStr = ""
    ),
    atom_string(GName, GStr),
    parse_wire_list(WStr, Wires),
    length(Wires, NW),
    qasm3_op(GName, NCtrl, NW, Op),
    ( check_wires_ok(Wires, NQ) -> true
    ; format("[sv] WARNING: wire out of range: ~w~n", [Line]),
      fail
    ).

count_ctrl(Str, N, Rem) :-
    ( string_concat("ctrl @ ", R, Str)
    ->  count_ctrl(R, N1, Rem), N is N1+1
    ;   N = 0, Rem = Str
    ).

parse_wire_list(WStr, Idxs) :-
    split_string(WStr, ",", " ", Parts),
    maplist(parse_wire, Parts, Idxs).

parse_wire(Part, Idx) :-
    string_trim(Part, T),
    ( sub_string(T, Bef, 1, _, "[")
    ->  Aft is Bef+1, sub_string(T, Aft, _, 1, IS), number_string(Idx, IS)
    ;   number_string(Idx, T)
    ).

%%  qasm3_op(+GateName, +NCtrl, +NWires, -Op)

%%  ctrl @ x  -> cnx family
qasm3_op(x, N, NW, Op) :- N > 0, !,
    ( NW=:=2 -> Op=cx ; NW=:=3 -> Op=ccx ; Op=cnx(NW) ).

%%  ctrl @ z  -> cz or ctrl_op
qasm3_op(z, 1, _, cz) :- !.
qasm3_op(z, N, _, ctrl_op(z, N)) :- N > 1, !.

%%  ctrl @ rz/rx/ry
qasm3_op(GName, N, _, ctrl_op(Op, N)) :-
    N > 0,
    atom_string(GName, GS),
    qasm3_param_op(GS, Op), !.

%%  Parametric single-qubit (no ctrl)
qasm3_op(GName, 0, _, Op) :-
    atom_string(GName, GS),
    qasm3_param_op(GS, Op), !.

%%  Named single-qubit
qasm3_op(h,    0, _, h)    :- !.
qasm3_op(x,    0, _, x)    :- !.
qasm3_op(y,    0, _, y)    :- !.
qasm3_op(z,    0, _, z)    :- !.
qasm3_op(s,    0, _, s)    :- !.
qasm3_op(sdg,  0, _, sdg)  :- !.
qasm3_op(t,    0, _, t)    :- !.
qasm3_op(tdg,  0, _, tdg)  :- !.
qasm3_op(cx,   0, _, cx)   :- !.
qasm3_op(cz,   0, _, cz)   :- !.
qasm3_op(ccx,  0, _, ccx)  :- !.
qasm3_op(swap, 0, _, swap) :- !.
qasm3_op(measure, 0, _, measure) :- !.
qasm3_op(Name, NC, NW, x) :-
    format("[sv] WARNING: unknown gate ~w (ctrl=~w, wires=~w) -- skipping~n",
           [Name, NC, NW]).

qasm3_param_op(GS, rz(T))    :- string_concat("rz(", R, GS), string_concat(TS, ")", R), number_string(T, TS), !.
qasm3_param_op(GS, rx(T))    :- string_concat("rx(", R, GS), string_concat(TS, ")", R), number_string(T, TS), !.
qasm3_param_op(GS, ry(T))    :- string_concat("ry(", R, GS), string_concat(TS, ")", R), number_string(T, TS), !.
qasm3_param_op(GS, phase(T)) :- string_concat("p(",  R, GS), string_concat(TS, ")", R), number_string(T, TS), !.

check_wires_ok([], _).
check_wires_ok([W|Ws], N) :- integer(W), W>=0, W<N, check_wires_ok(Ws,N).

string_trim(S, T) :-
    ( string_concat(" ", R, S) -> string_trim(R, T)
    ; string_concat(R, " ", S) -> string_trim(R, T)
    ; T = S
    ).




/* ============================================================
   Helper predicates for maplist (avoid two-arg yall lambdas)
   ============================================================ */

%%  zero_amp(+I, -Amp)  :  |0> = c(1,0), rest = c(0,0)
zero_amp(0, c(1.0,0.0)) :- !.
zero_amp(_, c(0.0,0.0)).

%%  extract_bit_sv(+I, +P, -B)  :  B = bit P of I (for int_to_bits_msb)
extract_bit_sv(I, P, B) :- B is (I >> P) /\ 1.

%%  identity_row(+Size1, +R, -Row)
identity_row(Size1, R, Row) :-
    numlist(0, Size1, Cols),
    maplist(identity_entry(R), Cols, Row).

identity_entry(R, C, V) :-
    ( R =:= C -> V = c(1.0,0.0) ; V = c(0.0,0.0) ).

%%  project_amp(+Wire, +Outcome, +State, +I, -Amp)
project_amp(Wire, Outcome, State, I, Amp) :-
    B is (I >> Wire) /\ 1,
    ( B =:= Outcome -> nth0(I, State, Amp) ; Amp = c(0.0,0.0) ).


%%  swap_row(+I, +J, +RI, +RJ, +M, +Idx, -Row)
swap_row(I, J, RI, RJ, M, Idx, Row) :-
    ( Idx=:=I -> Row=RJ ; Idx=:=J -> Row=RI ; nth0(Idx,M,Row) ).

%%  replace_row(+I, +J, +RI, +RJ, +M0, +Idx, -Row)
replace_row(I, J, RI, RJ, M0, Idx, Row) :-
    ( Idx=:=I -> Row=RI ; Idx=:=J -> Row=RJ ; nth0(Idx,M0,Row) ).

%%  state_prob_pair(+State, +I, -I-Prob)
state_prob_pair(State, I, I-P) :- state_prob(State, I, P).


%%  bits_to_int_step(+Bit, +Acc, -Out)  :  shift-or step for bits_to_int_msb
bits_to_int_step(B, Acc, Out) :- Out is (Acc << 1) \/ B.

%%  most_prob_step(+State, +I, +BestI-BestP, -NewBest)
most_prob_step(State, I, BI-BP, New) :-
    state_prob(State, I, P),
    ( P > BP -> New = I-P ; New = BI-BP ).


%%  wire_idx_pair(+WM, +Wire, -Idx)
wire_idx_pair(WM, C, I) :- wire_idx(C, WM, I).

%%  state_prob_for(+State, +I, -P)
state_prob_for(State, I, P) :- state_prob(State, I, P).


%%  matches_wire(+Wire, +Value, +I)
matches_wire(Wire, Value, I) :-
    B is (I >> Wire) /\ 1, B =:= Value.

/* ============================================================
   Measurement, sampling, and analysis
   ============================================================ */

%%  sv_measure(+Wire, +NQubits, +State, -Outcome, -PostState)
sv_measure(Wire, NQubits, State, Outcome, Post) :-
    qubit_prob(Wire, NQubits, State, 1, P1),
    random(R),
    ( R < P1 -> Outcome = 1 ; Outcome = 0 ),
    project_qubit(Wire, NQubits, State, Outcome, Post).

qubit_prob(Wire, NQubits, State, Value, Prob) :-
    Size is 2^NQubits, Size1 is Size-1,
    numlist(0, Size1, Is),
    include(matches_wire(Wire, Value), Is, Match),
    maplist(state_prob_for(State), Match, Ps),
    sumlist(Ps, Prob).

project_qubit(Wire, NQubits, State, Outcome, Post) :-
    Size is 2^NQubits, Size1 is Size-1,
    numlist(0, Size1, Is),
    maplist(project_amp(Wire, Outcome, State), Is, Proj),
    state_normalise(Proj, Post).

%%  sv_sample(+State, +NQubits, +NShots, -Outcomes)
sv_sample(State, _NQ, NShots, Outcomes) :-
    build_cdf(State, CDF),
    findall(I, (between(1,NShots,_),
                random(R), sample_from_cdf(CDF,R,I)), Outcomes).

build_cdf(State, CDF) :-
    ( State = sparse(_, Assoc) ->
        assoc_to_list(Assoc, Pairs),
        build_cdf_sparse(Pairs, 0.0, CDF)
    ;
        functor(State, sv, Size),
        build_cdf_loop(State, 0, Size, 0.0, CDF)
    ).

build_cdf_sparse([], _, []).
build_cdf_sparse([Idx-Amp|Rest], Acc, [Idx-Cum|CDF]) :-
    c_abs_sq(Amp, P),
    Cum is Acc + P,
    build_cdf_sparse(Rest, Cum, CDF).

build_cdf_loop(_, I, Size, _, []) :- I >= Size, !.
build_cdf_loop(State, I, Size, Acc, [I-Cum|Rest]) :-
    I1 is I+1,
    arg(I1, State, Amp), c_abs_sq(Amp, P),
    Cum is Acc + P,
    build_cdf_loop(State, I1, Size, Cum, Rest).

build_cdf_acc([], _, []).
build_cdf_acc([I-P|Rest], Acc, [I-Cum|CDF]) :-
    Cum is Acc+P, build_cdf_acc(Rest, Cum, CDF).

sample_from_cdf([I-Cum|_], R, I) :- R =< Cum, !.
sample_from_cdf([_|Rest],  R, I) :- !, sample_from_cdf(Rest, R, I).
sample_from_cdf([I-_],     _, I) :- !.

%%  sv_most_probable(+State, +NQ, -Idx, -Prob)
%%  Uses a direct arg-loop to avoid building a list of 2^NQ elements.
sv_most_probable(sparse(_, Assoc), _NQ, BestIdx, BestProb) :- !,
    assoc_to_list(Assoc, Pairs),
    foldl([Idx-Amp, BI-BP, NBI-NBP]>>(
        c_abs_sq(Amp, P),
        ( P > BP -> NBI=Idx, NBP=P ; NBI=BI, NBP=BP )
    ), Pairs, (-1)-(-1.0), BestIdx-BestProb).
sv_most_probable(State, _NQ, BestIdx, BestProb) :-
    functor(State, sv, Size),
    most_prob_loop_dense(State, 0, Size, -1, -1.0, BestIdx, BestProb).

%%  most_prob_loop/7 -- defined later with sparse/dense dispatch
%%  (dense fallback below)
most_prob_loop_dense(_, I, Size, BestI, BestP, BestI, BestP) :- I >= Size, !.
most_prob_loop_dense(State, I, Size, BI, BP, OutI, OutP) :-
    I1 is I+1,
    arg(I1, State, Amp), c_abs_sq(Amp, P),
    ( P > BP -> NBI = I, NBP = P ; NBI = BI, NBP = BP ),
    most_prob_loop_dense(State, I1, Size, NBI, NBP, OutI, OutP).


/* ============================================================
   Display utilities
   ============================================================ */

%% sv_probabilities -- unified sparse/dense version below


%%  sv_amplitudes(+State, +NQubits)
sv_amplitudes(State, NQ) :-
    format("~nAmplitudes (~w qubits):~n", [NQ]),
    ( State = sparse(_, Assoc) ->
        assoc_to_list(Assoc, Pairs),
        forall(member(I-c(R,Im), Pairs),
            ( c_abs_sq(c(R,Im), P), P > 1.0e-6 ->
                format("  |~w>: ~6f + ~6fi~n", [I, R, Im])
            ; true ))
    ;
        functor(State, sv, Size),
        sv_amp_loop(State, 0, Size)
    ).

sv_amp_loop(_, I, Size) :- I >= Size, !.
sv_amp_loop(State, I, Size) :-
    I1 is I+1, arg(I1, State, c(R,Im)),
    c_abs_sq(c(R,Im), P),
    ( P > 1.0e-6 -> format("  |~w>: ~6f + ~6fi~n", [I, R, Im]) ; true ),
    sv_amp_loop(State, I1, Size).

%%  print_results(+State, +NQubits)
print_results(State, NQ) :-
    format("~n-- Simulation result (~w qubits) --~n~n", [NQ]),
    sv_most_probable(State, NQ, BestIdx, BestProb),
    BestPct is BestProb*100.0,
    ( BestProb > 1.0e-9 ->
        format("  Most probable: |~w>  (~1f%)~n~n", [BestIdx, BestPct])
    ;   format("  (state vector is all-zero -- circuit may be unphysical)~n~n", [])
    ),
    format("  States with >1% probability:~n"),
    print_notable(State),
    nl.

%%  print_notable/1 -- dispatch for sparse and dense
print_notable(sparse(_, Assoc)) :- !,
    assoc_to_list(Assoc, Pairs),
    include([_-Amp]>>(c_abs_sq(Amp, Sq), Sq > 0.01), Pairs, Notable),
    length(Notable, NNot),
    ( NNot =:= 0 ->
        format("    (no states above 1% threshold)~n")
    ;
        ( NNot > 64 -> length(Show, 64), append(Show, _, Notable) ; Show = Notable ),
        forall(member(Idx-Amp, Show),
            ( c_abs_sq(Amp, P), Pct is P*100.0,
              format("    |~w>  (~1f%)~n", [Idx, Pct]) ))
    ).
print_notable(State) :-
    functor(State, sv, Size),
    print_notable_loop(State, 0, Size, 0).

%%  print_notable_loop -- unified version above



/* ============================================================
   Unified sparse/dense display predicates
   ============================================================ */

%%  sv_probabilities(+State, +NQubits)
%%
%%  Display non-zero probability states.
%%  When total non-zero states exceed the display cap (64), we show:
%%    - ALL high-probability states (prob > 1%) regardless of index
%%    - Enough low-probability states to fill the cap
%%  This ensures solution states are never hidden behind low-index background states.
sv_probabilities(State, NQ) :-
    format("~nProbabilities (~w qubits):~n", [NQ]),
    ( State = sparse(_, Assoc) ->
        assoc_to_list(Assoc, Pairs),
        include([_-Amp]>>(c_abs_sq(Amp, Sq), Sq > 1.0e-6), Pairs, NonZero),
        length(NonZero, Total),
        ( Total =< 64 ->
            forall(member(Idx-Amp2, NonZero),
                ( c_abs_sq(Amp2, P), Pct is P*100.0,
                  format("  |~w> : ~4f%~n", [Idx, Pct]) ))
        ;
            %% Split into notable (>1%) and background states
            include([_-Amp2]>>(c_abs_sq(Amp2, Sq2), Sq2 > 0.01), NonZero, Notable),
            exclude([_-Amp2]>>(c_abs_sq(Amp2, Sq2), Sq2 > 0.01), NonZero, Background),
            length(Notable, NNotable),
            BgCap is max(0, 64 - NNotable),
            length(BgShow, BgCap), append(BgShow, BgRest, Background),
            length(BgRest, NHidden),
            %% Print background states first (in index order), then notable
            forall(member(Idx-Amp2, BgShow),
                ( c_abs_sq(Amp2, P), Pct is P*100.0,
                  format("  |~w> : ~4f%~n", [Idx, Pct]) )),
            ( NHidden > 0 ->
                format("  ... (~w more background states not shown)~n", [NHidden])
            ; true ),
            %% Always show all notable (solution) states
            ( NNotable > 0 ->
                format("  --- Notable states (>1%): ---~n"),
                forall(member(Idx-Amp2, Notable),
                    ( c_abs_sq(Amp2, P), Pct is P*100.0,
                      format("  |~w> : ~4f%~n", [Idx, Pct]) ))
            ; true )
        )
    ;
        functor(State, sv, Size),
        prob_loop_dense(State, 0, Size, 0)
    ).

%%  prob_loop_dense: iterate dense state vector, print non-zero probabilities
prob_loop_dense(_, I, Size, _) :- I >= Size, !.
prob_loop_dense(State, I, Size, Shown) :-
    ( Shown >= 64 ->
        Remaining is Size - I,
        format("  ... (~w more states not shown; use amplitudes(true) option)~n",
               [Remaining]),
        !
    ;
        I1 is I+1,
        arg(I1, State, Amp), c_abs_sq(Amp, P),
        ( P > 1.0e-6 ->
            Pct is P*100.0,
            format("  |~w> : ~4f%~n", [I, Pct]),
            Shown1 is Shown + 1
        ;   Shown1 = Shown ),
        prob_loop_dense(State, I1, Size, Shown1)
    ).

%%  print_notable_loop: print states > 1% for print_results
print_notable_loop(State, _Start, _Size, _Shown) :-
    State = sparse(_, Assoc), !,
    assoc_to_list(Assoc, Pairs),
    include([_-Amp]>>(c_abs_sq(Amp, Sq), Sq > 0.01), Pairs, Notable),
    ( Notable = [] ->
        format("    (all amplitudes below 1% threshold)~n")
    ;
        ( length(Notable, NNot), NNot > 64 ->
            length(Show, 64), append(Show, _, Notable)
        ;   Show = Notable ),
        forall(member(Idx-Amp2, Show),
            ( c_abs_sq(Amp2, P), Pct is P*100.0,
              format("    |~w>  (~1f%)~n", [Idx, Pct]) ))
    ).
print_notable_loop(_, I, Size, _) :- I >= Size, !.
print_notable_loop(State, I, Size, Shown) :-
    ( Shown >= 64 -> ! ;
        I1 is I+1, arg(I1, State, Amp), c_abs_sq(Amp, P),
        ( P > 0.01 ->
            Pct is P*100.0,
            format("    |~w>  (~1f%)~n", [I,Pct]),
            Shown1 is Shown+1
        ;   Shown1 = Shown ),
        print_notable_loop(State, I1, Size, Shown1)
    ).

/* ============================================================
   SPARSE state vector implementation
   ============================================================
   For circuits with NQ >= 18 qubits (2^18 = 262144 states),
   the dense sv/N compound is too large.  The sparse representation
   stores only non-zero amplitudes in a library(assoc) AVL tree.

   State term:  sparse(NQubits, Assoc)
     where Assoc maps integer index -> c(Re, Im).
     Missing keys have amplitude c(0.0, 0.0).
   ============================================================ */

:- use_module(library(assoc)).

%% -- Construction ---------------------------------------------

state_zero_sparse(N, sparse(N, Assoc)) :-
    empty_assoc(A0),
    put_assoc(0, A0, c(1.0, 0.0), Assoc).

%% -- Access ---------------------------------------------------

sv_get_sparse(sparse(_, Assoc), Idx, Amp) :-
    ( get_assoc(Idx, Assoc, Amp) -> true ; Amp = c(0.0, 0.0) ).

state_prob_sparse(sparse(_, Assoc), Idx, Prob) :-
    ( get_assoc(Idx, Assoc, Amp) ->
        c_abs_sq(Amp, Prob)
    ;   Prob = 0.0
    ).

%% -- Gate application -----------------------------------------

apply_gate_sparse(Op, GateWires, NQubits, sparse(N,AIn), sparse(N,AOut)) :-
    gate_mat(Op, GateM),
    length(GateWires, K), GateSize is 2^K,
    GateSize1 is GateSize - 1,

    %% -- FAST PATH with key caching ---------------------------------------
    %% assoc_to_keys is O(N) and called for every gate -- expensive at 4000+ gates.
    %% Cache: if AIn matches the last-seen assoc, reuse its key list.
    %% The cache is invalidated whenever apply_gate_sparse_work produces a new AOut.
    get_or_compute_occupied_keys(AIn, OccupiedKeys),

    %% Gate bitmask: if no occupied state touches gate wires, gate is identity.
    foldl([W, Acc, New]>>(New is Acc \/ (1 << W)), GateWires, 0, GMask),
    ( \+ (member(K3, OccupiedKeys), K3 /\ GMask =\= 0) ->
        GateM = [[c(M00R,_)|_]|_],
        ( abs(M00R - 1.0) < 1.0e-10 ->
            AOut = AIn   %% identity on |0..0>: skip entirely (no cache update needed)
        ;
            apply_gate_sparse_work(GateWires, GateM, GateSize, GateSize1,
                                   K, NQubits, OccupiedKeys, AIn, AOut),
            invalidate_key_cache
        )
    ;
        apply_gate_sparse_work(GateWires, GateM, GateSize, GateSize1,
                               K, NQubits, OccupiedKeys, AIn, AOut),
        invalidate_key_cache
    ).

%%  get_or_compute_occupied_keys(+Assoc, -Keys)
%%  Returns the cached key list if assoc hasn't changed, else recomputes.
get_or_compute_occupied_keys(Assoc, Keys) :-
    ( nb_getval(sv_key_cache, cached(CachedAssoc, CachedKeys)),
      CachedAssoc == Assoc ->
        Keys = CachedKeys
    ;
        assoc_to_keys(Assoc, Keys),
        nb_setval(sv_key_cache, cached(Assoc, Keys))
    ).

invalidate_key_cache :-
    nb_setval(sv_key_cache, no_cache).

apply_gate_sparse_work(GateWires, GateM, GateSize, GateSize1,
                       K, NQubits, OccupiedKeys, AIn, AOut) :-
    NQubits1 is NQubits - 1,
    numlist(0, NQubits1, AllQubits),
    subtract(AllQubits, GateWires, BgWires),
    functor(GateOffsets, go, GateSize),
    ( K > 0 ->
        K1 is K-1,
        forall(between(0, GateSize1, J),
            ( gate_offset_msb(J, K1, 0, GateWires, Off),
              J1 is J+1, nb_setarg(J1, GateOffsets, Off)
            ))
    ; nb_setarg(1, GateOffsets, 0) ),
    flatten(GateM, GateFlat), GateArr =.. [mat | GateFlat],
    bg_mask(BgWires, BgMask),
    maplist([Kx,B]>>(B is Kx /\ BgMask), OccupiedKeys, BgRaw),
    sort(BgRaw, UniqueBgBases),
    nb_setval(sv_sparse_assoc, AIn),
    forall(
        member(BgBase, UniqueBgBases),
        apply_gate_block_sparse(BgBase, GateOffsets, GateArr, GateSize, GateSize1, AIn)
    ),
    nb_getval(sv_sparse_assoc, AOut).

%%  bg_mask(+BgWires, -Mask): bitmask with 1s at background wire positions
bg_mask([], 0).
bg_mask([W|Ws], Mask) :-
    bg_mask(Ws, RestMask),
    Mask is RestMask \/ (1 << W).

%%  apply_gate_block_sparse: read GateSize amps for BgBase, apply matrix, write back
%%
%%  Key optimization: in Grover circuits, ancilla qubits are almost always |0>.
%%  When gate acts on ancilla that are in |0> (InJ=0 is the only non-zero input),
%%  check if the gate is identity on the |0...0> subspace.
%%  For all standard gates, GateM[0][0] = 1 and GateM[j][0] = 0 for j>0,
%%  meaning |0...0> maps to |0...0> unchanged.  In that case: skip the block.
%%
apply_gate_block_sparse(BgBase, GateOffsets, GateArr, GateSize, GateSize1, AIn) :-
    %% Get gate combo 0 (all gate-bits=0) state index
    arg(1, GateOffsets, GOff0),
    SIdx0 is BgBase + GOff0,
    ( get_assoc(SIdx0, AIn, Amp0) -> true ; Amp0 = c(0.0,0.0) ),
    c_abs_sq(Amp0, Mag0),
    %% Check if any OTHER gate combo (InJ>0) has a non-zero state
    ( ( between(1, GateSize1, InJ2),
        InJ21 is InJ2+1,
        arg(InJ21, GateOffsets, GOff2),
        SIdx2 is BgBase + GOff2,
        get_assoc(SIdx2, AIn, c(R2,Im2)),
        abs(R2)+abs(Im2) > 1.0e-15 ) ->
        HasHigherNonZero = true
    ;   HasHigherNonZero = false
    ),
    ( HasHigherNonZero = false, Mag0 < 1.0e-15 ->
        %% All inputs are zero: block has no effect, skip
        true
    ; HasHigherNonZero = false ->
        %% Only InJ=0 is non-zero: check if gate maps |0..0>->|0..0> (identity on this basis state)
        %% This is true for all standard gates (X,H,CX,CCX: GateM[0][0]=1, GateM[j>0][0]=0)
        arg(1, GateArr, c(M00Re,_)),
        ( abs(M00Re - 1.0) < 1.0e-10 ->
            %% First column of gate is e_0: |0..0> -> |0..0>, no change needed for this block
            true
        ;   %% Gate mixes |0..0> with other states (e.g. superposition input)
            apply_gate_block_full(BgBase, GateOffsets, GateArr, GateSize, GateSize1, AIn)
        )
    ;   %% Multiple non-zero inputs: full computation needed
        apply_gate_block_full(BgBase, GateOffsets, GateArr, GateSize, GateSize1, AIn)
    ).

%%  apply_gate_block_full: full matrix multiply for this gate block
%%  Reads all inputs first, computes all outputs, then applies all updates at once.
apply_gate_block_full(BgBase, GateOffsets, GateArr, GateSize, GateSize1, AIn) :-
    %% Step 1: read all input amplitudes into a local compound
    functor(InAmps, amp, GateSize),
    forall(between(0, GateSize1, InJ),
        ( InJ1 is InJ+1,
          arg(InJ1, GateOffsets, GOff),
          SIdx is BgBase + GOff,
          ( get_assoc(SIdx, AIn, Amp) -> true ; Amp = c(0.0,0.0) ),
          nb_setarg(InJ1, InAmps, Amp)
        )
    ),
    %% Step 2: compute all output amplitudes (no assoc access here)
    functor(OutAmps, out, GateSize),
    functor(OutIdxs, oidx, GateSize),
    forall(between(0, GateSize1, OutJ),
        ( OutJ1 is OutJ+1,
          arg(OutJ1, GateOffsets, OutOff),
          OutSIdx is BgBase + OutOff,
          RowBase is OutJ * GateSize,
          dot_fast(GateSize1, RowBase, GateArr, InAmps, c(0.0,0.0), NewAmp),
          nb_setarg(OutJ1, OutAmps, NewAmp),
          nb_setarg(OutJ1, OutIdxs, OutSIdx)
        )
    ),
    %% Step 3: apply all updates to assoc in one read-modify-write pass
    nb_getval(sv_sparse_assoc, ACur),
    apply_updates(0, GateSize1, OutIdxs, OutAmps, ACur, AFinal),
    nb_setval(sv_sparse_assoc, AFinal).

%%  apply_updates: fold all (index, amplitude) pairs into assoc
apply_updates(I, Max, _, _, A, A) :- I > Max, !.
apply_updates(I, Max, OutIdxs, OutAmps, AIn, AOut) :-
    I1 is I+1,
    arg(I1, OutIdxs, Idx),
    arg(I1, OutAmps, Amp),
    update_assoc_amp(Idx, Amp, AIn, AMid),
    I2 is I+1,
    apply_updates(I2, Max, OutIdxs, OutAmps, AMid, AOut).

%%  update_assoc_amp(+Idx, +Amp, +AIn, -AOut)
%%  Set AOut[Idx] = Amp, pruning near-zero entries.
update_assoc_amp(Idx, Amp, AIn, AOut) :-
    c_abs_sq(Amp, Sq),
    ( Sq < 1.0e-20 ->
        %% Remove near-zero entry to keep assoc sparse
        ( del_assoc(Idx, AIn, _, AOut) -> true ; AOut = AIn )
    ;
        put_assoc(Idx, AIn, Amp, AOut)
    ).

%% -- Overriding the main pipeline ----------------------------

%%  state_zero/2 -- always use sparse representation.
%%  Dense mode (building a sv/2^N term) is extremely slow for N>=14 because it
%%  allocates 2^N Prolog cells just for the initial zero state.  Sparse mode
%%  starts with a single-entry association list and expands on demand, which is
%%  much faster for Grover circuits that remain sparse throughout.
state_zero(N, State) :-
    state_zero_sparse(N, State).

%%  sv_get/3 -- dispatch to sparse or dense
sv_get(sparse(_, Assoc), Idx, Amp) :- !,
    ( get_assoc(Idx, Assoc, Amp) -> true ; Amp = c(0.0, 0.0) ).
sv_get(State, Idx, Amp) :-
    Idx1 is Idx+1, arg(Idx1, State, Amp).

%%  state_prob/3 -- dispatch
state_prob(sparse(_, Assoc), Idx, Prob) :- !,
    ( get_assoc(Idx, Assoc, Amp) ->
        c_abs_sq(Amp, Prob)
    ;   Prob = 0.0
    ).
state_prob(State, Idx, Prob) :-
    sv_get(State, Idx, Amp), c_abs_sq(Amp, Prob).

%%  apply_gate/5 -- dispatch to sparse or dense
apply_gate(Op, GateWires, NQubits, sparse(N,AIn), StateOut) :- !,
    apply_gate_sparse(Op, GateWires, NQubits, sparse(N,AIn), StateOut).
apply_gate(Op, GateWires, NQubits, StateIn, StateOut) :-
    functor(StateIn, sv, _),
    apply_gate_dense(Op, GateWires, NQubits, StateIn, StateOut).

%%  apply_gate_dense is the original apply_gate body:
apply_gate_dense(Op, GateWires, NQubits, StateIn, StateOut) :-
    gate_mat(Op, GateM),
    copy_term(StateIn, StateOut),
    length(GateWires, K), GateSize is 2^K,
    NQubits1 is NQubits - 1,
    numlist(0, NQubits1, AllQubits),
    subtract(AllQubits, GateWires, BgWires),
    length(BgWires, BgK), BgSize is 2^BgK,
    BgSize1   is BgSize   - 1,
    GateSize1 is GateSize - 1,
    functor(GateOffsets, go, GateSize),
    ( K > 0 ->
        K1 is K-1,
        forall(between(0, GateSize1, J),
            ( gate_offset_msb(J, K1, 0, GateWires, Off),
              J1 is J+1, nb_setarg(J1, GateOffsets, Off)
            ))
    ; nb_setarg(1, GateOffsets, 0) ),
    flatten(GateM, GateFlat),
    GateArr =.. [mat | GateFlat],
    functor(BgBases, bg, BgSize),
    precompute_bg_bases(BgWires, BgSize, BgBases),
    forall(
        between(0, BgSize1, BgJ),
        ( BgJ1 is BgJ+1, arg(BgJ1, BgBases, BgBase),
          apply_gate_block(BgBase, GateOffsets, GateArr, GateSize, StateIn, StateOut)
        )
    ).

%% -- Sparse result display ------------------------------------

%%  (most_prob_loop sparse handled directly in sv_most_probable)

%%  (prob_loop sparse override removed -- handled in sv_probabilities)

%%  state_norm_sq -- sparse override
state_norm_sq(sparse(_, Assoc), NSq) :- !,
    assoc_to_values(Assoc, Amps),
    foldl([Amp, Acc, New]>>(c_abs_sq(Amp, Sq), New is Acc+Sq), Amps, 0.0, NSq).


/* ============================================================
   FLAT SPARSE implementation  (fast_sparse)
   ============================================================
   Replaces assoc-tree sparse for large circuits.
   Representation: fast_sparse(N, IdxArr, AmpArr, Size)
     N       = total qubits
     IdxArr  = compound idx(I0,I1,...,ISize-1)  -- sorted state indices
     AmpArr  = compound amp(c(R0,Im0),...,c(Rn,Imn))  -- matching amplitudes
     Size    = number of occupied states

   Access:   O(log Size) via binary search on IdxArr
   Update:   O(1) nb_setarg on AmpArr  (no allocation!)
   Expand:   when a new non-zero state appears: rebuild (rare in Grover circuits)
   ============================================================ */

:- discontiguous state_zero/2, sv_get/3, state_prob/3, apply_gate/5.

%% -- Construction -----------------------------------------------

state_zero_fsparse(N, fast_sparse(N, IdxArr, AmpArr, 1)) :-
    IdxArr =.. [idx, 0],
    AmpArr =.. [amp, c(1.0, 0.0)].

%% -- Access -----------------------------------------------------

fsparse_get(fast_sparse(_, IdxArr, AmpArr, Size), Idx, Amp) :-
    Size1 is Size - 1,
    ( fsparse_bsearch(IdxArr, 0, Size1, Idx, Pos) ->
        Pos1 is Pos + 1,
        arg(Pos1, AmpArr, Amp)
    ;   Amp = c(0.0, 0.0)
    ).

%% Binary search: find position of Idx in IdxArr[Lo..Hi], or fail
fsparse_bsearch(IdxArr, Lo, Hi, Target, Pos) :-
    Lo =< Hi,
    Mid is (Lo + Hi) // 2,
    Mid1 is Mid + 1,
    arg(Mid1, IdxArr, MidVal),
    ( MidVal =:= Target -> Pos = Mid
    ; MidVal < Target   -> Lo1 is Mid + 1, fsparse_bsearch(IdxArr, Lo1, Hi, Target, Pos)
    ;                      Hi1 is Mid - 1, fsparse_bsearch(IdxArr, Lo, Hi1, Target, Pos)
    ).

fsparse_put(fast_sparse(N, IdxArr, AmpArr, Size), Idx, Amp,
            fast_sparse(N, IdxArr2, AmpArr2, Size2)) :-
    Size1 is Size - 1,
    c_abs_sq(Amp, Sq),
    ( fsparse_bsearch(IdxArr, 0, Size1, Idx, Pos) ->
        %% Existing slot: update in place or remove if zero
        ( Sq < 1.0e-20 ->
            %% Remove: rebuild without this entry
            fsparse_remove(Pos, IdxArr, AmpArr, Size, IdxArr2, AmpArr2),
            Size2 is Size - 1
        ;   %% Update in place: nb_setarg on AmpArr
            Pos1 is Pos + 1,
            copy_term(AmpArr, AmpArr2),
            nb_setarg(Pos1, AmpArr2, Amp),
            IdxArr2 = IdxArr,
            Size2 = Size
        )
    ;   %% New slot: insert in sorted order
        ( Sq < 1.0e-20 ->
            IdxArr2 = IdxArr, AmpArr2 = AmpArr, Size2 = Size  %% don't insert zero
        ;   fsparse_insert(Idx, Amp, IdxArr, AmpArr, Size, IdxArr2, AmpArr2),
            Size2 is Size + 1
        )
    ).

%% Insert Idx/Amp into sorted arrays at correct position
fsparse_insert(Idx, Amp, IdxArr, AmpArr, Size, IdxArr2, AmpArr2) :-
    functor(IdxArr, idx, Size),
    functor(AmpArr, amp, Size),
    Size2 is Size + 1,
    functor(IdxArr2, idx, Size2),
    functor(AmpArr2, amp, Size2),
    %% Find insertion point
    fsparse_insert_pos(IdxArr, 0, Size, Idx, InsPos),
    %% Copy elements before InsPos
    forall(between(0, InsPos-1, I), (
        I1 is I+1, arg(I1, IdxArr, IV), arg(I1, AmpArr, AV),
        nb_setarg(I1, IdxArr2, IV), nb_setarg(I1, AmpArr2, AV)
    )),
    %% Insert new element
    Ins1 is InsPos+1,
    nb_setarg(Ins1, IdxArr2, Idx), nb_setarg(Ins1, AmpArr2, Amp),
    %% Copy elements after InsPos
    forall(between(InsPos, Size-1, I), (
        I1 is I+1, I2 is I+2, arg(I1, IdxArr, IV), arg(I1, AmpArr, AV),
        nb_setarg(I2, IdxArr2, IV), nb_setarg(I2, AmpArr2, AV)
    )).

fsparse_insert_pos(_, Size, Size, _, Size) :- !.
fsparse_insert_pos(IdxArr, Pos, Size, Idx, InsPos) :-
    Pos1 is Pos + 1,
    arg(Pos1, IdxArr, V),
    ( V > Idx -> InsPos = Pos
    ; Pos2 is Pos + 1, fsparse_insert_pos(IdxArr, Pos2, Size, Idx, InsPos)
    ).

%% Remove element at Pos (0-indexed)
fsparse_remove(Pos, IdxArr, AmpArr, Size, IdxArr2, AmpArr2) :-
    Size2 is Size - 1,
    functor(IdxArr2, idx, Size2),
    functor(AmpArr2, amp, Size2),
    forall(between(0, Size2-1, I), (
        (I < Pos -> SrcI = I ; SrcI is I + 1),
        SrcI1 is SrcI+1, I1 is I+1,
        arg(SrcI1, IdxArr, IV), arg(SrcI1, AmpArr, AV),
        nb_setarg(I1, IdxArr2, IV), nb_setarg(I1, AmpArr2, AV)
    )).

%% -- Gate application -------------------------------------------

apply_gate_fsparse(Op, GateWires, NQubits,
                   fast_sparse(N,IdxArr,_,Size), StateOut) :-
    gate_mat(Op, GateM),
    length(GateWires, K), GateSize is 2^K, GateSize1 is GateSize-1,

    %% Fast-path: check if any occupied state touches gate wires
    foldl([W,Acc,New]>>(New is Acc \/ (1<<W)), GateWires, 0, GMask),
    Size1 is Size-1,
    ( ( between(0, Size1, I), I1 is I+1, arg(I1, IdxArr, Kv), Kv /\ GMask =\= 0 ) ->
        HasActive = true
    ;   HasActive = false
    ),
    ( HasActive = false ->
        GateM = [[c(M00R,_)|_]|_],
        ( abs(M00R - 1.0) < 1.0e-10 ->
            StateOut = fast_sparse(N,IdxArr,_,Size)  %% identity: no-op
        ;
            apply_gate_fsparse_work(Op, GateWires, GateM, GateSize, GateSize1,
                                    NQubits, fast_sparse(N,IdxArr,_,Size), StateOut)
        )
    ;
        apply_gate_fsparse_work(Op, GateWires, GateM, GateSize, GateSize1,
                                NQubits, fast_sparse(N,IdxArr,_,Size), StateOut)
    ).

apply_gate_fsparse_work(_Op, GateWires, GateM, GateSize, GateSize1, NQubits,
                         StateIn, StateOut) :-
    StateIn = fast_sparse(_N, IdxArr, _AmpArr, Size),
    NQubits1 is NQubits-1,
    numlist(0, NQubits1, AllQ),
    subtract(AllQ, GateWires, BgWires),
    length(GateWires, K),
    functor(GateOffsets, go, GateSize),
    ( K > 0 -> K1 is K-1,
        forall(between(0,GateSize1,J),
            (gate_offset_msb(J,K1,0,GateWires,Off), J1 is J+1, nb_setarg(J1,GateOffsets,Off)))
    ; nb_setarg(1,GateOffsets,0) ),
    flatten(GateM, GF), GateArr =.. [mat|GF],
    bg_mask(BgWires, BgMask),
    %% Collect unique bg bases from occupied states
    Size1 is Size-1,
    findall(B, (between(0,Size1,I), I1 is I+1, arg(I1,IdxArr,Kv), B is Kv /\ BgMask), BgRaw),
    sort(BgRaw, UniqueBgBases),
    %% Apply each block -- accumulate changes
    nb_setval(sv_fs_state, StateIn),
    forall(member(BgBase, UniqueBgBases),
        apply_gate_block_fsparse(BgBase, GateOffsets, GateArr, GateSize, GateSize1)),
    nb_getval(sv_fs_state, StateOut).

apply_gate_block_fsparse(BgBase, GateOffsets, GateArr, GateSize, GateSize1) :-
    nb_getval(sv_fs_state, State),
    State = fast_sparse(_, _, _, _),
    %% Read input amplitudes
    functor(InAmps, amp, GateSize),
    forall(between(0,GateSize1,InJ), (
        InJ1 is InJ+1,
        arg(InJ1, GateOffsets, GOff),
        SIdx is BgBase + GOff,
        fsparse_get(State, SIdx, Amp),
        nb_setarg(InJ1, InAmps, Amp)
    )),
    %% Compute and write output amplitudes
    forall(between(0,GateSize1,OutJ), (
        OutJ1 is OutJ+1,
        arg(OutJ1, GateOffsets, OutOff),
        OutSIdx is BgBase + OutOff,
        RowBase is OutJ * GateSize,
        dot_fast(GateSize1, RowBase, GateArr, InAmps, c(0.0,0.0), NewAmp),
        nb_getval(sv_fs_state, SCur),
        fsparse_put(SCur, OutSIdx, NewAmp, SNext),
        nb_setval(sv_fs_state, SNext)
    )).

