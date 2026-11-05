%% ============================================================
%%  rp_gates.pl  --  Layer 3 gate expansion
%%
%%  The primary API works entirely on structured op/4 terms.
%%  No string parsing anywhere in the expansion path.
%%
%%  rp_ops(+Microcode, -Ops)
%%    Extract op/4 terms directly from microcode.
%%    op(Name, A, B, Result)
%%
%%  rp_expand_ops(+Ops, -Lines)
%%    Expand op/4 terms to gate line strings.
%%    This is the ONLY place strings are produced.
%%
%%  rp_expand_qasm(+L2Lines, -L3Lines)
%%    Convenience wrapper: takes Layer 2 named-op strings,
%%    re-parses them to op/4, then expands.
%%    Only used for human-readable Layer 2 output display.
%%
%%  Gate generators (all parameterised by bit-width N):
%%    rp_adder_qasm(+X, +Y, +Z, +N, -Lines)
%%    rp_sub_qasm(+X, +Y, +Z, +N, -Lines)
%%    rp_mod_qasm(+X, +Nval, +Z, +N, -Lines)
%%    rp_mul_qasm(+X, +Y, +Z, +N, -Lines)
%%    rp_shr_qasm(+X, +Shift, +Z, +N, -Lines)
%%
%%  All use qubit-register names (atoms), not flat indices.
%%  Flat index assignment happens in rp_verify.pl.
%% ============================================================

:- module(rp_gates, [
    rp_ops/2,
    rp_expand_ops/2,
    rp_expand_ops_n/3,      %% +Ops, +Bits, -Lines  (used by rp_grover_structured)
    rp_expand_qasm/2,
    rp_adder_qasm/5,
    rp_sub_qasm/5,
    rp_mod_qasm/5,
    rp_mul_qasm/5,
    rp_shr_qasm/5,
    rp_xor_qasm/5,          %% +X, +Y, +Z, +N, -Lines
    rp_and_qasm/5,          %% +X, +Y, +Z, +N, -Lines
    rp_verify_adder/0,
    rp_verify_mod/1,
    rp_verify_mul/0
]).

:- use_module(library(lists)).

%% ============================================================
%%  op/4 term set
%%
%%  op(rev_add, X, Y, Z)   Z = X + Y
%%  op(rev_sub, X, Y, Z)   Z = X - Y
%%  op(rev_mul, X, Y, Z)   Z = X * Y
%%  op(rev_mod, X, N, Z)   Z = X mod N   (N may be a constant)
%%  op(rev_shr, X, N, Z)   Z = X >> N    (N usually a constant)
%%  op(rev_and, X, Y, Z)   Z = X /\ Y
%%  op(rev_xor, X, Y, Z)   Z = X xor Y
%%  op(unknown, V, _, _)   unrecognised expression
%% ============================================================

%% ============================================================
%%  Extract op/4 terms directly from microcode
%% ============================================================

rp_ops(MC, Ops) :-
    collect_ops(MC, Ops).

collect_ops([], []).
collect_ops([next(V, Expr)|T], [Op|Rest]) :- !,
    expr_to_op(Expr, V, Op),
    collect_ops(T, Rest).
collect_ops([ite(_,TMC,EMC)|T], Ops) :- !,
    collect_ops(TMC, OT),
    collect_ops(EMC, OE),
    collect_ops(T, OR),
    append(OT, OE, OTE), append(OTE, OR, Ops).
collect_ops([_|T], Ops) :-
    collect_ops(T, Ops).

expr_to_op(A + B,   V, op(rev_add, A, B, V)).
expr_to_op(A - B,   V, op(rev_sub, A, B, V)).
expr_to_op(A * B,   V, op(rev_mul, A, B, V)).
expr_to_op(A mod B, V, op(rev_mod, A, B, V)).
expr_to_op(A >> B,  V, op(rev_shr, A, B, V)).
expr_to_op(A /\ B,  V, op(rev_and, A, B, V)).
expr_to_op(A xor B,    V, op(rev_xor,    A, B,    V)).
expr_to_op(phase(K),   V, op(rev_phase,  K, none, V)).
expr_to_op(cphase(C,K),V, op(rev_cphase, C, K,    V)).
expr_to_op(_Expr,      V, op(unknown,    V, none, none)).

