%% ============================================================
%%  rp_ite.pl  --  ite -> Fredkin (CSWAP) translation
%%
%%  Translates the specific pattern that arises from if-then-else
%%  in reversible predicates:
%%
%%    ite([guard(Ctrl =:= 0)], [unify(Out, ThenVal)], [unify(Out, ElseVal)])
%%
%%  Into the Fredkin (controlled-SWAP) construction:
%%
%%    Copy ThenVal -> Out         (CNOT per bit)
%%    CSWAP(Ctrl, Out_i, ElseVal_i)  per bit
%%
%%  When Ctrl=0: Out = ThenVal  (no swap)
%%  When Ctrl=1: Out = ElseVal  (swap)
%%
%%  The construction is self-inverse (CSWAP and CNOT are both
%%  self-inverse), so uncompute is identical to compute.
%%
%%  Public API:
%%    collect_events(+MC, -Events)
%%      Extract ops and ite events from microcode in order.
%%      Events = list of op/4 | ite_mux/4 terms.
%%
%%    ite_to_lines(+ite_mux(Ctrl,Out,Then,Else), +WM, +Bits, -Lines)
%%      Generate gate lines for one ite_mux event.
%% ============================================================

:- module(rp_ite, [
    collect_events/2,
    ite_to_lines/4,
    recognise_ite/7
]).

:- use_module(rp_gates, [rp_ops/2]).

%% ============================================================
%%  collect_events/2
%%  Walk microcode, extracting op/4 and ite_mux/4 events in order.
%%  Applies constant folding to shift/and amounts.
%% ============================================================

collect_events(MC, Events) :-
    rp_fold_const_map(MC, ConstMap),
    collect_ev(MC, ConstMap, Events).

collect_ev([], _, []).
collect_ev([next(V, Expr)|T], CM, [op(Name,A2,B2,V)|Rest]) :- !,
    expr_to_op(Expr, V, op(Name,A,B,V)),
    fold_arg(CM, A, A2),
    fold_arg(CM, B, B2),
    collect_ev(T, CM, Rest).
collect_ev([ite(CondMC, ThenMC, ElseMC)|T], CM, Events) :- !,
    ( recognise_ite(CondMC, ThenMC, ElseMC, Ctrl, Out, ThenVar, ElseVar) ->
        Events = [ite_mux(Ctrl, Out, ThenVar, ElseVar) | Rest]
    ;
        %% Unrecognised ite shape -- collect ops from branches
        collect_ev(ThenMC, CM, ThenOps),
        collect_ev(ElseMC, CM, ElseOps),
        append(ThenOps, ElseOps, BranchOps),
        append(BranchOps, Rest, Events)
    ),
    collect_ev(T, CM, Rest).
collect_ev([_|T], CM, Events) :-
    collect_ev(T, CM, Events).

%% ============================================================
%%  recognise_ite/7
%%  Match the specific pattern:
%%    cond: [guard(Ctrl =:= 0)]  or [guard(Ctrl =:= 1)]
%%    then: [unify(Out, ThenVar)]
%%    else: [unify(Out, ElseVar)]
%% ============================================================

recognise_ite(CondMC, ThenMC, ElseMC, Ctrl, Out, ThenVar, ElseVar) :-
    %% Condition must be a single equality test on a named wire
    ( CondMC = [guard(Ctrl =:= 0)] ->
        TrueIsZero = true
    ; CondMC = [guard(Ctrl =:= 1)] ->
        TrueIsZero = false
    ),
    atom(Ctrl),
    %% Branches must each be a single unification
    ThenMC = [unify(Out, V1)],
    ElseMC = [unify(Out, V2)],
    atom(Out), atom(V1), atom(V2),
    %% Map: if Ctrl=0 takes then-branch, ThenVar=V1, ElseVar=V2
    ( TrueIsZero = true ->
        ThenVar = V1, ElseVar = V2
    ;   ThenVar = V2, ElseVar = V1
    ).

%% ============================================================
%%  ite_to_lines/4
%%  Generate gate lines for ite_mux(Ctrl, Out, ThenVar, ElseVar).
%%  WM = wire map [Name-BaseIdx, ...]
%%  Bits = register width
%%
%%  Construction:
%%    1. Copy ThenVar -> Out  (cx per bit)
%%    2. CSWAP(Ctrl, Out_i, ElseVar_i) per bit
%%       CSWAP = cx b,a; ccx ctrl,a,b; cx b,a
%% ============================================================

