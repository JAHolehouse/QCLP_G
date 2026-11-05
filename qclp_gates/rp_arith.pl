%% ============================================================
%%  rp_arith -- RProlog standard arithmetic library
%%
%%  All predicates are:
%%    - Valid standard Prolog (run unchanged in SWI-Prolog)
%%    - In the reversible subset (no cut, no side effects)
%%    - Ground arithmetic only (inputs must be instantiated)
%%
%%  These are the predicates a developer writes in their
%%  RProlog programs. The compiler recognises them and
%%  generates appropriate microcode and QASM.
%% ============================================================

:- module(rp_arith, [
    %% Level 1 -- bitwise
    rp_xor/3,       % rp_xor(X, Y, Z)      Z = X xor Y
    rp_and/3,       % rp_and(X, Y, Z)      Z = X /\ Y
    rp_or/3,        % rp_or(X, Y, Z)       Z = X \/ Y
    rp_not/2,       % rp_not(X, Z)         Z = 1-X  (single bit)
    rp_bit/3,       % rp_bit(X, I, B)      B = bit I of X
    rp_mux/4,       % rp_mux(Bit, A, B, Z) Z = A if Bit=0 else B
    %% Level 2 -- integer arithmetic
    rp_add/3,       % rp_add(A, B, Z)      Z = A + B
    rp_sub/3,       % rp_sub(A, B, Z)      Z = A - B
    rp_mul/3,       % rp_mul(A, B, Z)      Z = A * B
    rp_div/3,       % rp_div(A, B, Q)      Q = A // B
    rp_mod/3,       % rp_mod(A, B, R)      R = A mod B
    rp_divmod/4,    % rp_divmod(A,B,Q,R)   Q,R = A divmod B
    rp_shr/3,       % rp_shr(A, N, Z)      Z = A >> N
    rp_shl/3,       % rp_shl(A, N, Z)      Z = A << N
    %% Level 3 -- modular arithmetic (Shor kernel)
    rp_mod_add/4,   % rp_mod_add(A,B,M,Z)  Z = (A+B) mod M
    rp_mod_sub/4,   % rp_mod_sub(A,B,M,Z)  Z = (A-B) mod M
    rp_mod_mul/4,   % rp_mod_mul(A,B,M,Z)  Z = (A*B) mod M
    rp_mod_exp/4,   % rp_mod_exp(B,E,M,Z)  Z = B^E mod M (4-bit E)
    %% Level 4 -- number theory (classical, used in Shor wrapper)
    rp_gcd/3,       % rp_gcd(A, B, G)      G = gcd(A,B)
    rp_is_even/1,   % rp_is_even(N)        N mod 2 = 0
    rp_is_odd/1     % rp_is_odd(N)         N mod 2 = 1
]).

%% ---- Level 1 -----------------------------------------------

rp_xor(X, Y, Z) :- Z is X xor Y.
rp_and(X, Y, Z) :- Z is X /\ Y.
rp_or(X, Y, Z)  :- Z is X \/ Y.
rp_not(X, Z)    :- Z is 1 - X.
rp_bit(X, I, B) :- S is X >> I, B is S /\ 1.
rp_mux(0, A, _, A).
rp_mux(1, _, B, B).

%% ---- Level 2 -----------------------------------------------

rp_add(A, B, Z)    :- Z is A + B.
rp_sub(A, B, Z)    :- Z is A - B.
rp_mul(A, B, Z)    :- Z is A * B.
rp_div(A, B, Q)    :- Q is A // B.
rp_mod(A, B, R)    :- R is A mod B.
rp_divmod(A, B, Q, R) :- Q is A // B, R is A mod B.
rp_shr(A, N, Z)    :- Z is A >> N.
rp_shl(A, N, Z)    :- Z is A << N.

%% ---- Level 3 -----------------------------------------------

rp_mod_add(A, B, M, Z) :-
    S is A + B, Z is S mod M.

rp_mod_sub(A, B, M, Z) :-
    S is A - B + M, Z is S mod M.

rp_mod_mul(A, B, M, Z) :-
    P is A * B, Z is P mod M.

%% Modular exponentiation -- iterative binary method
%% 4-bit exponent (handles E = 0..15)
rp_mod_exp(Base, Exp, M, Result) :-
    rp_mod_exp_loop(Base, Exp, M, 1, 4, Result).

rp_mod_exp_loop(_B, _E, _M, Acc, 0, Acc).
rp_mod_exp_loop(Base, Exp, M, AccIn, I, Result) :-
    I > 0,
    I1      is I - 1,
    Shifted is Exp >> I1,
    Bit     is Shifted /\ 1,
    Sq      is AccIn * AccIn,
    SqMod   is Sq mod M,
    Mx      is SqMod * Base,
    MxMod   is Mx mod M,
    ( Bit =:= 0 -> AccOut = SqMod ; AccOut = MxMod ),
    rp_mod_exp_loop(Base, Exp, M, AccOut, I1, Result).

%% ---- Level 4 -----------------------------------------------

rp_gcd(A, 0, A) :- A > 0.
rp_gcd(A, B, G) :-
    B > 0, R is A mod B, rp_gcd(B, R, G).

rp_is_even(N) :- 0 is N mod 2.
rp_is_odd(N)  :- 1 is N mod 2.