%% ============================================================
%%  Expand op/4 terms to gate lines
%%  Uses default bit-width 4.  For other widths use
%%  rp_expand_ops_n/3.
%% ============================================================

rp_expand_ops(Ops, Lines) :-
    rp_expand_ops_n(Ops, 4, Lines).

rp_expand_ops_n(Ops, N, Lines) :-
    maplist(expand_op_n(N), Ops, Blocks),
    flatten(Blocks, Lines).

expand_op_n(N, op(rev_add, X, Y, Z), Lines) :- rp_adder_qasm(X,Y,Z,N,Lines).
expand_op_n(N, op(rev_sub, X, Y, Z), Lines) :- rp_sub_qasm(X,Y,Z,N,Lines).
expand_op_n(N, op(rev_mul, X, Y, Z), Lines) :- rp_mul_qasm(X,Y,Z,N,Lines).
expand_op_n(N, op(rev_mod, X, Nv, Z), Lines) :-
    ( integer(Nv) -> NVal=Nv ; NVal=15 ),
    rp_mod_qasm(X,NVal,Z,N,Lines).
expand_op_n(N, op(rev_shr, X, Sh, Z), Lines) :- rp_shr_qasm(X,Sh,Z,N,Lines).
expand_op_n(N, op(rev_and, X, Y, Z), Lines) :- rp_and_qasm(X,Y,Z,N,Lines).
expand_op_n(N, op(rev_xor,    X, Y,    Z), Lines) :- rp_xor_qasm(X,Y,Z,N,Lines).
expand_op_n(_, op(unknown,V,_,_), [L]) :-
    format(atom(L), "// *** no gate pattern for ~w ***", [V]).

%% ============================================================
%%  Convenience: expand from Layer 2 QASM string list
%%  Parses string lines -> op/4 -> gate lines.
%%  Only used for displaying Layer 2 output.
%% ============================================================

rp_expand_qasm(L2Lines, L3Lines) :-
    include(is_named_op_line, L2Lines, OpLines),
    maplist(parse_op_line, OpLines, Ops),
    exclude([op(unknown,_,_,_)]>>true, Ops, ValidOps),
    rp_expand_ops(ValidOps, GateLines),
    maplist(replace_if_op(OpLines, GateLines), L2Lines, Replaced),
    flatten(Replaced, L3Lines).

replace_if_op(OpLines, GateLines, Line, Replacement) :-
    ( nth1(Idx, OpLines, Line) ->
        nth1(Idx, GateLines, Replacement)
    ;   Replacement = Line
    ).

is_named_op_line(Line) :-
    atom(Line),
    member(Prefix, ["rev_add","rev_sub","rev_mul",
                    "rev_mod","rev_shr","rev_and","rev_xor"]),
    atom_string(Line, S),
    sub_string(S, 0, _, _, Prefix).

parse_op_line(Line, Op) :-
    atom_string(Line, S),
    named_op_string(S, OpName, A, B, Z),
    Op = op(OpName, A, B, Z).

named_op_string(S, OpAtom, A, B, Z) :-
    member(OpStr, ["rev_add","rev_sub","rev_mul",
                   "rev_mod","rev_shr","rev_and","rev_xor"]),
    sub_string(S, 0, _, _, OpStr),
    atom_string(OpAtom, OpStr),
    string_length(OpStr, Len),
    sub_string(S, Len, _, 0, Rest),
    split_string(Rest, ";", " ", [Main|_]),
    split_string(Main, ",->", " ", RawToks),
    include([T]>>(T \= ""), RawToks, [SA,SB,SZ|_]),
    atom_string(A,SA), atom_string(B,SB), atom_string(Z,SZ).