ite_to_lines(ite_mux(Ctrl, Out, ThenVar, ElseVar), WM, Bits, Lines) :-
    wire_base(Ctrl,    WM, CtrlBase),
    wire_base(Out,     WM, OutBase),
    wire_base(ThenVar, WM, ThenBase),
    wire_base(ElseVar, WM, ElseBase),
    CtrlQ is CtrlBase,             %% single-bit control wire
    Bits1 is Bits - 1,
    numlist(0, Bits1, Offsets),
    %% Step 1: copy ThenVar -> Out
    maplist([Off, L]>>(
        T is ThenBase + Off, O is OutBase + Off,
        format(atom(L), "cx q[~w], q[~w];", [T, O])
    ), Offsets, CopyLines),
    %% Step 2: CSWAP(Ctrl, Out_i, ElseVar_i) per bit
    maplist([Off, [L1,L2,L3]]>>(
        O is OutBase  + Off,
        E is ElseBase + Off,
        format(atom(L1), "cx q[~w], q[~w];",       [E, O]),
        format(atom(L2), "ccx q[~w], q[~w], q[~w];", [CtrlQ, O, E]),
        format(atom(L3), "cx q[~w], q[~w];",       [E, O])
    ), Offsets, CSwapNested),
    flatten(CSwapNested, CSwapLines),
    append(CopyLines, CSwapLines, Lines).

%% ============================================================
%%  Helpers
%% ============================================================

wire_base(Name, WM, Base) :-
    ( member(Name-Base, WM) ->
        true
    ;
        format("[rp_ite] WARNING: ~w not in wire map~n", [Name]),
        Base = 0
    ).

%% Expression -> op term (same as rp_gates)
expr_to_op(A + B,   V, op(rev_add, A, B, V)).
expr_to_op(A - B,   V, op(rev_sub, A, B, V)).
expr_to_op(A * B,   V, op(rev_mul, A, B, V)).
expr_to_op(A mod B, V, op(rev_mod, A, B, V)).
expr_to_op(A >> B,  V, op(rev_shr, A, B, V)).
expr_to_op(A /\ B,  V, op(rev_and, A, B, V)).
expr_to_op(A xor B, V, op(rev_xor, A, B, V)).
expr_to_op(_,       V, op(unknown, V, none, none)).

%% Constant folding (same logic as rp_fold, local copy for independence)
rp_fold_const_map(MC, ConstMap) :-
    foldl(acc_const, MC, [], ConstMap).

acc_const(next(V, Expr), Acc, NewAcc) :-
    ( ground_eval(Expr, Acc, Val) ->
        ( \+ memberchk(V-_, Acc) -> NewAcc = [V-Val|Acc] ; NewAcc = Acc )
    ;   NewAcc = Acc
    ).
acc_const(_, Acc, Acc).

ground_eval(X, _, X)    :- integer(X), !.
ground_eval(X, M, V)    :- atom(X), memberchk(X-V, M), integer(V), !.
ground_eval(A+B, M, V)  :- ground_eval(A,M,VA), ground_eval(B,M,VB), !, V is VA+VB.
ground_eval(A-B, M, V)  :- ground_eval(A,M,VA), ground_eval(B,M,VB), !, V is VA-VB.
ground_eval(A*B, M, V)  :- ground_eval(A,M,VA), ground_eval(B,M,VB), !, V is VA*VB.
ground_eval(A mod B,M,V):- ground_eval(A,M,VA), ground_eval(B,M,VB), !, V is VA mod VB.
ground_eval(A>>B, M, V) :- ground_eval(A,M,VA), ground_eval(B,M,VB), !, V is VA>>VB.
ground_eval(A/\B, M, V) :- ground_eval(A,M,VA), ground_eval(B,M,VB), !, V is VA/\VB.

fold_arg(Map, Arg, Val) :-
    atom(Arg), \+ number(Arg),
    memberchk(Arg-Val, Map),
    integer(Val), !.
fold_arg(_, Arg, Arg).

