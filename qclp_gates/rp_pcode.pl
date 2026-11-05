%% ============================================================
%%  rp_pcode.pl  --  Oracle pcode interpreter
%%
%%  Evaluates oracle pcode (produced by rp_fd_oracle_mc/2)
%%  against a concrete variable assignment.
%%
%%  Pcode event types:
%%    next(Anc, Expr)         -- evaluate Expr into ancilla Anc
%%    flag_test(Anc, Kind)    -- succeed iff ancilla Anc passes Kind
%%
%%  Flag test kinds:
%%    neq_zero                -- Anc =/= 0
%%    eq_zero                 -- Anc =:= 0
%%    gt_zero                 -- Anc > 0
%%    ge_zero                 -- Anc >= 0
%%    eq_const(Val)           -- Anc =:= Val
%%
%%  The evaluation environment (Env) is an assoc mapping
%%  atom keys (variable and ancilla names) to integer values.
%%  Variables are seeded from the assignment; ancilla values
%%  are added as each next/2 event fires.
%%
%%  Public API:
%%    pcode_eval(+OracleMC, +Assignment)
%%      Succeeds iff all flag_test events pass.
%%      Assignment = list of Var-Val pairs (atoms to integers).
%%
%%    pcode_eval_trace(+OracleMC, +Assignment, -Trace)
%%      As pcode_eval/2 but returns Trace = list of
%%      event_result(Event, Env, passed/failed) terms.
%%      Always succeeds (even if the oracle rejects the assignment);
%%      useful for debugging and test harness.
%%
%%    pcode_flag_result(+MC, +Assignment, -Result)
%%      Result = solution | non_solution.
%%      Never throws; convenience wrapper for the test harness.
%%
%%    pcode_marks(+MC, +Widths, +Bits, +Assignment)
%%      The circuit's own verdict: evaluates the pcode in the circuit's
%%      fixed-width registers (see below). The fast simulator (run/1)
%%      uses this as its oracle.
%%
%%  pcode_eval/2 uses exact integer arithmetic: it checks that the
%%  microcode expresses the constraints (rp_pcode_test). pcode_marks/4
%%  checks what the CIRCUIT does with it.
%% ============================================================

:- module(rp_pcode, [
    pcode_eval/2,             %% pcode_eval(+MC, +Assignment)
    pcode_eval_trace/3,       %% pcode_eval_trace(+MC, +Assign, -Trace)
    pcode_flag_result/3,      %% pcode_flag_result(+MC, +Assign, -Result)
    pcode_pretty/1,           %% pcode_pretty(+MC)            -- print to current output
    pcode_pretty/2,           %% pcode_pretty(+MC, -Lines)    -- list of strings
    pcode_marks/4             %% pcode_marks(+MC, +Widths, +Bits, +Assign)
]).

:- use_module(library(assoc)).
:- use_module(library(lists)).


%% ============================================================
%%  pcode_eval(+OracleMC, +Assignment)
%%
%%  Succeeds iff the assignment satisfies all flag tests.
%%  Fails silently if any flag test fails (non-solution).
%% ============================================================

pcode_eval(MC, Assignment) :-
    pairs_to_assoc(Assignment, Env0),
    run_events(MC, Env0).

%%  run_events(+Events, +Env)
run_events([], _Env).
run_events([next(Anc, Expr) | Rest], Env0) :-
    eval_expr(Env0, Expr, Val),
    put_assoc(Anc, Env0, Val, Env1),
    run_events(Rest, Env1).
run_events([flag_test(Anc, Kind) | Rest], Env) :-
    get_assoc(Anc, Env, Val),
    check_flag(Kind, Val),
    run_events(Rest, Env).