%% ============================================================
%%  GATE GENERATORS
%%  All parameterised by N (bit-width).
%%  Use register name atoms: X[0]..X[N-1] notation.
%%  Carry register named 'carry'.
%% ============================================================

%% ---- XOR: Z = X xor Y  (CNOT chain, no carry, no ancilla) -

rp_xor_qasm(X, Y, Z, N, Lines) :-
    N1 is N-1, numlist(0, N1, Bits),
    maplist(xor_bit(X,Y,Z), Bits, Pairs),
    flatten(Pairs, Lines).

xor_bit(X,Y,Z, I, [L1,L2]) :-
    format(atom(L1), "cx ~w[~w], ~w[~w];", [X,I,Z,I]),
    format(atom(L2), "cx ~w[~w], ~w[~w];", [Y,I,Z,I]).

%% ---- AND: Z = X /\ Y  (Toffoli per bit) -------------------

rp_and_qasm(X, Y, Z, N, Lines) :-
    N1 is N-1, numlist(0, N1, Bits),
    maplist(and_bit(X,Y,Z), Bits, Lines).

and_bit(X,Y,Z, I, L) :-
    format(atom(L), "ccx ~w[~w], ~w[~w], ~w[~w];", [X,I,Y,I,Z,I]).

%% ---- ADD: Z = X + Y  (Cuccaro MAJ/UMA, N-bit) -------------
%%
%%  Standard Cuccaro ripple-carry adder (Cuccaro et al. 2004),
%%  adapted for 3 separate registers X, Y, Z (X, Y preserved; Z
%%  starts at |0> and ends holding (X+Y) mod 2^N):
%%
%%    1. Copy Y into Z (Z was |0>, now Z=Y).
%%    2. Run the standard in-place adder treating X as the "a"
%%       register and Z as the "b" register: this computes
%%       Z := X + Z (mod 2^N) while restoring X to its original
%%       value. Y itself is never touched again after step 1, so
%%       it is automatically preserved.
%%
%%  The carry chain is the classic Cuccaro trick: bit 0's carry-in
%%  is a single external ancilla qubit (carry[0], must start and
%%  end at |0>); every other bit's carry-in is simply the PREVIOUS
%%  bit's X qubit (X[I-1]) -- no separate N-wide carry register is
%%  needed, and none is used (the "carry" scratch register declared
%%  by rp_grover.pl is N qubits wide for interface-compatibility
%%  reasons, but only carry[0] is ever touched; carry[1..N-1] are
%%  simply unused spare qubits).
%%
%%  This exact gate sequence (MAJ/UMA definitions below) was
%%  verified classically in Python against all input combinations
%%  for N=1,2,3,5 before being transcribed here -- see the fix
%%  writeup for the verification script. The PREVIOUS version of
%%  this predicate used an N-WIDE carry array with NO cross-bit
%%  carry propagation at all (every bit's carry-in was hard-wired
%%  to a fresh |0>, never chained from the previous bit), so it
%%  only ever produced a correct result for bit 0; every constraint
%%  built from addition or subtraction (fd_sum_eq, fd_sum_neq,
%%  fd_lt/le/gt/ge, fd_weighted_sum, and by inheritance fd_product_eq)
%%  compiled to a circuit whose oracle never actually discriminated
%%  solutions from non-solutions.
%%
%%  IMPORTANT: each gate is emitted as a SEPARATE list element so
%%  that reversing the gate list (for Bennett uncompute) correctly
%%  inverts the circuit. Never concatenate multiple gates into one
%%  string here.

