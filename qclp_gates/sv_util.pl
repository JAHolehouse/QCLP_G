/* ============================================================
   sv_util.pl  --  Shared wire utilities and circuit helpers.

   Used by both qoracle_circuit.pl (synthesis) and
   qoracle_sim.pl (simulation).  No quantum logic here --
   only naming conventions, bit arithmetic, and IR traversal.

   Wire naming convention:
     g0..g{N-1}   input register    (g0 = LSB)
     o0..o{M-1}   output register   (function oracles)
     anc          phase oracle ancilla
     car1,car2..  carry ancillae    (CDKM adder)
     tmp1,tmp2..  temporary wires   (constant adder)
     a0..a{K-1}   QPE ancilla       (HHL)
     flag         HHL flag qubit

   Circuit IR terms:
     empty
     gate(Op, [Wire])
     ctrl(Controls, Body)
     seq(A, B)
     init(Wire, Val)
     discard(Wire)
   ============================================================ */

:- module(sv_util, [
    %%  Wire name constructors
    input_wires/2,          %% input_wires(+N, -Wires)
    output_wires/2,         %% output_wires(+N, -Wires)

    %%  Wire map: name -> qubit index
    collect_wires/2,        %% collect_wires(+Circuit, -Wires)
    build_wire_map/4,       %% build_wire_map(+Sorted,+NIn,-Map,-TotalQ)
    wire_idx/3,             %% wire_idx(+Name, +Map, -Idx)

    %%  Bit arithmetic
    int_to_bits/3,          %% int_to_bits(+K, +N, -Bits)  LSB first
    nbits_for_max/2,        %% nbits_for_max(+MaxVal, -Bits)
    nbits_for_domain/2,     %% nbits_for_domain(+Domain, -Bits)

    %%  Circuit utilities
    qoc_seq/2,              %% qoc_seq(+List, -Circuit)
    qoc_gate_count/2,       %% qoc_gate_count(+Circuit, -N)
    input_to_wires/3        %% input_to_wires(+Input,+N,-WireBitPairs)
]).

:- use_module(library(lists)).
:- use_module(library(apply)).


/* ============================================================
   Wire name constructors
   ============================================================ */

input_wires(N, Ws) :-
    N1 is N-1, numlist(0, N1, Is),
    maplist(mk_gwire, Is, Ws).

output_wires(N, Ws) :-
    N1 is N-1, numlist(0, N1, Is),
    maplist(mk_owire, Is, Ws).

mk_gwire(I, W) :- atom_concat(g, I, W).
mk_owire(I, W) :- atom_concat(o, I, W).


/* ============================================================
   Wire collection from circuit IR
   ============================================================ */

collect_wires(empty,           []).
collect_wires(gate(_, Ws),     Ws).
collect_wires(ctrl(Cs, Body),  All) :-
    collect_wires(Body, BW), append(Cs, BW, All).
collect_wires(seq(A, B),       All) :-
    collect_wires(A, WA), collect_wires(B, WB), append(WA, WB, All).
collect_wires(init(W, _),      [W]).
collect_wires(discard(W),      [W]).


/* ============================================================
   Wire map

   Maps wire names to contiguous qubit indices:
     g0..g{N-1}   -> 0 .. N-1          input register
     o0..o{M-1}   -> N .. N+M-1        output register
     everything else -> N+M, N+M+1,..  ancilla
   ============================================================ */

build_wire_map(SortedWires, NQIn, WireMap, TotalQ) :-
    partition(is_input_wire,  SortedWires, IWires, Rest),
    partition(is_output_wire, Rest,        OWires, AncWires),
    maplist(input_wire_pair,  IWires, IMap),
    length(OWires, NOuts),
    maplist(output_wire_pair(NQIn), OWires, OMap),
    AncStart is NQIn + NOuts,
    length(AncWires, NAncilla),
    anc_map(AncWires, AncStart, AncMap),
    append(IMap, OMap, M1), append(M1, AncMap, WireMap),
    TotalQ is NQIn + NOuts + NAncilla.

is_input_wire(W)  :- atom_concat(g, R, W), atom_number(R, _).
is_output_wire(W) :- atom_concat(o, R, W), atom_number(R, _).

input_wire_pair(W, W-I) :-
    atom_concat(g, R, W), atom_number(R, I).

output_wire_pair(Base, W, W-I) :-
    atom_concat(o, R, W), atom_number(R, Pos), I is Base + Pos.

anc_map([], _, []).
anc_map([W|Ws], I, [W-I|Rest]) :-
    I1 is I+1, anc_map(Ws, I1, Rest).

wire_idx(Wire, WireMap, Idx) :-
    ( member(Wire-Idx, WireMap) -> true
    ; format("[qoracle] WARNING: wire ~w unmapped, using 0~n", [Wire]),
      Idx = 0
    ).


/* ============================================================
   Bit arithmetic
   ============================================================ */

int_to_bits(K, N, Bits) :-
    N1 is N-1, numlist(0, N1, Ps),
    maplist(extract_bit(K), Ps, Bits).

extract_bit(K, P, B) :- B is (K >> P) /\ 1.

nbits_for_max(0, 1) :- !.
nbits_for_max(M, N) :-
    N is max(1, ceiling(log(float(M)+1.0)/log(2.0))).

nbits_for_domain(Domain, N) :-
    length(Domain, Len),
    ( Len =< 1 -> N = 1
    ; N is max(1, ceiling(log(float(Len))/log(2.0)))
    ).


/* ============================================================
   Circuit utilities
   ============================================================ */

qoc_seq([], empty)   :- !.
qoc_seq([C], C)      :- !.
qoc_seq([C|Cs], seq(C, Rest)) :- qoc_seq(Cs, Rest).

qoc_gate_count(empty,        0).
qoc_gate_count(gate(_,_),    1).
qoc_gate_count(ctrl(_,B),    N) :- qoc_gate_count(B,NB), N is NB+1.
qoc_gate_count(seq(A,B),     N) :- qoc_gate_count(A,NA), qoc_gate_count(B,NB), N is NA+NB.
qoc_gate_count(init(_,_),    0).
qoc_gate_count(discard(_),   0).

%%  input_to_wires(+Input, +Nbits, -WireBitPairs)
%%  e.g. input_to_wires(5, 3, [g0-1, g1-0, g2-1])
input_to_wires(Input, Nbits, WAs) :-
    Nbits1 is Nbits-1, numlist(0, Nbits1, Is),
    maplist(input_bit_pair(Input), Is, WAs).

input_bit_pair(Input, I, W-B) :-
    atom_concat(g, I, W),
    B is (Input >> I) /\ 1.