%% ============================================================
%%  pcode_marks(+MC, +Widths, +Bits, +Assignment)
%%
%%  Evaluates the pcode exactly as the generated circuit computes it,
%%  so its verdict for a basis state is the circuit oracle's verdict:
%%
%%    * Every ancilla is a register of the width the circuit gives it
%%      (Widths = Anc-W pairs from rp_grover's anc_width_map/3); a
%%      search variable is Bits wide. Values are stored as unsigned
%%      W-bit patterns: a negative difference is its two's complement.
%%    * add, sub, xor: computed and reduced mod 2^W. Operands are used
%%      as stored, zero-extended (the circuit pads with |0> qubits).
%%    * mul: the multiplier is as wide as its widest operand (W/2,
%%      at least Bits) and writes a W-bit product.
%%    * Tests read the register bits: ge_zero = sign bit (bit W-1)
%%      clear; gt_zero = sign bit clear and not zero; eq_const(C)
%%      compares the low W bits of C; in_range(L, H) on the register.
%%
%%  Assignment: Var-Val pairs (register values, possibly outside the
%%  declared domains -- the circuit's registers can hold them).
%% ============================================================

pcode_marks(MC, Widths, Bits, Assignment) :-
    pairs_to_assoc(Assignment, Env0),
    fw_run(MC, Widths, Bits, Env0).

fw_run([], _, _, _).
fw_run([next(Anc, Expr)|Rest], Ws, Bits, Env0) :-
    fw_width(Anc, Ws, Bits, W),
    fw_expr(Expr, Ws, Bits, Env0, W, Val),
    put_assoc(Anc, Env0, Val, Env1),
    fw_run(Rest, Ws, Bits, Env1).
fw_run([flag_test(R, Kind)|Rest], Ws, Bits, Env) :-
    fw_val(R, Env, Val),
    fw_width(R, Ws, Bits, W),
    fw_flag(Kind, W, Val),
    fw_run(Rest, Ws, Bits, Env).

fw_width(R, Ws, _, W) :- memberchk(R-W, Ws), !.
fw_width(_, _, Bits, Bits).

fw_val(X, _, X) :- integer(X), !.
fw_val(X, Env, V) :- get_assoc(X, Env, V), !.
fw_val(X, _, _) :-                      % a compiler fault, never "not marked"
    throw(error(existence_error(pcode_value, X), pcode_marks/4)).

fw_expr(A * B, _Ws, _Bits, Env, W, V) :- !,
    fw_val(A, Env, VA), fw_val(B, Env, VB),
    Mb is (1 << (W // 2)) - 1,          % operands W/2 wide, product W
    V is ((VA /\ Mb) * (VB /\ Mb)) /\ ((1 << W) - 1).
fw_expr(E, _Ws, _Bits, Env, W, V) :-
    E =.. [Op, A, B],
    fw_val(A, Env, VA), fw_val(B, Env, VB),
    fw_op(Op, VA, VB, R),
    V is R /\ ((1 << W) - 1).

fw_op(+,   A, B, R) :- !, R is A + B.
fw_op(-,   A, B, R) :- !, R is A - B.
fw_op(xor, A, B, R) :- !, R is A xor B.
fw_op(Op,  _, _, _) :- throw(error(domain_error(pcode_operator, Op), pcode_marks/4)).

fw_flag(eq_zero,  _, V) :- V =:= 0.
fw_flag(neq_zero, _, V) :- V =\= 0.
fw_flag(ge_zero,  W, V) :- (V >> (W-1)) /\ 1 =:= 0.
fw_flag(gt_zero,  W, V) :- (V >> (W-1)) /\ 1 =:= 0, V =\= 0.
fw_flag(eq_const(C), _, V) :- integer(C), V =:= C.   % never true if C does not fit
fw_flag(in_range(L, H), _, V) :- V >= L, V =< H.
fw_flag(Kind, _, _) :-
    \+ memberchk(Kind, [eq_zero, neq_zero, ge_zero, gt_zero, eq_const(_), in_range(_, _)]),
    throw(error(domain_error(pcode_test, Kind), pcode_marks/4)).


%% ============================================================
%%  pcode_eval_trace(+OracleMC, +Assignment, -Trace)
%%
%%  Non-failing version that records each event outcome.
%%  Trace = list of traced_event(Event, Result) where
%%  Result = passed | failed | bound(Anc, Val).
%% ============================================================

pcode_eval_trace(MC, Assignment, Trace) :-
    pairs_to_assoc(Assignment, Env0),
    run_events_trace(MC, Env0, Trace).

run_events_trace([], _Env, []).
run_events_trace([next(Anc, Expr) | Rest], Env0,
                 [traced_event(next(Anc,Expr), bound(Anc,Val)) | Trace]) :-
    ( catch(eval_expr(Env0, Expr, Val), _, fail)
    ->  put_assoc(Anc, Env0, Val, Env1)
    ;   Val = error,
        Env1 = Env0
    ),
    run_events_trace(Rest, Env1, Trace).
run_events_trace([flag_test(Anc, Kind) | Rest], Env,
                 [traced_event(flag_test(Anc,Kind), FlagResult) | Trace]) :-
    ( get_assoc(Anc, Env, Val),
      check_flag(Kind, Val)
    ->  FlagResult = passed
    ;   FlagResult = failed
    ),
    run_events_trace(Rest, Env, Trace).


%% ============================================================
%%  pcode_flag_result(+MC, +Assignment, -Result)
%%
%%  Result = solution | non_solution.
%% ============================================================

pcode_flag_result(MC, Assignment, Result) :-
    ( pcode_eval(MC, Assignment)
    ->  Result = solution
    ;   Result = non_solution
    ).


%% ============================================================
%%  eval_expr(+Env, +Expr, -Val)
%%
%%  Evaluates a pcode arithmetic expression to an integer.
%%  Atoms are looked up in Env (variable or ancilla names).
%%  Integers evaluate to themselves.
%%  Compound terms are evaluated recursively then passed to is/2.
%%
%%  Supported operators (matching rp_fd expr_to_op/3):
%%    A + B,  A - B,  A * B,  A mod B,  A >> B,  A /\ B,  A xor B
%% ============================================================

eval_expr(Env, Expr, Val) :-
    ( integer(Expr) ->
        Val = Expr
    ; atom(Expr) ->
        get_assoc(Expr, Env, Val)
    ;
        eval_compound(Env, Expr, Val)
    ).

eval_compound(Env, A + B, Val) :-
    eval_expr(Env, A, VA), eval_expr(Env, B, VB), Val is VA + VB.
eval_compound(Env, A - B, Val) :-
    eval_expr(Env, A, VA), eval_expr(Env, B, VB), Val is VA - VB.
eval_compound(Env, A * B, Val) :-
    eval_expr(Env, A, VA), eval_expr(Env, B, VB), Val is VA * VB.
eval_compound(Env, A mod B, Val) :-
    eval_expr(Env, A, VA), eval_expr(Env, B, VB), Val is VA mod VB.
eval_compound(Env, A >> B, Val) :-
    eval_expr(Env, A, VA), eval_expr(Env, B, VB), Val is VA >> VB.
eval_compound(Env, A /\ B, Val) :-
    eval_expr(Env, A, VA), eval_expr(Env, B, VB), Val is VA /\ VB.
eval_compound(Env, A xor B, Val) :-
    eval_expr(Env, A, VA), eval_expr(Env, B, VB), Val is VA xor VB.


%% ============================================================
%%  check_flag(+Kind, +Val)
%%
%%  Succeeds iff Val satisfies Kind.
%% ============================================================

check_flag(neq_zero,    Val) :- Val =\= 0.
check_flag(eq_zero,     Val) :- Val =:= 0.
check_flag(gt_zero,     Val) :- Val > 0.
check_flag(ge_zero,     Val) :- Val >= 0.
check_flag(eq_const(C), Val) :-
    ( integer(C) -> CVal = C
    ; atom(C),
      nb_getval(rp_current_fdspec, fd_spec(Doms, _)),
      member(dom(C, CVal, CVal), Doms) -> true
    ; CVal = C
    ),
    Val =:= CVal.


%% ============================================================
%%  pairs_to_assoc(+Pairs, -Assoc)
%%
%%  Converts a Var-Val list to an assoc.
%%  Handles both Var-Val and Var=Val forms.
%% ============================================================

pairs_to_assoc(Pairs, Assoc) :-
    list_to_assoc_pairs(Pairs, [], KVs),
    list_to_assoc(KVs, Assoc).

list_to_assoc_pairs([], Acc, Acc).
list_to_assoc_pairs([K-V | Rest], Acc, Result) :-
    list_to_assoc_pairs(Rest, [K-V | Acc], Result).
list_to_assoc_pairs([K=V | Rest], Acc, Result) :-
    list_to_assoc_pairs(Rest, [K-V | Acc], Result).


%% ============================================================
%%  pcode_pretty/1, pcode_pretty/2
%%
%%  Renders pcode as readable pseudocode:
%%
%%    next(Anc, Expr)        -->  Anc := Expr
%%    flag_test(Anc, Kind)   -->  if <cond> then SOLUTION else reject
%%
%%  pcode_pretty(+MC)          prints directly (one line per event)
%%  pcode_pretty(+MC, -Lines)  returns a list of strings, one per event
%% ============================================================

pcode_pretty(MC) :-
    pcode_pretty(MC, Lines),
    forall(member(L, Lines), (write(L), nl)).

pcode_pretty(MC, Lines) :-
    maplist(pretty_event, MC, Lines).

pretty_event(next(Anc, Expr), Line) :-
    pretty_expr(Expr, ExprStr),
    format(string(Line), "  ~w := ~w", [Anc, ExprStr]).
pretty_event(flag_test(Anc, Kind), Line) :-
    pretty_flag(Kind, Anc, Cond),
    format(string(Line), "  if ~w then SOLUTION else reject", [Cond]).

%%  pretty_expr(+Expr, -String)
%%  Renders an arithmetic expression with infix operators and spaces.
pretty_expr(Expr, Str) :-
    ( atom(Expr) ; integer(Expr) ), !,
    format(string(Str), "~w", [Expr]).
pretty_expr(A + B, Str)   :- pretty_binop(A, "+",   B, Str).
pretty_expr(A - B, Str)   :- pretty_binop(A, "-",   B, Str).
pretty_expr(A * B, Str)   :- pretty_binop(A, "*",   B, Str).
pretty_expr(A mod B, Str) :- pretty_binop(A, "mod", B, Str).
pretty_expr(A >> B, Str)  :- pretty_binop(A, ">>",  B, Str).
pretty_expr(A /\ B, Str)  :- pretty_binop(A, "&",   B, Str).
pretty_expr(A xor B, Str) :- pretty_binop(A, "XOR", B, Str).

pretty_binop(A, OpStr, B, Str) :-
    pretty_expr(A, AStr), pretty_expr(B, BStr),
    format(string(Str), "~w ~w ~w", [AStr, OpStr, BStr]).

%%  pretty_flag(+Kind, +Anc, -CondString)
pretty_flag(neq_zero,    Anc, Cond) :- format(string(Cond), "~w != 0",  [Anc]).
pretty_flag(eq_zero,     Anc, Cond) :- format(string(Cond), "~w == 0",  [Anc]).
pretty_flag(gt_zero,     Anc, Cond) :- format(string(Cond), "~w > 0",   [Anc]).
pretty_flag(ge_zero,     Anc, Cond) :- format(string(Cond), "~w >= 0",  [Anc]).
pretty_flag(eq_const(C), Anc, Cond) :- format(string(Cond), "~w == ~w",[Anc, C]).
pretty_flag(in_range(L,H), Anc, Cond) :- format(string(Cond), "~w =< ~w =< ~w", [L, Anc, H]).