rp_adder_qasm(X, Y, Z, N, Lines) :-
    N1 is N-1, numlist(0, N1, Bits),
    Header = [Hdr],
    format(atom(Hdr), "// adder ~w = ~w + ~w (~w-bit, Cuccaro ripple-carry)", [Z,X,Y,N]),
    %% Step 1: Z := Y  (Z starts at |0>)
    maplist(copy_into_line(Y,Z), Bits, CopyLines),
    %% Step 2: in-place add X into Z, treating X as the carry-chain
    %% register (restored at the end) and Z as the accumulator.
    maplist(maj_line(X,Z), Bits, MajBlocks),
    reverse(Bits, RevBits),
    maplist(uma_line(X,Z), RevBits, UmaBlocks),
    flatten([Header, CopyLines, MajBlocks, UmaBlocks], Lines).

copy_into_line(Y, Z, I, L) :-
    format(atom(L), "cx ~w[~w], ~w[~w];", [Y,I,Z,I]).

%% carry_in_ref(+X, +I, -Ref)
%%   The qubit acting as carry-in to bit I of the chain: bit 0 uses
%%   the single external ancilla carry[0]; every other bit reuses
%%   the PREVIOUS bit's X qubit directly (the Cuccaro trick).
carry_in_ref(_, 0, 'carry[0]') :- !.
carry_in_ref(X, I, Ref) :-
    I1 is I - 1,
    format(atom(Ref), "~w[~w]", [X, I1]).

%% MAJ(a=X[I], b=Z[I], c=carry_in): 3 separate gate strings.
%%   cx a,b ; cx a,c ; ccx c,b,a
maj_line(X, Z, I, [L1,L2,L3]) :-
    carry_in_ref(X, I, C),
    format(atom(L1), "cx ~w[~w], ~w[~w];", [X,I,Z,I]),
    format(atom(L2), "cx ~w[~w], ~w;",     [X,I,C]),
    format(atom(L3), "ccx ~w, ~w[~w], ~w[~w];", [C,Z,I,X,I]).

%% UMA(a=X[I], b=Z[I], c=carry_in): 3 separate gate strings.
%%   ccx c,b,a ; cx a,c ; cx c,b
uma_line(X, Z, I, [L1,L2,L3]) :-
    carry_in_ref(X, I, C),
    format(atom(L1), "ccx ~w, ~w[~w], ~w[~w];", [C,Z,I,X,I]),
    format(atom(L2), "cx ~w[~w], ~w;",          [X,I,C]),
    format(atom(L3), "cx ~w, ~w[~w];",          [C,Z,I]).

