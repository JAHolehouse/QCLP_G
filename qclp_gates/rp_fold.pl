%% ============================================================
%%  rp_fold.pl  --  Compile-time constant folding for op/4 terms
%%
%%  Some wires in the op list are bound to concrete integer
%%  values by preceding next() events.  For example:
%%
%%    next(t1, 2 + -1)   -->  t1 = 1
%%    op(rev_shr, exp, t1, t2)  -->  shift exp by t1
%%
%%  At gate generation time, the shift amount t1 must be a
%%  concrete integer so the SWAP chain can be statically routed.
%%  This pass evaluates all constant-valued wires and substitutes
%%  them into subsequent op arguments.
%%
%%  rp_fold_ops(+MC, -FoldedOps)
%%    Takes full microcode (not just ops) so it can see the
%%    next() events that produce constant values.
%%    Returns op/4 list with constant wire args replaced by integers.
%%
%%  rp_const_map(+MC, -ConstMap)
%%    Returns a list of Var-Value pairs for wires that are
%%    bound to ground integers by next() events.
%% ============================================================

:- module(rp_fold, [
    rp_fold_ops/2,
    rp_const_map/2
]).

:- use_module(rp_gates, [rp_ops/2]).

%% ============================================================
%%  Build constant map from microcode
%%  A wire is constant if its expression evaluates to a ground
%%  integer under the already-known constants.
%% ============================================================

rp_const_map(MC, ConstMap) :-
    foldl(accumulate_const, MC, [], ConstMap).

accumulate_const(next(V, Expr), Acc, NewAcc) :-
    ( ground_eval(Expr, Acc, Val) ->
        ( \+ memberchk(V-_, Acc) ->
            NewAcc = [V-Val | Acc]
        ;   NewAcc = Acc
        )
    ;   NewAcc = Acc
    ).
accumulate_const(_, Acc, Acc).

%% Evaluate an arithmetic expression under a partial constant map
ground_eval(X, _, X) :- integer(X), !.
ground_eval(X, Map, V) :-
    atom(X), memberchk(X-V, Map), integer(V), !.
ground_eval(A+B, Map, V) :-
    ground_eval(A,Map,VA), ground_eval(B,Map,VB), !,
    V is VA+VB.
ground_eval(A-B, Map, V) :-
    ground_eval(A,Map,VA), ground_eval(B,Map,VB), !,
    V is VA-VB.
ground_eval(A*B, Map, V) :-
    ground_eval(A,Map,VA), ground_eval(B,Map,VB), !,
    V is VA*VB.
ground_eval(A mod B, Map, V) :-
    ground_eval(A,Map,VA), ground_eval(B,Map,VB), !,
    V is VA mod VB.
ground_eval(A//B, Map, V) :-
    ground_eval(A,Map,VA), ground_eval(B,Map,VB), !,
    V is VA//VB.
ground_eval(A>>B, Map, V) :-
    ground_eval(A,Map,VA), ground_eval(B,Map,VB), !,
    V is VA>>VB.
ground_eval(A/\B, Map, V) :-
    ground_eval(A,Map,VA), ground_eval(B,Map,VB), !,
    V is VA/\VB.

%% ============================================================
%%  Fold constants into op/4 terms
%% ============================================================

rp_fold_ops(MC, FoldedOps) :-
    rp_const_map(MC, ConstMap),
    rp_ops(MC, Ops),
    maplist(fold_op(ConstMap), Ops, FoldedOps).

fold_op(Map, op(Name,A,B,V), op(Name,A2,B2,V)) :-
    fold_arg(Map, A, A2),
    fold_arg(Map, B, B2).

%% Substitute a known-constant wire with its integer value
fold_arg(Map, Arg, Val) :-
    atom(Arg), \+ number(Arg),
    memberchk(Arg-Val, Map),
    integer(Val), !.
fold_arg(_, Arg, Arg).

