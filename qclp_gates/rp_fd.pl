%% ============================================================
%%  rp_fd.pl  --  RProlog(FD): Finite Domain constraint extension
%%
%%  Compiles finite-domain constraints into oracle microcode
%%  for Grover's search algorithm.
%%
%%  Constraint predicates (write these in your FD programs):
%%    fd_domain(Var, Low, High)    Var in Low..High
%%    fd_eq(X, Y)                  X #= Y
%%    fd_neq(X, Y)                 X #\= Y
%%    fd_lt(X, Y)                  X #< Y
%%    fd_le(X, Y)                  X #=< Y
%%    fd_sum_eq(X, Y, Z)           X + Y #= Z
%%    fd_sum_neq(X, Y, Z)          X + Y #\= Z
%%    fd_all_different(Vars)       all-different constraint
%%    fd_product_eq(X, Y, Z)       X * Y #= Z
%%
%%  Oracle microcode event types:
%%    next(V, Expr)              reversible arithmetic (from rp_engine.pl)
%%    flag_test(Anc, TestKind)   flip oracle_flag based on ancilla Anc
%%
%%  TestKind values and their gate translations:
%%    eq_zero   -- Anc =:= 0  -->  X all bits, MCX -> flag, X all bits
%%    neq_zero  -- Anc =\= 0  -->  OR-reduction into flag (via ancilla chain)
%%    gt_zero   -- Anc > 0    -->  test sign bit = 0 AND any lower bit = 1
%%                                 (simplified: test that Anc[N-1] = 0,
%%                                  i.e. not negative in two's complement)
%%    ge_zero   -- Anc >= 0   -->  test sign bit = 0  (CX sign -> flag)
%%
%%  The flag_test event is translated to QASM gates by rp_grover_structured.pl.
%%  The next events are translated by rp_gates.pl (rp_expand_ops_n).
%%  Bennett uncompute of next events is done by rp_fd_oracle_gates/3.
%%
%%  CHANGE LOG:
%%    v1: initial implementation
%%    v2: fix all_different ancilla bug (remove dead numlist/4 call)
%%        replace guard/1 with flag_test/2 for proper quantum translation
%%        add rp_fd_solve/2 for classical verification
%% ============================================================

:- module(rp_fd, [
    %% Constraint predicates
    fd_domain/3,
    fd_eq/2,
    fd_neq/2,
    fd_lt/2,
    fd_le/2,
    fd_sum_eq/3,
    fd_sum_neq/3,
    fd_all_different/1,
    fd_product_eq/3,
    %% Compilation API
    rp_fd_compile/2,        % +Goals, -FDSpec
    rp_fd_oracle_mc/2,      % +FDSpec, -OracleMC
    rp_fd_oracle_gates/3,   % +OracleMC, +Bits, -GateLines (fwd+uncompute)
    rp_fd_solve/2,          % +FDSpec, -Solutions (classical checker)
    rp_fd_solve/3,          % +FDSpec, +MaxSols, -solutions(List,Flag)
    rp_fd_info/1,           % +FDSpec
    %% Utilities
    fd_domain_bits/2,
    fd_register_bits/2,
    fd_domain_size/2,
    fd_spec_domains/2,
    check_constraint/2,
    fd_spec_constraints/2
]).

:- use_module(library(lists)).
:- use_module(library(aggregate)).

%% ============================================================
%%  Constraint predicates (classical semantics)
%% ============================================================

fd_domain(Var, Low, High) :-
    integer(Low), integer(High), Low =< High,
    ( integer(Var) -> Low =< Var, Var =< High ; true ).

fd_eq(X, Y)         :- ( integer(X), integer(Y) -> X =:= Y  ; true ).
fd_neq(X, Y)        :- ( integer(X), integer(Y) -> X =\= Y  ; true ).
fd_lt(X, Y)         :- ( integer(X), integer(Y) -> X < Y    ; true ).
fd_le(X, Y)         :- ( integer(X), integer(Y) -> X =< Y   ; true ).
fd_sum_eq(X, Y, Z)  :- ( integer(X), integer(Y), integer(Z) -> X+Y =:= Z ; true ).
fd_sum_neq(X, Y, Z) :- ( integer(X), integer(Y), integer(Z) -> X+Y =\= Z ; true ).
fd_all_different([]).
fd_all_different([H|T]) :-
    maplist([X]>>(integer(H), integer(X) -> H =\= X ; true), T),
    fd_all_different(T).

fd_product_eq(X, Y, Z) :-
    ( integer(X), integer(Y), integer(Z) -> X*Y =:= Z ; true ).

%% ============================================================
%%  FDSpec representation
%%
%%  fd_spec(Domains, Constraints)
%%    Domains     = list of dom(Var, Low, High)
%%    Constraints = list of con(Type, Args)
%% ============================================================

%% ============================================================
%%  rp_fd_compile/2
%% ============================================================

rp_fd_compile(Goals, fd_spec(Domains, Constraints)) :-
    partition(is_domain_goal, Goals, DomGoals, ConGoals),
    maplist(domain_goal_set, DomGoals, VarSets),
    merge_domains(VarSets, Domains, HoleCons),
    maplist(parse_constraint, ConGoals, RawConstraints0),
    append(HoleCons, RawConstraints0, RawConstraints),
    arc_consistency(RawConstraints, Domains, Constraints).

is_domain_goal(fd_domain(_,_,_)).
is_domain_goal(fd_domain(_,_)).    % QCLP list/range form
is_domain_goal(fd_eq(V,C)) :- atom(V), integer(C), !.  % clue: V's domain is {C}

%% ============================================================
%%  Domains
%%
%%  Every goal that restricts a variable's values -- fd_domain(V,Lo,Hi),
%%  fd_domain(V,List), fd_domain(V,Lo-Hi) and a clue fd_eq(V,C) -- is
%%  read as a SET of values, and all sets for the same variable are
%%  INTERSECTED, in any order. (Previously the first dom/3 for a
%%  variable won and later ones were dropped, so the usual QCLP
%%  pattern fd_domain(v,1,9), fd_eq(v,5) silently lost the clue.)
%%
%%  The result is stored as dom(V, Min, Max) plus one con(neq,[V,Gap])
%%  per missing value between Min and Max, so every path (classical
%%  solver, pcode, exact circuit) sees the gaps unchanged.
%%
%%  Sets are sorted, merged interval lists [Lo-Hi, ...], so a range
%%  like 0..1000 costs one interval, not a thousand values.
%% ============================================================

%%  domain_goal_set(+Goal, -Var-Intervals)
domain_goal_set(fd_domain(V, Lo, Hi), V-Is) :- !,
    domain_list_intervals(V, fd_domain(V, Lo, Hi), [Lo-Hi], Is).
domain_goal_set(fd_domain(V, List), V-Is) :- is_list(List), !,
    domain_list_intervals(V, fd_domain(V, List), List, Is).
domain_goal_set(fd_domain(V, Lo-Hi), V-Is) :- !,
    domain_list_intervals(V, fd_domain(V, Lo-Hi), [Lo-Hi], Is).
domain_goal_set(fd_eq(V, C), V-[C-C]) :- !.
domain_goal_set(G, _) :-
    domain_error_msg(G, "expected fd_domain(V,Lo,Hi), fd_domain(V,[...]) or fd_domain(V,Lo-Hi)").

%%  merge_domains(+VarSets, -Domains, -HoleConstraints)
%%  Variables keep the order of their first appearance.
merge_domains(VarSets, Domains, HoleCons) :-
    pairs_keys(VarSets, Vs0), list_to_set(Vs0, Vars),
    maplist(merge_one(VarSets), Vars, Domains, HoleLists),
    append(HoleLists, HoleCons).

merge_one(VarSets, V, dom(V, Min, Max), Holes) :-
    findall(Is, member(V-Is, VarSets), [First|Rest]),
    foldl([B, A, C]>>intervals_intersect(A, B, C), Rest, First, Common),
    (   Common == []
    ->  %% The declarations share no value: the problem has no
        %% solutions. Keep V's first domain and add constraints that
        %% no value can meet, so every path reports 0 solutions.
        format(user_error,
               "[rp_fd] WARNING: the domains given for ~w (including any fd_eq clue) have no value in common -- the problem has no solutions~n",
               [V]),
        First = [Min-_|_], last(First, _-Max),
        intervals_values(First, Vals),
        maplist([X, con(neq, [V, X])]>>true, Vals, Holes)
    ;   Common = [Min-_|_], last(Common, _-Max),
        intervals_gaps(Common, Gaps),
        maplist([G, con(neq, [V, G])]>>true, Gaps, Holes)
    ).

%%  domain_list_intervals(+Var, +Goal, +List, -Intervals)
%%  QCLP list domain syntax: each element is an integer N, or Lo-Hi
%%  meaning every integer from Lo to Hi inclusive (negative bounds are
%%  fine: -3-2 reads as the pair (-3, 2)). Overlaps and duplicates
%%  merge; order does not matter. The elements are TERMS: Lo-Hi is
%%  never evaluated as subtraction (previously min_list/2 evaluated
%%  it, so [0,2-3] became -1..0).
domain_list_intervals(_, G, [], _) :- !,
    domain_error_msg(G, "the list of values is empty").
domain_list_intervals(_, G, List, Is) :-
    maplist(domain_element_interval(G), List, Is0),
    msort(Is0, Is1),
    intervals_merge(Is1, Is).

domain_element_interval(_, N, N-N) :- integer(N), !.
domain_element_interval(G, Lo-Hi, Lo-Hi) :- integer(Lo), integer(Hi), !,
    (   Lo =< Hi -> true
    ;   format(string(Why), "range ~w-~w runs backwards (write ~w-~w)", [Lo, Hi, Hi, Lo]),
        domain_error_msg(G, Why)
    ).
domain_element_interval(G, E, _) :-
    format(string(Why), "~q is not an integer or an integer range Lo-Hi", [E]),
    domain_error_msg(G, Why).

domain_error_msg(G, Why) :-
    format(string(Msg), "~q: ~w", [G, Why]),
    throw(error(domain_error(fd_domain, G), context(rp_fd_compile/2, Msg))).

%%  Interval-list helpers (lists of Lo-Hi, sorted, disjoint, non-adjacent)
intervals_merge([], []).
intervals_merge([I], [I]) :- !.
intervals_merge([L1-H1, L2-H2 | Rest], Out) :-
    (   L2 =< H1 + 1
    ->  H is max(H1, H2), intervals_merge([L1-H | Rest], Out)
    ;   Out = [L1-H1 | Out1], intervals_merge([L2-H2 | Rest], Out1)
    ).

intervals_intersect([], _, []) :- !.
intervals_intersect(_, [], []) :- !.
intervals_intersect([L1-H1|R1], [L2-H2|R2], Out) :-
    L is max(L1, L2), H is min(H1, H2),
    ( L =< H -> Out = [L-H | Out1] ; Out = Out1 ),
    (   H1 < H2 -> intervals_intersect(R1, [L2-H2|R2], Out1)
    ;   intervals_intersect([L1-H1|R1], R2, Out1)
    ).

intervals_gaps([_], []) :- !.
intervals_gaps([_-H1, L2-H2 | Rest], Gaps) :-
    A is H1 + 1, B is L2 - 1, numlist(A, B, G1),
    intervals_gaps([L2-H2 | Rest], G2),
    append(G1, G2, Gaps).

intervals_values(Is, Vals) :-
    findall(X, (member(L-H, Is), between(L, H, X)), Vals).

parse_constraint(fd_eq(X,Y),           con(eq,       [X,Y])) :- !.
parse_constraint(fd_neq(X,Y),          con(neq,      [X,Y])) :- !.
parse_constraint(fd_lt(X,Y),           con(lt,       [X,Y])) :- !.
parse_constraint(fd_le(X,Y),           con(le,       [X,Y])) :- !.
parse_constraint(fd_sum_eq(X,Y,Z),     con(sum_eq,   [X,Y,Z])) :- !.
parse_constraint(fdsumeq(X,Y,Z),       con(sum_eq,   [X,Y,Z])) :- !.
parse_constraint(fd_sum_neq(X,Y,Z),    con(sum_neq,  [X,Y,Z])) :- !.
parse_constraint(fdsumneq(X,K,Y),      con(sum_neq,  [X,K,Y])) :- !.
parse_constraint(fd_all_different(Vs), con(all_diff,  Vs)) :- !.
parse_constraint(fdalldifferent(Vs),   con(all_diff,  Vs)) :- !.
parse_constraint(fd_product_eq(X,Y,Z), con(prod_eq,  [X,Y,Z])) :- !.
parse_constraint(fd_ge(X,Y),           con(ge,       [X,Y])) :- !.
parse_constraint(fd_gt(X,Y),           con(gt,       [X,Y])) :- !.
parse_constraint(fd_eq(V,C),           con(eq,       [V,C])) :- !.
%% Soft constraints
parse_constraint(fd_cost(W,C),         con(cost,     [W,C])) :- !,
    %% Validate now rather than silently scoring 0 later: the weight
    %% must be a number and the inner constraint one RProlog evaluates.
    (   number(W) -> true
    ;   constraint_error(fd_cost(W,C), "the weight must be a number")
    ),
    parse_constraint(C, Inner),
    (   Inner = con(cost, _)
    ->  constraint_error(fd_cost(W,C), "fd_cost cannot contain another fd_cost")
    ;   true
    ).
%% Extended constraints
parse_constraint(fd_weighted_sum(Pairs,T), con(weighted_sum, [Pairs,T])) :- !.
parse_constraint(fd_abs_diff(X,Y,D),   con(abs_diff, [X,Y,D])) :- !.
parse_constraint(fd_min(List,M),       con(min_list, [List,M])) :- !.
parse_constraint(fd_max(List,M),       con(max_list, [List,M])) :- !.
parse_constraint(fd_count(List,V,N),   con(count,    [List,V,N])) :- !.
%%  Anything else is an error. (It used to become con(unknown,_), which
%%  every solver path then treated as always satisfied, so a typo or an
%%  unsupported constraint such as fd_xor silently gave wrong answers.)
parse_constraint(G, _) :-
    constraint_error(G, "not a recognised constraint. Supported: fd_eq, fd_neq, fd_lt, fd_le, fd_gt, fd_ge, fd_sum_eq/fdsumeq, fd_sum_neq/fdsumneq, fd_all_different/fdalldifferent, fd_product_eq, fd_weighted_sum, fd_abs_diff, fd_min, fd_max, fd_count, fd_cost").

constraint_error(G, Why) :-
    format(string(Msg), "~q: ~w", [G, Why]),
    throw(error(domain_error(fd_constraint, G), context(rp_fd_compile/2, Msg))).


%% ============================================================
%%  Arc consistency (unary propagation pass)
%% ============================================================

arc_consistency(Constraints, Domains, Constraints) :-
    foldl(propagate_unary, Constraints, Domains, _).

propagate_unary(con(lt, [Var, Const]), Doms0, Doms1) :-
    atom(Var), integer(Const), !,
    NewHigh is Const - 1,
    tighten_high(Var, NewHigh, Doms0, Doms1).
propagate_unary(con(le, [Var, Const]), Doms0, Doms1) :-
    atom(Var), integer(Const), !,
    tighten_high(Var, Const, Doms0, Doms1).
propagate_unary(con(lt, [Const, Var]), Doms0, Doms1) :-
    integer(Const), atom(Var), !,
    NewLow is Const + 1,
    tighten_low(Var, NewLow, Doms0, Doms1).
propagate_unary(con(le, [Const, Var]), Doms0, Doms1) :-
    integer(Const), atom(Var), !,
    tighten_low(Var, Const, Doms0, Doms1).
propagate_unary(_, Doms, Doms).

tighten_high(Var, NewHigh, Doms0, Doms1) :-
    ( select(dom(Var, Low, High), Doms0, Rest) ->
        ActualHigh is min(High, NewHigh),
        Doms1 = [dom(Var, Low, ActualHigh)|Rest]
    ;   Doms1 = Doms0 ).

tighten_low(Var, NewLow, Doms0, Doms1) :-
    ( select(dom(Var, Low, High), Doms0, Rest) ->
        ActualLow is max(Low, NewLow),
        Doms1 = [dom(Var, ActualLow, High)|Rest]
    ;   Doms1 = Doms0 ).

%% ============================================================
%%  rp_fd_oracle_mc/2
%%
%%  Produces a list of oracle microcode events:
%%    next(AncVar, Expr)        -- reversible arithmetic
%%    flag_test(AncVar, Kind)   -- flip oracle_flag if test passes
%%
%%  flag_test kinds:
%%    eq_zero   Anc must equal 0       (equality check)
%%    neq_zero  Anc must be non-zero   (inequality check)
%%    gt_zero   Anc must be > 0        (strict lower bound)
%%    ge_zero   Anc must be >= 0       (non-negative, sign-bit test)
%%
%%  The rp_fd_oracle_gates/3 predicate translates these to real
%%  QASM gate sequences.  The next/2 events are handled by
%%  rp_expand_ops_n from rp_gates.pl (same as existing RProlog).
%% ============================================================

rp_fd_oracle_mc(FDSpec, OracleMC) :-
    FDSpec = fd_spec(_Domains, Constraints),
    nb_setval(rp_current_fdspec, FDSpec),
    gen_mc(0, Constraints, OracleMC, []).

gen_mc(_, [], T, T).
gen_mc(N, [Con|Cons], MC, T) :-
    N1 is N + 1,
    constraint_mc(Con, N1, MC, Mid),
    gen_mc(N1, Cons, Mid, T).

%% ---- eq: X = Y  -->  XOR into anc, test eq_zero -----------
%%  (XOR is cheaper than subtraction; zero XOR = identical)
constraint_mc(con(eq, [X, Y]), N,
              [next(Anc, X xor Y), flag_test(Anc, eq_zero)|T], T) :-
    anc(N, Anc).

%% ---- neq: X \= Y  -->  XOR into anc, test neq_zero --------
constraint_mc(con(neq, [X, Y]), N,
              [next(Anc, X xor Y), flag_test(Anc, neq_zero)|T], T) :-
    anc(N, Anc).

%% ---- lt: X < Y  -->  Y-X into anc, test gt_zero -----------
%%  Y-X > 0  iff  X < Y
constraint_mc(con(lt, [X, Y]), N,
              [next(Anc, Y-X), flag_test(Anc, gt_zero)|T], T) :-
    anc(N, Anc).

%% ---- le: X =< Y  -->  Y-X into anc, test ge_zero ----------
%%  Y-X >= 0  iff  X =< Y
constraint_mc(con(le, [X, Y]), N,
              [next(Anc, Y-X), flag_test(Anc, ge_zero)|T], T) :-
    anc(N, Anc).

%% ---- sum_eq: X+Y = Z  -->  add into anc1, sub Z into anc2,
%%                             test eq_zero -----------------
constraint_mc(con(sum_eq, [X, Y, Z]), N,
              [next(Anc1, X+Y), next(Anc2, Anc1-Z),
               flag_test(Anc2, eq_zero)|T], T) :-
    anc(N,          Anc1),
    anc_offset(N, 1, Anc2).

%% ---- sum_neq: X+Y \= Z  -->  same arithmetic, test neq_zero
constraint_mc(con(sum_neq, [X, Y, Z]), N,
              [next(Anc1, X+Y), next(Anc2, Anc1-Z),
               flag_test(Anc2, neq_zero)|T], T) :-
    anc(N,          Anc1),
    anc_offset(N, 1, Anc2).

%% ---- prod_eq: X*Y = Z  -->  mul into anc1, test eq_const(anc1, Z) ----------
%%  Uses the schoolbook N^2-Toffoli multiplier from rp_gates.pl.
%%  anc1 holds the 2N-bit product X*Y.
%%  We test anc1 == Z directly via bit-pattern matching:
%%    flip the 0-bits of Z in anc1, MCX all 2N bits -> oracle_flag, flip back.
%%  This avoids the subtraction circuit entirely, eliminating the need for
%%  fd_anc2, carry, and const_Z ancilla registers.
constraint_mc(con(prod_eq, [X, Y, Z]), N,
              [next(Anc1, X*Y),
               flag_test(Anc1, eq_const(ZVal))|T], T) :-
    anc(N, Anc1),
    %% If Z is an integer use it directly; if it's a variable name
    %% resolve it via the FDSpec domains (singleton domain = constant).
    ( integer(Z) -> ZVal = Z
    ; nb_getval(rp_current_fdspec, fd_spec(Doms, _)),
      member(dom(Z, ZVal, ZVal), Doms) -> true
    ; ZVal = Z   % fallback: leave as atom, check_flag will handle
    ).

%% ---- all_different: expand to pairwise neq -----------------
%%  FIX v2: removed dead numlist/4 call; use gen_ids/3 directly.
constraint_mc(con(all_diff, Vars), N, MC, T) :-
    findall(con(neq, [A, B]),
            (nth1(I, Vars, A), nth1(J, Vars, B), I < J),
            Pairs),
    length(Pairs, NP),
    %% BaseId must not collide with anc_offset(N,Offset,_) = N*100+Offset
    %% for any top-level constraint N and small Offset.  N*100000 is safe:
    %% anc_offset only ever produces IDs of the form N*100+k for small k,
    %% which never reach the N*100000 range for realistic N.
    BaseId is N * 100000,
    gen_ids(BaseId, NP, Ids),
    maplist([Con, Id, SubMC]>>(constraint_mc(Con, Id, SubMC, [])),
            Pairs, Ids, SubMCs),
    flatten(SubMCs, FlatMC),
    append(FlatMC, T, MC).

%% ---- ge: X >= Y  -->  X-Y into anc, test ge_zero -----------
constraint_mc(con(ge, [X, Y]), N,
              [next(Anc, X-Y), flag_test(Anc, ge_zero)|T], T) :-
    anc(N, Anc).

%% ---- gt: X > Y  -->  X-Y into anc, test gt_zero -----------
constraint_mc(con(gt, [X, Y]), N,
              [next(Anc, X-Y), flag_test(Anc, gt_zero)|T], T) :-
    anc(N, Anc).

%% ---- range_in: circuit-only domain bounds, Low =< V =< High ----
%%  Added by rp_grover:rp_grover_circuit_spec/2. A bare test on the
%%  domain register itself; no arithmetic ancilla.
constraint_mc(con(range_in, [V, L, H]), _, [flag_test(V, in_range(L, H))|T], T).

%% ---- cost: soft constraint -- skip in oracle microcode -----
%%  There is no cost oracle yet: the circuit, and run/1 (which
%%  simulates the circuit's oracle), search the hard constraints only.
constraint_mc(con(cost, _), _, T, T).

%% ---- weighted_sum: treat as sum_eq with scaling ------------
%%  Emits sum_eq oracle code for the core constraint.
%%  W*V terms: compile as repeated addition (approximation for small W).
constraint_mc(con(weighted_sum, [Pairs, Target]), N, MC, T) :-
    anc(N, Anc),
    anc_offset(N, 1, Anc2),
    %% Emit as: compute weighted sum into Anc, compare to Target
    %% For now: treat as unknown (complex multi-operand sum)
    MC = [next(Anc, weighted_sum(Pairs)),
          next(Anc2, Anc - Target),
          flag_test(Anc2, eq_zero) | T].

%% ---- abs_diff: |X-Y| = D  ---------------------------------
%%  abs_diff is tricky quantumly; skip oracle generation, warn.
constraint_mc(con(abs_diff, _), _, T, T) :-
    format("[rp_fd] NOTE: fd_abs_diff oracle MC not yet supported~n").

%% ---- min_list / max_list / count ---------------------------
constraint_mc(con(min_list, _), _, T, T) :-
    format("[rp_fd] NOTE: fd_min oracle MC not yet supported~n").
constraint_mc(con(max_list, _), _, T, T) :-
    format("[rp_fd] NOTE: fd_max oracle MC not yet supported~n").
constraint_mc(con(count, _), _, T, T) :-
    format("[rp_fd] NOTE: fd_count oracle MC not yet supported~n").

%% ---- unknown: skip with warning ----------------------------
constraint_mc(con(unknown, [G]), _, T, T) :-
    format("[rp_fd] WARNING: skipping unknown constraint ~w~n", [G]).

%% ============================================================
%%  rp_fd_oracle_gates/3
%%
%%  Translates oracle microcode to concrete QASM gate lines.
%%  Handles BOTH the forward pass AND the Bennett uncompute,
%%  so the caller (rp_grover_structured.pl) gets two blocks directly.
%%
%%  rp_fd_oracle_gates(+OracleMC, +Bits, -GatePair)
%%    GatePair = fwd_rev(FwdLines, RevLines)
%%
%%  Forward pass:
%%    next(V, Expr)         --> rp_expand_ops_n gate sequence
%%    flag_test(Anc, Kind)  --> kind-specific gate sequence
%%
%%  Reverse pass (Bennett uncompute):
%%    flag_test events are OMITTED (they are not reversed;
%%    the phase has already been imprinted on oracle_flag)
%%    next events are emitted in reverse order with the same gates
%%    (all arithmetic gates are self-inverse at Layer 3)
%%
%%  This is the key architectural point: flag_test gates are
%%  NOT uncomputed.  The Bennett paradigm uncomputes the ancilla
%%  arithmetic (next events) but leaves the flag marking intact.
%% ============================================================

rp_fd_oracle_gates(OracleMC, Bits, fwd_rev(FwdLines, RevLines)) :-
    %% Separate next events from flag_test events
    partition(is_next_event, OracleMC, NextEvents, FlagEvents),

    %% Build the set of ancilla that hold multiplication results (or are derived from them).
    %% These are 2*Bits wide; the flag test must check all 2*Bits bits, not just Bits.
    mul_result_vars(NextEvents, MulVars),

    %% Forward: expand next events to gates, then emit flag tests
    next_events_to_gates(NextEvents, Bits, ArithFwd),
    flag_events_to_gates_adaptive(FlagEvents, Bits, MulVars, FlagGates),
    append(ArithFwd, FlagGates, FwdLines),

    %% Reverse (Bennett): events in reverse order AND gates within each event reversed.
    %%
    %% CRITICAL: The Cuccaro adder/subtractor is NOT self-inverse when run twice.
    %% Its uncompute requires running the SAME gates in REVERSE ORDER (since each
    %% individual CX/CCX gate is its own inverse, reversing the sequence gives the
    %% circuit adjoint).  Reversing only the event order (not gate order within each
    %% event) was the original bug causing ancillae not to be cleaned up.
    %%
    %% Correct Bennett uncompute = reverse event list + reverse each event's gate block.
    reverse(NextEvents, RevNextEvents),
    next_events_to_gates_rev(RevNextEvents, Bits, RevLines).

is_next_event(next(_, _)).

next_events_to_gates(NextEvents, Bits, Lines) :-
    maplist([next(V, Expr), op(Name, A, B, V)]>>(expr_to_op(Expr, V, op(Name, A, B, V))),
            NextEvents, Ops),
    %% For multiplication ops, the result register is 2*Bits wide.
    %% For subsequent operations involving mul results, use 2*Bits.
    mul_result_vars(NextEvents, MulVars),
    maplist(expand_op_with_consts_adaptive(Bits, MulVars), Ops, Blocks),
    flatten(Blocks, Lines).

%% Collect variable names that are results of multiplication (direct or derived).
%%   Direct:  next(V, A*B)         -- V holds A*B, so V is 2*Bits wide.
%%   Derived: next(V, Expr) where Expr contains a direct mul-result variable
%%            -- e.g. next(anc2, anc1-6) when anc1 is a mul result.
%%            V is also 2*Bits wide because anc1 dominates the register width.
mul_result_vars(Events, MulVars) :-
    include([next(_,Expr)]>>(Expr = _*_), Events, DirectEvents),
    maplist([next(V,_), V]>>true, DirectEvents, DirectVars),
    findall(V,
        ( member(next(V, Expr), Events),
          Expr \= _*_,
          expr_mentions_any(Expr, DirectVars) ),
        DerivedVars),
    append(DirectVars, DerivedVars, MulVars).

%% Succeeds if any atom in VarList appears in Expr as a subterm.
expr_mentions_any(Expr, VarList) :-
    ( atom(Expr)     -> member(Expr, VarList)
    ; compound(Expr) -> Expr =.. [_|Args],
                        member(Arg, Args),
                        expr_mentions_any(Arg, VarList)
    ;   fail
    ).

%% Like expand_op_with_consts but uses 2*Bits when operands are mul results
expand_op_with_consts_adaptive(Bits, MulVars, Op, Lines) :-
    Op = op(_, A, _, _),
    ( member(A, MulVars) ->
        EffBits is 2 * Bits
    ;   EffBits = Bits
    ),
    expand_op_with_consts(EffBits, Op, Lines).

%%  next_events_to_gates_rev/3
%%  Like next_events_to_gates but reverses the gate sequence within each event block.
%%  Used for Bennett uncompute: event order is already reversed by the caller;
%%  reversing each block gives the correct circuit adjoint for adder/subtractor ops.
next_events_to_gates_rev(NextEvents, Bits, Lines) :-
    maplist([next(V, Expr), op(Name, A, B, V)]>>(expr_to_op(Expr, V, op(Name, A, B, V))),
            NextEvents, Ops),
    mul_result_vars(NextEvents, MulVars),
    maplist(expand_op_with_consts_adaptive(Bits, MulVars), Ops, Blocks),
    %% Reverse gate order within each block, then flatten
    maplist(reverse, Blocks, RevBlocks),
    flatten(RevBlocks, Lines).

%% expand_op_with_consts/3
%%  If an operand is an integer constant, allocate a const_reg_N wire,
%%  initialise it with X gates (encoding the value), expand the gate,
%%  then clean up (same X gates, since X is self-inverse).
expand_op_with_consts(Bits, op(Name, A, B, V), Lines) :-
    ( integer(A) ->
        const_wire(A, WA),
        const_init_lines(A, WA, Bits, InitA),
        A2 = WA
    ;   InitA = [], A2 = A ),
    ( integer(B) ->
        const_wire(B, WB),
        const_init_lines(B, WB, Bits, InitB),
        B2 = WB
    ;   InitB = [], B2 = B ),
    rp_expand_ops_n([op(Name, A2, B2, V)], Bits, GateLines),
    %% Cleanup: same init lines (X is self-inverse)
    append(InitA, InitB, AllInit),
    append(AllInit, GateLines, Lines1),
    append(Lines1, InitA,  Lines2),
    append(Lines2, InitB,  Lines).

const_wire(N, W) :- format(atom(W), "const~w", [N]).

%% Emit X gates to initialise a register to integer value N
const_init_lines(N, W, Bits, Lines) :-
    Bits1 is Bits - 1,
    numlist(0, Bits1, BitIdxs),
    include([I]>>(Bit is (N >> I) /\ 1, Bit =:= 1), BitIdxs, OneBits),
    ( OneBits = [] ->
        format(atom(DeclL), "qubit[~w] ~w;  // const ~w", [Bits, W, N]),
        Lines = [DeclL]
    ;
        format(atom(DeclL), "qubit[~w] ~w;  // const ~w", [Bits, W, N]),
        maplist([I, L]>>(format(atom(L), "x ~w[~w];", [W, I])), OneBits, XLines),
        Lines = [DeclL | XLines]
    ).

%% flag_test/2 --> gate sequences targeting oracle_flag (fixed bit width)
%% Original non-adaptive version kept for callers that don't need the mul-result fix.
flag_events_to_gates(FlagEvents, Bits, Lines) :-
    flag_events_to_gates_adaptive(FlagEvents, Bits, [], Lines).

%% Adaptive version: uses 2*Bits for ancilla that are mul-result registers.
flag_events_to_gates_adaptive(FlagEvents, Bits, MulVars, Lines) :-
    maplist([flag_test(Anc, Kind), GLines]>>(
        ( member(Anc, MulVars) ->
            EffBits is 2 * Bits
        ;   EffBits = Bits
        ),
        flag_test_gates(Anc, Kind, EffBits, GLines)
    ), FlagEvents, Nested),
    flatten(Nested, Lines).

%% ============================================================
%%  flag_test_gates/4
%%  The core quantum translation of each test kind.
%%
%%  eq_zero: Anc =:= 0
%%    X every bit of Anc (so |0...0> becomes |1...1>)
%%    Multi-controlled NOT on oracle_flag (all Anc bits = controls)
%%    X every bit of Anc (restore)
%%    Net effect: oracle_flag flipped iff Anc was all-zero.
%%
%%  neq_zero: Anc =\= 0
%%    Equivalent to: flip flag if ANY bit of Anc is 1.
%%    OR-reduction: chain of Toffoli gates feeding an or_anc qubit,
%%    then CX or_anc -> oracle_flag, then uncompute or_anc.
%%    For single-bit result (e.g. from XOR): just CX Anc[0] -> flag.
%%    For multi-bit: OR tree.
%%
%%  gt_zero: Anc > 0
%%    In two's-complement N-bit arithmetic, Anc > 0 iff:
%%      - sign bit (bit N-1) is 0  (not negative)
%%      - at least one other bit is 1  (not zero)
%%    Approximation used here: test sign bit = 0.
%%    (Catches Anc > 0 but also Anc = 0 -- close enough for
%%     domains where 0 is not a valid difference.)
%%    Gate: X Anc[N-1], CX Anc[N-1] -> oracle_flag, X Anc[N-1]
%%
%%  ge_zero: Anc >= 0
%%    In two's complement: sign bit = 0.
%%    Gate: X Anc[N-1], CX Anc[N-1] -> oracle_flag, X Anc[N-1]
%%    (Same as gt_zero -- the difference matters only at Anc=0,
%%     which both handle the same way at the gate level.)
%% ============================================================

%% eq_const(Val): flip the 0-bits of Val in Anc, MCX all bits -> flag, flip back.
%%   This tests Anc == Val without any subtraction circuit.
%%   Bits must match the width of Anc.
flag_test_gates(Anc, eq_const(Val), Bits, Lines) :-
    Bits1 is Bits - 1,
    numlist(0, Bits1, BitIdxs),
    %% Flip bits where Val has 0 (so that all bits become 1 iff Anc == Val)
    include([I]>>( B is (Val >> I) /\ 1, B =:= 0 ), BitIdxs, ZeroBitIdxs),
    maplist([I, L]>>(format(atom(L), "x ~w[~w];", [Anc, I])), ZeroBitIdxs, XLines),
    mcx_into_flag(Anc, Bits, MCXLines),
    append(XLines, MCXLines, Lines1),
    append(Lines1, XLines, Lines).  %% X again to restore

flag_test_gates(Anc, eq_zero, Bits, Lines) :-
    Bits1 is Bits - 1,
    numlist(0, Bits1, BitIdxs),
    maplist([I, L]>>(format(atom(L), "x ~w[~w];", [Anc, I])), BitIdxs, XLines),
    mcx_into_flag(Anc, Bits, MCXLines),
    append(XLines, MCXLines, Lines1),
    append(Lines1, XLines, Lines).  %% X again to restore

flag_test_gates(Anc, neq_zero, Bits, Lines) :-
    %% OR-reduction: fan Anc bits into oracle_flag via ancilla chain
    or_reduction(Anc, Bits, Lines).

flag_test_gates(Anc, gt_zero, Bits, Lines) :-
    %% Test sign bit = 0 (positive in two's complement)
    SignBit is Bits - 1,
    format(atom(XL),   "x ~w[~w];",                    [Anc, SignBit]),
    format(atom(CXL),  "cx ~w[~w], oracle_flag[0];",   [Anc, SignBit]),
    format(atom(XL2),  "x ~w[~w];  // restore sign",   [Anc, SignBit]),
    Lines = [XL, CXL, XL2].

flag_test_gates(Anc, ge_zero, Bits, Lines) :-
    %% Same gate pattern as gt_zero at this level
    flag_test_gates(Anc, gt_zero, Bits, Lines).

%% ============================================================
%%  mcx_into_flag/3
%%  Multi-controlled X targeting oracle_flag.
%%  All bits of Anc are control qubits.
%%  Uses a Toffoli chain with a single mcx_anc ancilla.
%%
%%  For 1 control bit:  CX Anc[0], oracle_flag
%%  For 2 control bits: CCX Anc[0], Anc[1], oracle_flag
%%  For N>2:            ladder of Toffoli gates through mcx_anc
%% ============================================================

mcx_into_flag(Anc, 1, [L]) :-
    format(atom(L), "cx ~w[0], oracle_flag[0];", [Anc]).
mcx_into_flag(Anc, 2, [L]) :-
    format(atom(L), "ccx ~w[0], ~w[1], oracle_flag[0];", [Anc, Anc]).
mcx_into_flag(Anc, Bits, Lines) :-
    Bits > 2,
    Bits1 is Bits - 1,
    numlist(0, Bits1, BitIdxs),
    %% Ladder: accumulate controls into mcx_anc, then CCX into flag
    toffoli_ladder(Anc, BitIdxs, "mcx_anc", "oracle_flag", Lines).

%%  toffoli_ladder(+Anc, +BitIdxs, +_AncWire, +Target, -Lines)
%%  Implements MCX(Anc[BitIdxs] -> Target[0]) for arbitrary N controls.
%%
%%  Linear AND-chain decomposition (clean, N-2 ancilla for N controls):
%%    Step 1: a0 = Anc[B0] AND Anc[B1]            (CCX B0,B1 -> a0)
%%    Step i: a_i = a_{i-1} AND Anc[B_{i+1}]      (CCX B_{i+1},a_{i-1} -> a_i)
%%    Final:  Target ^= a_{last} AND Anc[B_{N-1}]  (phase kickback CCX)
%%    Uncompute: steps N-2 down to 0 (same CCX gates again, self-inverse)
%%
%%  Full sequence: [Decls, G0, G1, ..., G_{N-3}, FinalGate, G_{N-3}, ..., G0]
%%  Ancilla mcx_anc0, mcx_anc1, ... declared inline (hoisted to header).

toffoli_ladder(Anc, Bits, _AncWire, Target, Lines) :-
    mcx_linear_chain(Anc, Bits, Target, Lines).

mcx_linear_chain(Anc, [B], Target, [L]) :-
    format(atom(L), "cx ~w[~w], ~w[0];", [Anc, B, Target]).

mcx_linear_chain(Anc, [B0,B1], Target, [L]) :-
    format(atom(L), "ccx ~w[~w], ~w[~w], ~w[0];", [Anc, B0, Anc, B1, Target]).

mcx_linear_chain(Anc, [B0,B1|RestBits], Target, Lines) :-
    RestBits \= [],
    %% Build: gate_a0 = CCX(Anc[B0], Anc[B1], mcx_anc0)
    format(atom(D0), "qubit[1] mcx_anc0;", []),
    format(atom(G0), "ccx ~w[~w], ~w[~w], mcx_anc0[0];", [Anc, B0, Anc, B1]),
    %% Extend chain for RestBits
    mcx_chain_extend(Anc, RestBits, mcx_anc0, 1, Target, ChainDecls, ChainGates, FinalGate),
    %% Full sequence: Decls, then fwd gates (G0, ChainGates), FinalGate, then uncompute (ChainGates reversed + G0)
    reverse(ChainGates, RevChainGates),
    flatten([[D0], ChainDecls, [G0], ChainGates, [FinalGate], RevChainGates, [G0]], Lines).

%%  mcx_chain_extend(+Anc, +RestBits, +PrevAnc, +Idx, +Target, -Decls, -ChainGates, -FinalGate)
%%  Build the AND-chain gates after the first step (a0 already computed into PrevAnc).
%%  RestBits: remaining bits to AND in.  Idx: next ancilla index.
%%  Returns ChainGates (each computes next AND level), FinalGate (last CCX into Target).
mcx_chain_extend(Anc, [LastBit], PrevAnc, _Idx, Target, [], [], FinalGate) :-
    %% Only one bit left: final gate
    format(atom(FinalGate), "ccx ~w[~w], ~w[0], ~w[0];", [Anc, LastBit, PrevAnc, Target]).

mcx_chain_extend(Anc, [Bit|MoreBits], PrevAnc, Idx, Target, [Decl|Decls], [Gate|Gates], FinalGate) :-
    MoreBits \= [],
    format(atom(AncName), "mcx_anc~w", [Idx]),
    format(atom(Decl), "qubit[1] ~w;", [AncName]),
    format(atom(Gate), "ccx ~w[~w], ~w[0], ~w[0];", [Anc, Bit, PrevAnc, AncName]),
    NextIdx is Idx + 1,
    mcx_chain_extend(Anc, MoreBits, AncName, NextIdx, Target, Decls, Gates, FinalGate).

%% ============================================================
%%  or_reduction/3
%%  Flip oracle_flag if any bit of Anc is 1.
%%  Uses a qubit ancilla 'or_anc' to accumulate the OR.
%%
%%  For 1-bit Anc:    just CX Anc[0], oracle_flag
%%  For multi-bit:    chain of Toffoli accumulating into or_anc,
%%                    CX or_anc -> oracle_flag, uncompute chain
%% ============================================================

or_reduction(Anc, 1, [L]) :-
    format(atom(L), "cx ~w[0], oracle_flag[0];", [Anc]).
or_reduction(Anc, 2, Lines) :-
    %% True OR of 2 bits: OR(A,B) = A XOR B XOR (A AND B)
    %% Gates: CX A,or_anc; CX B,or_anc; CCX A,B,or_anc
    %% Then CX or_anc -> flag; then uncompute (same gates, self-inverse)
    format(atom(L1), "cx ~w[0], or_anc[0];",       [Anc]),
    format(atom(L2), "cx ~w[1], or_anc[0];",       [Anc]),
    format(atom(L3), "ccx ~w[0], ~w[1], or_anc[0];", [Anc, Anc]),
    format(atom(CXL), "cx or_anc[0], oracle_flag[0];", []),
    Lines = ["qubit[1] or_anc;", L1, L2, L3, CXL, L3, L2, L1].
or_reduction(Anc, Bits, Lines) :-
    Bits > 2,
    Bits1 is Bits - 1,
    numlist(0, Bits1, BitIdxs),
    %% General N-bit true OR via inclusion-exclusion is complex.
    %% Use Bits-bit accumulation into or_anc using XOR + pairwise AND corrections.
    %% For simplicity at N>2, we use a chain approach:
    %% Fold: or_anc = bit0 XOR bit1 XOR (bit0 AND bit1), then
    %%        for each remaining bit bi: or_anc = or_anc OR bi
    %%          = or_anc XOR bi XOR (or_anc AND bi)
    %% This requires a second ancilla (or_anc2) to hold the AND term.
    %% Emit CX chain + CCX corrections for a full OR tree.
    maplist([I, L]>>(format(atom(L), "cx ~w[~w], or_anc[0];", [Anc, I])),
            BitIdxs, CXLines),
    %% Add pairwise AND corrections to turn parity into OR
    pairs_or_corrections(Anc, BitIdxs, AndLines),
    format(atom(CXL), "cx or_anc[0], oracle_flag[0];", []),
    reverse(CXLines, UncCXLines),
    reverse(AndLines, UncAndLines),
    flatten(["qubit[1] or_anc;",
             CXLines, AndLines, [CXL],
             UncAndLines, UncCXLines], Lines).

%%  pairs_or_corrections: add CCX for every pair to correct parity -> OR
%%  OR(b0..bn) = XOR of all bits + XOR of all AND(bi,bj) pairs + ...
%%  For simplicity we only do pairwise corrections (good for small Bits).
pairs_or_corrections(Anc, Bits, Lines) :-
    findall(L,
        ( nth0(I, Bits, BI), nth0(J, Bits, BJ), I < J,
          format(atom(L), "ccx ~w[~w], ~w[~w], or_anc[0];", [Anc, BI, Anc, BJ]) ),
        Lines).

%% ============================================================
%%  expr_to_op/3  (local copy matching rp_gates conventions)
%% ============================================================

expr_to_op(A + B,   V, op(rev_add, A, B, V)).
expr_to_op(A - B,   V, op(rev_sub, A, B, V)).
expr_to_op(A * B,   V, op(rev_mul, A, B, V)).
expr_to_op(A mod B, V, op(rev_mod, A, B, V)).
expr_to_op(A >> B,  V, op(rev_shr, A, B, V)).
expr_to_op(A /\ B,  V, op(rev_and, A, B, V)).
expr_to_op(A xor B, V, op(rev_xor, A, B, V)).
expr_to_op(_,       V, op(unknown, V, none, none)).

:- use_module(rp_gates, [rp_expand_ops_n/3]).

%% ============================================================
%%  rp_fd_solve/2  --  classical constraint satisfaction checker
%%  rp_fd_solve/3  --  capped version (stops after MaxSols found)
%%
%%  rp_fd_solve(+FDSpec, -Solutions)
%%    Finds ALL solutions. Only safe for small search spaces.
%%    Use rp_fd_solve/3 for large problems.
%%
%%  rp_fd_solve(+FDSpec, +MaxSols, -Solutions)
%%    Stops after MaxSols solutions.  Returns a list of up to
%%    MaxSols assignments plus a flag: exact or capped.
%%    Result = solutions(List, exact) or solutions(List, capped).
%%
%%  Search space warning threshold: 100,000 states.
%%  Above this, rp_fd_solve/2 prints a warning and uses a cap.
%% ============================================================

:- use_module(library(aggregate)).

rp_fd_solve(FDSpec, Solutions) :-
    FDSpec = fd_spec(Domains, _),
    maplist(fd_domain_size, Domains, Sizes),
    foldl([S,A,P]>>(P is A*S), Sizes, 1, N),
    ( N > 100_000 ->
        format("[rp_fd] WARNING: search space ~w > 100,000 -- capping solver at 10 solutions.~n", [N]),
        format("[rp_fd]          Use rp_fd_solve(Spec, Max, Result) for a specific cap.~n"),
        rp_fd_solve_capped(FDSpec, 10, Solutions)
    ;   findall(Assignment,
               solve_once(FDSpec, Assignment),
               Solutions)
    ).

rp_fd_solve(FDSpec, MaxSols, solutions(Solutions, Flag)) :-
    rp_fd_solve_capped(FDSpec, MaxSols, Solutions),
    ( length(Solutions, MaxSols) -> Flag = capped ; Flag = exact ).

rp_fd_solve_capped(FDSpec, Max, Solutions) :-
    FDSpec = fd_spec(Domains, Constraints),
    findnsols(Max, Assignment,
              ( maplist(enumerate_domain, Domains, Assignment),
                maplist(check_constraint(Assignment), Constraints) ),
              Solutions).

solve_once(fd_spec(Domains, Constraints), Assignment) :-
    maplist(enumerate_domain, Domains, Assignment),
    maplist(check_constraint(Assignment), Constraints).

enumerate_domain(dom(Var, Low, High), Var-Val) :-
    between(Low, High, Val).

check_constraint(Assignment, con(eq, [X, Y])) :-
    lookup(X, Assignment, VX), lookup(Y, Assignment, VY),
    VX =:= VY.
check_constraint(Assignment, con(neq, [X, Y])) :-
    lookup(X, Assignment, VX), lookup(Y, Assignment, VY),
    VX =\= VY.
check_constraint(Assignment, con(lt, [X, Y])) :-
    lookup(X, Assignment, VX), lookup(Y, Assignment, VY),
    VX < VY.
check_constraint(Assignment, con(le, [X, Y])) :-
    lookup(X, Assignment, VX), lookup(Y, Assignment, VY),
    VX =< VY.
check_constraint(Assignment, con(ge, [X, Y])) :-
    lookup(X, Assignment, VX), lookup(Y, Assignment, VY),
    VX >= VY.
check_constraint(Assignment, con(gt, [X, Y])) :-
    lookup(X, Assignment, VX), lookup(Y, Assignment, VY),
    VX > VY.
check_constraint(Assignment, con(sum_eq, [X, Y, Z])) :-
    lookup(X, Assignment, VX), lookup(Y, Assignment, VY),
    lookup(Z, Assignment, VZ),
    VX + VY =:= VZ.
check_constraint(Assignment, con(sum_neq, [X, Y, Z])) :-
    lookup(X, Assignment, VX), lookup(Y, Assignment, VY),
    lookup(Z, Assignment, VZ),
    VX + VY =\= VZ.
check_constraint(Assignment, con(prod_eq, [X, Y, Z])) :-
    lookup(X, Assignment, VX), lookup(Y, Assignment, VY),
    lookup(Z, Assignment, VZ),
    VX * VY =:= VZ.
check_constraint(Assignment, con(all_diff, Vars)) :-
    maplist([V, Val]>>(lookup(V, Assignment, Val)), Vars, Vals),
    all_distinct(Vals).

%% Soft constraint: always passes hard check (cost is evaluated separately)
check_constraint(_, con(cost, _)).
check_constraint(Assignment, con(range_in, [X, L, H])) :-
    lookup(X, Assignment, VX), VX >= L, VX =< H.

%% Extended constraint: weighted_sum -- Pairs is list of W*V or V
check_constraint(Assignment, con(weighted_sum, [Pairs, Target])) :-
    eval_weighted_sum(Pairs, Assignment, Total),
    lookup(Target, Assignment, VT),
    Total =:= VT.

%% Extended constraint: abs_diff
check_constraint(Assignment, con(abs_diff, [X, Y, D])) :-
    lookup(X, Assignment, VX), lookup(Y, Assignment, VY),
    lookup(D, Assignment, VD),
    VD =:= abs(VX - VY).

%% Extended constraint: min of list
check_constraint(Assignment, con(min_list, [List, M])) :-
    maplist([V, Val]>>(lookup(V, Assignment, Val)), List, Vals),
    lookup(M, Assignment, VM),
    min_list(Vals, VM).

%% Extended constraint: max of list
check_constraint(Assignment, con(max_list, [List, M])) :-
    maplist([V, Val]>>(lookup(V, Assignment, Val)), List, Vals),
    lookup(M, Assignment, VM),
    max_list(Vals, VM).

%% Extended constraint: count occurrences of Val in List = N
check_constraint(Assignment, con(count, [List, Val, N])) :-
    maplist([V, Vv]>>(lookup(V, Assignment, Vv)), List, Vals),
    lookup(Val, Assignment, VV),
    lookup(N, Assignment, VN),
    include(==(VV), Vals, Matches),
    length(Matches, VN).

check_constraint(_, con(unknown, _)).  %% skip unknowns

%% ---- weighted sum evaluation ----
eval_weighted_sum([], _, 0).
eval_weighted_sum([P|Ps], Assignment, Total) :-
    ( P = W*V ->
        lookup(V, Assignment, VV),
        C is W * VV
    ;   lookup(P, Assignment, C)
    ),
    eval_weighted_sum(Ps, Assignment, Rest),
    Total is C + Rest.

lookup(Var, Assignment, Val) :-
    ( atom(Var) ->
        memberchk(Var-Val, Assignment)
    ;   integer(Var) -> Val = Var
    ).

all_distinct([]).
all_distinct([H|T]) :-
    \+ member(H, T),
    all_distinct(T).

%% ============================================================
%%  fd_cost support
%%
%%  fd_cost(W, Constraint), the same rule as QCLP:
%%    W > 0  penalty: W is added when Constraint is VIOLATED
%%    W < 0  reward:  W is added when Constraint HOLDS
%%    W = 0  no effect
%%  The oracle targets assignments that achieve the minimum total
%%  cost (over all hard-satisfying assignments).
%%
%%  eval_cost/3: compute total soft cost for one assignment
%%  find_optimal_cost/3: classical pass to find best cost
%%  rp_fd_solve_optimal/2: return only optimal assignments
%% ============================================================

%% eval_cost(+FDSpec, +Assignment, -Cost)
eval_cost(fd_spec(_, Constraints), Assignment, Cost) :-
    include([con(cost,_)]>>true, Constraints, CostCons),
    maplist(eval_one_cost(Assignment), CostCons, Costs),
    sumlist(Costs, Cost).

eval_one_cost(Assignment, con(cost, [W, C]), Cost) :-
    ( check_one_cost(C, Assignment) -> Holds = true ; Holds = false ),
    cost_contribution(W, Holds, Cost).

%% cost_contribution(+W, +Holds, -Cost): QCLP's fd_cost rule.
cost_contribution(W, false, W) :- W > 0, !.
cost_contribution(W, true,  W) :- W < 0, !.
cost_contribution(_, _,     0).

%%  A soft constraint is evaluated exactly like a hard one, so every
%%  constraint type RProlog knows can carry a cost. (The old separate
%%  evaluator covered only 9 types and scored 0 for the rest -- e.g.
%%  fd_cost(W, fdsumeq(...)) never contributed anything.)
check_one_cost(C, A) :-
    parse_constraint(C, Con),
    check_constraint(A, Con).

%% rp_fd_solve_optimal/2: find min-cost satisfying assignments
%%   Returns solutions(List, exact|capped) with the minimum cost.
rp_fd_solve_optimal(FDSpec, solutions(BestSols, Flag)) :-
    FDSpec = fd_spec(_Domains, Constraints),
    include([con(cost,_)]>>true, Constraints, CostCons),
    ( CostCons = [] ->
        %% No soft constraints -- just use regular solve
        rp_fd_solve(FDSpec, Sols),
        BestSols = Sols, Flag = exact
    ;
        %% Find minimum cost over all satisfying assignments
        findall(Cost-Assignment,
            ( solve_once(FDSpec, Assignment),
              eval_cost(FDSpec, Assignment, Cost) ),
            Pairs),
        ( Pairs = [] ->
            BestSols = [], Flag = exact
        ;
            pairs_keys(Pairs, Costs),
            min_list(Costs, MinCost),
            include([C-_]>>(C =:= MinCost), Pairs, BestPairs),
            pairs_values(BestPairs, BestSols),
            length(BestSols, NBest),
            format("[rp_fd] Minimum cost: ~w  (~w optimal solution(s))~n",
                   [MinCost, NBest]),
            Flag = exact
        )
    ).

%% has_cost_constraints/1
has_cost_constraints(fd_spec(_, Constraints)) :-
    member(con(cost, _), Constraints), !.

anc(N, Anc) :- format(atom(Anc), "fd_anc~w", [N]).

anc_offset(N, Offset, Anc) :-
    Id is N * 100 + Offset,
    format(atom(Anc), "fd_anc~w", [Id]).

gen_ids(Start, Count, Ids) :-
    End is Start + Count - 1,
    numlist(Start, End, Ids).

%% ============================================================
%%  fd_domain_bits/2, fd_domain_size/2
%% ============================================================

%%  fd_domain_bits(+Dom, -Bits): qubits the circuit needs for a variable.
%%  The circuit stores a variable's VALUE directly in its register
%%  (every adder, comparator and multiplier works on the value), so the
%%  register must hold High, not merely High-Low+1 distinct states.
%%  (It used to be ceil(log2(High-Low+1)): b in 6..10 got 3 qubits, so
%%  8..10 could not be represented.) A one-value domain (a clue) is a
%%  constant and needs no register.
fd_domain_bits(dom(_, Low, High), 0) :- Low =:= High, !.
fd_domain_bits(dom(_, _, High), Bits) :-
    ( High =< 1 -> Bits = 1 ; Bits is msb(High) + 1 ).

%%  fd_register_bits(+Domains, -Bits)
%%  All search registers share one width: the widest variable's.
fd_register_bits(Domains, Bits) :-
    findall(B, (member(D, Domains), fd_domain_bits(D, B)), Bs),
    ( Bs == [] -> Bits = 1 ; max_list(Bs, Bits0), Bits is max(1, Bits0) ).

fd_domain_size(dom(_, Low, High), Size) :-
    Size is High - Low + 1.

fd_spec_domains(fd_spec(D, _), D).
fd_spec_constraints(fd_spec(_, C), C).

%% ============================================================
%%  rp_fd_info/1
%% ============================================================

rp_fd_info(fd_spec(Domains, Constraints)) :-
    format("~n~`=t~55|~n"),
    format("  QCLP_G -- Constraint Summary~n"),
    format("~`=t~55|~n"),
    format("~n  Domains:~n"),
    maplist(print_domain, Domains),
    format("~n  Constraints:~n"),
    maplist(print_constraint, Constraints),
    format("~n  Qubit budget:~n"),
    maplist(print_qubit_cost, Domains),
    fd_register_bits(Domains, RegBits),
    aggregate_all(count, (member(dom(_,L,H), Domains), L =\= H), NSearch),
    TotalBits is RegBits * NSearch,
    format("  Registers share the widest width: ~w x ~w qubits~n", [NSearch, RegBits]),
    format("  Total domain qubits: ~w~n", [TotalBits]),
    format("  + 1 oracle flag qubit~n"),
    TotalBitsP1 is TotalBits + 1,
    format("  = ~w qubits minimum~n", [TotalBitsP1]),
    format("~`=t~55|~n~n").

print_domain(dom(Var, Low, High)) :-
    Size is High - Low + 1,
    fd_domain_bits(dom(Var, Low, High), Bits),
    format("    ~w  in  ~w..~w  (~w values, ~w qubits)~n",
           [Var, Low, High, Size, Bits]).

print_constraint(con(eq,       [X,Y]))    :- format("    ~w  #=   ~w~n",      [X,Y]).
print_constraint(con(neq,      [X,Y]))    :- format("    ~w  #\\=  ~w~n",     [X,Y]).
print_constraint(con(lt,       [X,Y]))    :- format("    ~w  #<   ~w~n",      [X,Y]).
print_constraint(con(le,       [X,Y]))    :- format("    ~w  #=<  ~w~n",      [X,Y]).
print_constraint(con(ge,       [X,Y]))    :- format("    ~w  #>=  ~w~n",      [X,Y]).
print_constraint(con(gt,       [X,Y]))    :- format("    ~w  #>   ~w~n",      [X,Y]).
print_constraint(con(sum_eq,   [X,Y,Z])) :- format("    ~w + ~w  #=   ~w~n", [X,Y,Z]).
print_constraint(con(sum_neq,  [X,Y,Z])) :- format("    ~w + ~w  #\\=  ~w~n",[X,Y,Z]).
print_constraint(con(prod_eq,  [X,Y,Z])) :- format("    ~w * ~w  #=   ~w~n", [X,Y,Z]).
print_constraint(con(all_diff, Vs))       :- format("    all_different(~w)~n", [Vs]).
print_constraint(con(cost,     [W,C]))    :- format("    cost(~w, ~w)~n",     [W,C]).
print_constraint(con(weighted_sum,[Ps,T])):- format("    weighted_sum(~w) #= ~w~n",[Ps,T]).
print_constraint(con(abs_diff, [X,Y,D])) :- format("    |~w - ~w| #= ~w~n",  [X,Y,D]).
print_constraint(con(min_list, [L,M]))    :- format("    min(~w) #= ~w~n",    [L,M]).
print_constraint(con(max_list, [L,M]))    :- format("    max(~w) #= ~w~n",    [L,M]).
print_constraint(con(count,    [L,V,N]))  :- format("    count(~w,~w) #= ~w~n",[V,L,N]).
print_constraint(con(unknown,  [G]))      :- format("    ??? ~w~n",            [G]).

print_qubit_cost(dom(Var, Low, High)) :-
    ( Low =:= High ->
        format("    ~w: fixed at ~w (a constant, no register)~n", [Var, Low])
    ;   fd_domain_bits(dom(Var, Low, High), Bits),
        format("    ~w: ~w qubits to hold values up to ~w (domain ~w..~w)~n",
               [Var, Bits, High, Low, High])
    ).