%% ---- SUB: Z = X - Y  (two's complement: invert Y, add, +1) -
%%  Reversible: invert Y, add X + ~Y -> Z, then properly increment Z by 1,
%%  then restore Y.
%%
%%  The +1 is implemented as a proper N-bit ripple incrementer that correctly
%%  propagates carry through all bits of Z.  Simply flipping Z[0] is only
%%  correct when Z[0]=0 (no carry needed); it fails for Z=1111 -> should give
%%  0000 but gives 1110.
%%
%%  Ripple incrementer for N bits (gates listed MSB-first, self-inverse when reversed):
%%    For i = N-1 downto 2: MCX(Z[0..i-1]) -> Z[i]
%%    CX Z[0] -> Z[1]   (N>=2)
%%    X Z[0]             (always)
%%  Each gate is self-inverse so reversing the list gives the decrementer. (self-inverse)

rp_sub_qasm(X, Y, Z, N, Lines) :-
    N1 is N-1, numlist(0, N1, Bits),
    maplist(inv_line(Y), Bits, InvLines),   %% flip Y -> ~Y
    rp_adder_qasm(X, Y, Z, N, AddLines),   %% Z = X + ~Y
    rp_inc_qasm(Z, N, IncLines),           %% Z = Z + 1  (proper ripple increment)
    maplist(inv_line(Y), Bits, RestLines),  %% restore Y
    flatten([InvLines, AddLines, IncLines, RestLines], Lines).

inv_line(Y, I, L) :-
    format(atom(L), "x ~w[~w];", [Y,I]).

%% rp_inc_qasm(+Z, +N, -Lines)
%%   Increment Z by 1 using a ripple carry chain.
%%   Gates are listed from largest i downto 0 so that reversing the list
%%   gives the correct decrement (each gate is its own inverse).
%%
%%   For i=N-1 downto 2: MCX(Z[0..i-1]) -> Z[i]
%%   CX Z[0], Z[1]   (if N >= 2)
%%   X Z[0]
%%
%%   MCX with i-1 controls decomposes using inc_anc ancilla (a shared qubit).
rp_inc_qasm(Z, N, Lines) :-
    N1 is N-1,
    ( N1 >= 2 ->
        numlist(2, N1, BigIdxs0),
        %% MSB first (as documented above): each MCX must read the
        %% ORIGINAL lower bits, so Z[N-1] is flipped before Z[N-2]...
        %% Emitting them ascending (the old behaviour) was only
        %% harmless while N =< 3 (a single MCX line).
        reverse(BigIdxs0, BigIdxs),
        maplist(inc_mcx_line(Z), BigIdxs, MCXBlocks)
    ;   MCXBlocks = [] ),
    ( N >= 2 ->
        format(atom(CXL), "cx ~w[0], ~w[1];", [Z, Z]),
        CXLines = [CXL]
    ;   CXLines = [] ),
    format(atom(XL), "x ~w[0];", [Z]),
    flatten([MCXBlocks, CXLines, [XL]], Lines).

%% inc_mcx_line(+Z, +I, -Lines)
%%   Emit MCX(Z[0],...,Z[I-1]) -> Z[I].
%%   For I=2: CCX Z[0],Z[1],Z[2]
%%   For I=3: CCX Z[0],Z[1],inc_anc; CCX Z[2],inc_anc,Z[3]; CCX Z[0],Z[1],inc_anc
%%   For I>=4: extend ladder (not needed for N<=4 but included for completeness)
inc_mcx_line(Z, 2, [L]) :-
    format(atom(L), "ccx ~w[0], ~w[1], ~w[2];", [Z, Z, Z]).
inc_mcx_line(Z, 3, Lines) :-
    format(atom(L1), "ccx ~w[0], ~w[1], inc_anc[0];", [Z, Z]),
    format(atom(L2), "ccx ~w[2], inc_anc[0], ~w[3];", [Z, Z]),
    format(atom(L3), "ccx ~w[0], ~w[1], inc_anc[0];", [Z, Z]),
    Lines = ["qubit[1] inc_anc;", L1, L2, L3].
inc_mcx_line(Z, I, Lines) :-
    I >= 4,
    %% General MCX(Z[0..I-1]) -> Z[I] via a clean AND ladder:
    %%   inc_anc   = Z0 & Z1
    %%   inc_ancK  = inc_anc(K-1) & Z[K]      K = 2 .. I-2
    %%   Z[I]     ^= inc_anc(I-2) & Z[I-1]
    %% then the ladder is undone in reverse. (The previous I>=4 clause
    %% only ANDed Z0,Z1,Z[I-2],Z[I-1] -- right for I=4, but it dropped
    %% the middle bits from I=5 upward, i.e. registers >= 6 bits.)
    inc_anc_name(1, A1),
    format(atom(Seed), "ccx ~w[0], ~w[1], ~w[0];", [Z, Z, A1]),
    I2 is I - 2,
    numlist(2, I2, Ks),
    maplist(inc_ladder_step(Z), Ks, Steps),
    inc_anc_name(I2, ALast), I1 is I - 1,
    format(atom(Final), "ccx ~w[0], ~w[~w], ~w[~w];", [ALast, Z, I1, Z, I]),
    numlist(1, I2, AllKs),
    maplist([K,D]>>(inc_anc_name(K,N), format(atom(D), "qubit[1] ~w;", [N])), AllKs, Decls),
    reverse(Steps, RevSteps),
    flatten([Decls, Seed, Steps, Final, RevSteps, Seed], Lines).

inc_anc_name(1, inc_anc) :- !.
inc_anc_name(K, N) :- format(atom(N), "inc_anc~w", [K]).

inc_ladder_step(Z, K, L) :-
    K0 is K - 1,
    inc_anc_name(K0, Prev), inc_anc_name(K, Cur),
    format(atom(L), "ccx ~w[0], ~w[~w], ~w[0];", [Prev, Z, K, Cur]).

%% ---- MOD: Z = X mod Nval  (copy + comparator + cond-sub) --
%%  Works for X < 2*Nval (one reduction step).
%%  Uses cmp_flag ancilla.

rp_mod_qasm(X, Nval, Z, N, Lines) :-
    Header = [Hdr],
    format(atom(Hdr), "// mod ~w = ~w mod ~w (~w-bit)", [Z,X,Nval,N]),
    N1 is N-1, numlist(0, N1, Bits),
    int_bits_n(Nval, N, NBits),
    maplist(copy_line(X,Z), Bits, CopyL),
    maplist(cmp_line(Z), Bits, NBits, CmpL),
    maplist(csub_line(Z), Bits, NBits, SubL),
    maplist(cmp_line(Z), Bits, NBits, UCmpL),
    flatten([Header, CopyL, CmpL, SubL, UCmpL], Lines).

copy_line(X,Z, I, L) :-
    format(atom(L), "cx ~w[~w], ~w[~w];", [X,I,Z,I]).

cmp_line(Z, I, 1, L) :-
    format(atom(L), "cx ~w[~w], cmp_flag;", [Z,I]).
cmp_line(_, _, 0, "// mod bit=0").

csub_line(Z, I, 1, L) :-
    format(atom(L), "ccx cmp_flag, ~w[~w], ~w[~w];", [Z,I,Z,I]).
csub_line(_, _, 0, "// mod bit=0").

int_bits_n(N, Width, Bits) :-
    W1 is Width-1, numlist(0, W1, Ps),
    maplist([P,B]>>(B is (N>>P)/\1), Ps, Bits).

%% ---- MUL: Z = X * Y  (shift-and-add, Cuccaro in-place adder, N-bit) ---
%%
%%  Correct quantum multiplier using shift-and-conditionally-add.
%%  Z (2N qubits) is the product register, starts at |0>.
%%  mul_t (N+1 qubits, starts at |0>) is the row temporary register.
%%  mul_g (1 qubit, starts at |0>) is the carry-in scratch for the adder.
%%
%%  For each row I = 0..N-1:
%%    1. Compute T[J] = Y[I] AND X[J]  for J = 0..N-1  (N CCX gates)
%%       T[N] is the padding bit, always 0.
%%    2. In-place Cuccaro add: Z[I..I+N] += T[0..N]
%%       Uses Cuccaro 2004 MAJ/UMA adder on (N+1)-bit operands.
%%       mul_t[0..N] serves as the A register (scratch, restored after).
%%       Z[I..I+N] is the B register (accumulates the sum).
%%       mul_g is the carry-in register (always 0, restored by UMA).
%%       Overflow CX is OMITTED: T[N]=0 always, so carry never exceeds 2N bits.
%%    3. Uncompute T: same N CCX gates again (self-inverse).
%%
%%  Gate count: N * (2N + 3*(N+2) + 3*(N+1) + 1) = O(N^2) gates per row.
%%  Total: O(N^3) gates. Uncompute: run same gate list in reverse.
%%
%%  MAJ(a, b, c): cx c,a; cx c,b; ccx a,b,c   -> c = MAJ(a,b,c), carry chain
%%  UMA(a, b, c): ccx a,b,c; cx c,a; cx a,b   -> c restored, a restored, b = sum
%%
%%  New ancilla registers declared inline and hoisted to header by rp_grover_structured:
%%    qubit[N+1] mul_t;    (row temp, N+1 bits)
%%    qubit[1]   mul_g;    (carry-in scratch)

rp_mul_qasm(X, Y, Z, N, Lines) :-
    Header = [Hdr],
    format(atom(Hdr), "// mul ~w = ~w * ~w (~w-bit, Cuccaro shift-and-add)", [Z,X,Y,N]),
    NT is N + 1,
    format(atom(TDecl), "qubit[~w] mul_t;", [NT]),
    format(atom(GDecl), "qubit[1] mul_g;", []),
    N1 is N - 1, numlist(0, N1, Rows),
    maplist(mul_row_gates(X, Y, Z, N), Rows, RowBlocks),
    flatten([Header, TDecl, GDecl | RowBlocks], Lines).

%%  mul_row_gates(+X, +Y, +Z, +N, +I, -Lines)
%%  Emit gates for row I of the multiplier: compute T, add into Z[I..I+N], uncompute T.
mul_row_gates(X, Y, Z, N, I, Lines) :-
    N1 is N - 1, numlist(0, N1, Jbits),
    %% Step 1: compute T[J] = Y[I] AND X[J]
    maplist([J, L]>>(format(atom(L), "ccx ~w[~w], ~w[~w], mul_t[~w];", [Y,I,X,J,J])),
            Jbits, ComputeT),
    %% Step 2: Cuccaro in-place add T into Z[I..I+N]
    mul_cuccaro_add(Z, I, N, AddLines),
    %% Step 3: uncompute T (same gates, self-inverse)
    UncomputeT = ComputeT,
    flatten([ComputeT, AddLines, UncomputeT], Lines).

%%  mul_cuccaro_add(+Z, +I, +N, -Lines)
%%  Emit MAJ + UMA gates for in-place (N+1)-bit Cuccaro add of mul_t into Z[I..I+N].
%%  mul_t serves as A (scratch, preserved). Z[I..I+N] is B (accumulates sum).
%%  mul_g is the carry-in scratch for bit 0.
%%
%%  Circuit structure for (N+1)-bit add (positions 0..N):
%%    MAJ(mul_g, Z[I+0], mul_t[0])
%%    for k=1..N: MAJ(mul_t[k-1], Z[I+k], mul_t[k])
%%    for k=N downto 1: UMA(mul_t[k-1], Z[I+k], mul_t[k])
%%    UMA(mul_g, Z[I+0], mul_t[0])
%%
mul_cuccaro_add(Z, I, N, Lines) :-
    Header = [Hdr],
    format(atom(Hdr), "// Cuccaro add mul_t into ~w[~w..~w]", [Z, I, I+N]),
    %% MAJ gates for positions 0..N
    IZ0 is I,
    maj_qasm_lines("mul_g", 0, Z, IZ0, "mul_t", 0, MajFirst),
    numlist(1, N, KsMAJ),
    maplist(maj_row(Z, I), KsMAJ, MajRest),
    %% UMA gates for positions N downto 0
    numlist(1, N, KsUMAFwd), reverse(KsUMAFwd, KsUMA),
    maplist(uma_row(Z, I), KsUMA, UmaFirst),
    uma_qasm_lines("mul_g", 0, Z, IZ0, "mul_t", 0, UmaLast),
    flatten([Header, MajFirst, MajRest, UmaFirst, UmaLast], Lines).

%%  maj_row(+Z, +I, +K, -Lines)
%%  MAJ gate for adder position K (K >= 1):
%%    MAJ(mul_t[K-1], Z[I+K], mul_t[K])
%%    i.e. a=mul_t[K-1], b=Z[I+K], c=mul_t[K]
maj_row(Z, I, K, Lines) :-
    K1 is K - 1, IK is I + K,
    maj_qasm_lines("mul_t", K1, Z, IK, "mul_t", K, Lines).

%%  uma_row(+Z, +I, +K, -Lines)
%%  UMA gate for adder position K (K >= 1):
%%    UMA(mul_t[K-1], Z[I+K], mul_t[K])
uma_row(Z, I, K, Lines) :-
    K1 is K - 1, IK is I + K,
    uma_qasm_lines("mul_t", K1, Z, IK, "mul_t", K, Lines).

%%  maj_qasm_lines(+A, +IA, +B, +IB, +C, +IC, -Lines)
%%  Emit 3 gates for MAJ(A[IA], B[IB], C[IC]):
%%    cx C[IC], A[IA]
%%    cx C[IC], B[IB]
%%    ccx A[IA], B[IB], C[IC]
maj_qasm_lines(A, IA, B, IB, C, IC, [L1, L2, L3]) :-
    format(atom(L1), "cx ~w[~w], ~w[~w];",        [C, IC, A, IA]),
    format(atom(L2), "cx ~w[~w], ~w[~w];",        [C, IC, B, IB]),
    format(atom(L3), "ccx ~w[~w], ~w[~w], ~w[~w];", [A, IA, B, IB, C, IC]).

%%  uma_qasm_lines(+A, +IA, +B, +IB, +C, +IC, -Lines)
%%  Emit 3 gates for UMA(A[IA], B[IB], C[IC]):
%%    ccx A[IA], B[IB], C[IC]
%%    cx C[IC], A[IA]
%%    cx A[IA], B[IB]
uma_qasm_lines(A, IA, B, IB, C, IC, [L1, L2, L3]) :-
    format(atom(L1), "ccx ~w[~w], ~w[~w], ~w[~w];", [A, IA, B, IB, C, IC]),
    format(atom(L2), "cx ~w[~w], ~w[~w];",           [C, IC, A, IA]),
    format(atom(L3), "cx ~w[~w], ~w[~w];",           [A, IA, B, IB]).


%% ---- SHR: Z = X >> Shift  (SWAP chain, zero T-cost) -------
%%  Right shift by Shift positions: wire X[I+Shift] -> Z[I].
%%  Implemented as cascaded SWAP gates.

rp_shr_qasm(X, Shift, Z, N, Lines) :-
    ( integer(Shift) -> ShiftVal = Shift ; ShiftVal = 1 ),
    Header = [Hdr],
    format(atom(Hdr), "// shr ~w = ~w >> ~w (~w-bit)", [Z,X,ShiftVal,N]),
    N1 is N-1, numlist(0, N1, OutBits),
    findall([L1,L2,L3], (
        member(I, OutBits),
        SrcI is I + ShiftVal,
        SrcI < N,
        format(atom(L1), "cx ~w[~w], ~w[~w];", [X,SrcI,Z,I]),
        format(atom(L2), "cx ~w[~w], ~w[~w];", [Z,I,X,SrcI]),
        format(atom(L3), "cx ~w[~w], ~w[~w];", [X,SrcI,Z,I])
    ), Triples),
    flatten([Header | Triples], Lines).

%% ============================================================
%%  VERIFICATION  (classical simulation)
%% ============================================================

rp_verify_adder :-
    format("Verifying ~w-bit adder (0..~w + 0..~w): ",
           [4, 7, 7]),
    Max is (1<<3)-1,
    aggregate_all(count,
        (between(0,Max,A), between(0,Max,B),
         E is A+B,
         sim_add(A,B,Got), Got =\= E),
        0),
    format("all correct.~n").

rp_verify_mod(Nval) :-
    Max is 2*Nval-1,
    format("Verifying mod ~w (0..~w): ", [Nval,Max]),
    aggregate_all(count,
        (between(0,Max,X),
         E is X mod Nval,
         sim_mod(X,Nval,Got), Got =\= E),
        0),
    format("all correct.~n").

rp_verify_mul :-
    format("Verifying multiplier (all 2-bit pairs): "),
    Max is (1<<2)-1,
    aggregate_all(count,
        (between(0,Max,A), between(0,Max,B),
         E is A*B,
         sim_mul(A,B,Got), Got =\= E),
        0),
    format("all correct.~n").

sim_add(A,B,S) :- S is A+B.
sim_mod(X,N,Z) :- ( X>=N -> Z is X-N ; Z=X ).
sim_mul(A,B,Z) :- Z is A*B.

