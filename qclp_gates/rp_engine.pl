%% ============================================================
%%  QCLP_G -- rp_engine.pl (formerly rprolog.pl)
%%  Core: compiler, interpreter, QASM Layer 2 generator
%%
%%  CHANGE LOG (Gemini review):
%%    - Fix 2: deref/3 chain dereferencing in theta_apply
%%    - Fix 3: list_to_set deduplication in QASM declarations
%%    - Fix 6: bounds check in rp_qasm (configurable bit width)
%% ============================================================

:- module(rp_engine, [
    rp_compile/3,       % +Goal, +Module, -Microcode
    rp_run/3,           % +Microcode, +ThetaIn, -ThetaOut
    rp_show/1,          % +Microcode
    rp_qasm/2,          % +Microcode, -QASMLines  (Layer 2)
    rp_qasm/3,          % +Microcode, +Bits, -QASMLines
    rp_theta_get/3,     % +Var, +Theta, -Val
    rp_theta_put/4,     % +Var, +Val, +Theta, -Theta
    rp_set_bits/1,      % +N  set register bit width (default 4)
    rp_get_bits/1,       % -N
    info/0
]).

%% ---- Configurable bit width (default 4) --------------------
:- dynamic rp_bits/1.
rp_bits(4).

rp_set_bits(N) :-
    integer(N), N > 0,
    retractall(rp_bits(_)),
    assertz(rp_bits(N)).

rp_get_bits(N) :- rp_bits(N).

%% ============================================================
%%  COMPILER
%% ============================================================

rp_compile(Goal, Mod, MC) :-
    compile_goal(Goal, Mod, MC, []).

compile_goal(V is Expr, _Mod, [next(V,Expr)|T], T) :- !.
compile_goal(X = Y,    _Mod, [unify(X,Y)|T],   T) :- !.
compile_goal(Goal, _Mod, [guard(Goal)|T], T) :-
    test_goal(Goal), !.
compile_goal((Cond->Then;Else), Mod, [ite(CMC,TMC,EMC)|T], T) :- !,
    compile_goal(Cond, Mod, CMC, []),
    compile_goal(Then, Mod, TMC, []),
    compile_goal(Else, Mod, EMC, []).
compile_goal((A,B), Mod, MC, T) :- !,
    compile_goal(A, Mod, MC, Mid),
    compile_goal(B, Mod, Mid, T).
compile_goal(true, _Mod, T, T) :- !.
compile_goal(Goal, Mod, MC, T) :-
    functor(Goal, Name, Arity),
    findall(L-H-B, numbered_clause(Mod,Name,Arity,L,H,B), Clauses),
    Clauses \= [], !,
    ( Clauses = [L1-H1-B1]
    ->  MC = [ch(L1),unf(Goal,L1)|BodyMC],
        copy_term(H1-B1, Goal-BInst),
        compile_body(BInst, Mod, BodyMC, [exit(Goal)|T])
    ;   compile_choices(Goal, Clauses, Mod, MC, T)
    ).
compile_goal(Goal, _Mod, [fail_ev(Goal)|T], T).

compile_choices(Goal, [L-H-B|_], Mod, MC, T) :-
    \+ \+ Goal = H, !,
    MC = [ch(L),unf(Goal,L)|BodyMC],
    copy_term(H-B, Goal-BInst),
    compile_body(BInst, Mod, BodyMC, [exit(Goal)|T]).
compile_choices(Goal, [_|Rest], Mod, MC, T) :-
    compile_choices(Goal, Rest, Mod, MC, T).

compile_body([], _Mod, T, T).
compile_body([G|Gs], Mod, MC, T) :-
    compile_goal(G, Mod, MC, Mid),
    compile_body(Gs, Mod, Mid, T).

test_goal(_ > _).  test_goal(_ < _).  test_goal(_ >= _).
test_goal(_ =< _). test_goal(_ =:= _). test_goal(_ =\= _).

numbered_clause(Mod, Name, Arity, L, Head, Body) :-
    functor(Head, Name, Arity),
    predicate_property(Mod:Head, defined),
    nth_clause(Mod:Head, L, Ref),
    clause(Mod:Head, RawBody, Ref),
    body_to_list(RawBody, Body).

body_to_list(true, []) :- !.
body_to_list((A,B), [A|R]) :- !, body_to_list(B, R).
body_to_list(G, [G]).

%% ============================================================
%%  INTERPRETER
%% ============================================================

rp_run([], Theta, Theta).
rp_run([E|Es], T0, TF) :-
    interp(E, T0, T1), !,
    rp_run(Es, T1, TF).

interp(ch(_),          T, T).
interp(unf(_,_),       T, T).
interp(exit(_),        T, T).
interp(fail_ev(G),     _, _) :- format("FAIL: ~w~n",[G]), fail.
interp(guard(Goal),    T, T) :- eval_test(Goal, T).

interp(unify(X, Y), T0, TF) :-
    deref(X, T0, VX),
    deref(Y, T0, VY),
    ( bindable(VX, T0) -> TF = [VX-VY|T0]
    ; bindable(VY, T0) -> TF = [VY-VX|T0]
    ; VX = VY, TF = T0
    ).

interp(next(V, Expr), T0, [V-Val|T0]) :-
    theta_apply(Expr, T0, Inst),
    Val is Inst.

interp(ite(CMC,TMC,EMC), T0, TF) :-
    ( rp_run(CMC, T0, _) -> rp_run(TMC, T0, TF)
    ;                        rp_run(EMC, T0, TF) ).

%% ---- Fix 2: proper chain dereferencing ----------------------
%%  Follows the substitution chain until a value or unbound var.
deref(X, T, Val) :-
    ( atom(X), \+ number(X), memberchk(X-Next, T)
    ->  deref(Next, T, Val)
    ; var(X), memberchk(X-Next, T)
    ->  deref(Next, T, Val)
    ;   Val = X
    ).

theta_apply(X, T, V) :-
    ( var(X)    -> deref(X, T, V)
    ; number(X) -> V = X
    ; atom(X)   -> deref(X, T, V)
    ; X =.. [F|Args],
      maplist(theta_apply_arg(T), Args, VArgs),
      V =.. [F|VArgs]
    ).
theta_apply_arg(T, A, V) :- theta_apply(A, T, V).

bindable(V, T) :-
    atom(V), \+ number(V), \+ memberchk(V-_, T).

eval_test(X>Y,   T) :- theta_apply(X,T,A), theta_apply(Y,T,B), A>B.
eval_test(X<Y,   T) :- theta_apply(X,T,A), theta_apply(Y,T,B), A<B.
eval_test(X>=Y,  T) :- theta_apply(X,T,A), theta_apply(Y,T,B), A>=B.
eval_test(X=<Y,  T) :- theta_apply(X,T,A), theta_apply(Y,T,B), A=<B.
eval_test(X=:=Y, T) :- theta_apply(X,T,A), theta_apply(Y,T,B), A=:=B.
eval_test(X=\=Y, T) :- theta_apply(X,T,A), theta_apply(Y,T,B), A=\=B.

rp_theta_get(Var, Theta, Val) :- deref(Var, Theta, Val).
rp_theta_put(Var, Val, Theta, [Var-Val|Theta]).

%% ============================================================
%%  PRETTY PRINTER
%% ============================================================

rp_show([]).
rp_show([E|Es]) :- show_ev(E), rp_show(Es).

show_ev(ch(L))        :- format("  ch(~w)~n",[L]).
show_ev(unf(G,L))     :- format("  unf(~w, ~w)~n",[G,L]).
show_ev(next(V,E))    :- format("  next(~w, ~w)~n",[V,E]).
show_ev(guard(G))     :- format("  guard(~w)~n",[G]).
show_ev(flag_test(Anc, Kind)) :-
    format("  flag_test(~w, ~w)~n", [Anc, Kind]).
show_ev(unify(X,Y))   :- format("  unify(~w, ~w)~n",[X,Y]).
show_ev(exit(G))      :- format("  exit(~w)~n",[G]).
show_ev(fail_ev(G))   :- format("  fail(~w)~n",[G]).
show_ev(ite(C,Th,El)) :-
    format("  ite(~n"),
    format("    cond:  "), rp_show(C),
    format("    then:  "), rp_show(Th),
    format("    else:  "), rp_show(El),
    format("  )~n").

%% ============================================================
%%  QASM3 GENERATOR  (Layer 2 -- named ops)
%%
%%  Fix 3: deduplicate register declarations with list_to_set
%%  Fix 6: bounds check -- warn if values exceed 2^n - 1
%% ============================================================

rp_qasm(MC, Lines) :-
    rp_bits(N),
    rp_qasm(MC, N, Lines).

rp_qasm(MC, Bits, Lines) :-
    collect_next(MC, Nexts),
    bounds_check(Nexts, Bits),
    header(HL),
    decls(Nexts, DL),           % now deduplicated
    fwd_gates(Nexts, FwdL),
    copy_out(Nexts, CpL),
    reverse(Nexts, Rev),
    fwd_gates(Rev, UncL),
    append([HL, DL,
            ["","// === compute ==="],   FwdL,
            CpL,
            ["","// === uncompute (Bennett) ==="], UncL,
            ["// end"]], Lines).

%% ---- Fix 6: bounds checking --------------------------------
bounds_check(Nexts, Bits) :-
    Max is (1 << Bits) - 1,
    forall(
        ( member(next(_,Expr), Nexts),
          ground(Expr),
          catch(V is Expr, _, fail),
          integer(V) ),
        ( V > Max
        -> format("WARNING: value ~w exceeds ~w-bit range (max ~w)~n",
                  [V, Bits, Max])
        ;  true )
    ).

%% ---- Fix 3: deduplicated declarations ----------------------
collect_next([], []).
collect_next([next(V,E)|T], [next(V,E)|R]) :- !, collect_next(T,R).
collect_next([ite(_,TMC,EMC)|T], R) :- !,
    collect_next(TMC, RT), collect_next(EMC, RE),
    collect_next(T, Rest),
    append(RT, RE, RTE), append(RTE, Rest, R).
collect_next([_|T], R) :- collect_next(T,R).

header(["OPENQASM 3.0;","include \"stdgates.inc\";",
        "// Generated by QCLP_G",""]).

decls(Nexts, Lines) :-
    maplist([next(V,_),V]>>true, Nexts, Vars),
    list_to_set(Vars, UniqueVars),          %% Fix 3
    maplist(decl_ln, UniqueVars, VarLines),
    append(VarLines, ["qubit[n] result;",""], Lines).

decl_ln(V, L) :- format(atom(L),"qubit[n] ~w;",[V]).

fwd_gates(Nexts, Lines) :- maplist(gate_line, Nexts, Lines).

gate_line(next(V, A xor B), L) :-
    format(atom(L),"cx ~w, ~w; cx ~w, ~w;  // ~w = ~w xor ~w",[A,V,B,V,V,A,B]).
gate_line(next(V, A + B), L) :-
    format(atom(L),"rev_add ~w, ~w -> ~w;  // ~w = ~w + ~w",[A,B,V,V,A,B]).
gate_line(next(V, A - B), L) :-
    format(atom(L),"rev_sub ~w, ~w -> ~w;  // ~w = ~w - ~w",[A,B,V,V,A,B]).
gate_line(next(V, A * B), L) :-
    format(atom(L),"rev_mul ~w, ~w -> ~w;  // ~w = ~w * ~w",[A,B,V,V,A,B]).
gate_line(next(V, A mod B), L) :-
    format(atom(L),"rev_mod ~w, ~w -> ~w;  // ~w = ~w mod ~w",[A,B,V,V,A,B]).
gate_line(next(V, A // B), L) :-
    format(atom(L),"rev_div ~w, ~w -> ~w;  // ~w = ~w // ~w",[A,B,V,V,A,B]).
gate_line(next(V, A >> B), L) :-
    format(atom(L),"rev_shr ~w, ~w -> ~w;  // ~w = ~w >> ~w",[A,B,V,V,A,B]).
gate_line(next(V, A /\ B), L) :-
    format(atom(L),"rev_and ~w, ~w -> ~w;  // ~w = ~w /\\ ~w",[A,B,V,V,A,B]).
gate_line(next(V, _), L) :-
    format(atom(L),"// complex expr -> ~w",[V]).

copy_out([], ["// (no arithmetic output)"]) :- !.
copy_out(Nexts, ["","// === copy output ===",CL,""]) :-
    last(Nexts, next(LastV,_)),
    format(atom(CL),"cx ~w, result;  // copy output",[LastV]).

%% ============================================================
%%  Welcome banner
%% ============================================================
info :- format("~n~`=t~60|~n"),
   format("  QCLP_G -- Core Quantum Compiler Engine~n"),
   format("~`=t~60|~n~n"),
   format("  COMMAND INTERFACE (the supported way to interact)~n"),
   format("    help.                            full command list~n"),
   format("    run('clp/queens4.clp').         Grover search, fast simulator~n"),
   format("    solve('clp/queens4.clp').       classical reference solver~n"),
   format("    export('clp/queens4.clp', F).   write .qasm file~n~n"),
   format("  GENERATING .clp FILES (separate tool, not loaded here)~n"),
   format("    ?- ['examples/generators'].~n"),
   format("    ?- gen_clp(factor(15), 'examples/factor15.clp').~n~n"),
   format("  STATEVECTOR SIMULATOR~n"),
   format("    qsim_run(\"circuit.qasm\")    simulate~n"),
   format("    qsim_run(F, [shots(N)])     sample N times~n~n"),
   format("  STATEVECTOR SIMULATOR (expand first in QASM3 macro expander~n"),
   format("    qasm3_expand_and_run('qasm/factor15.qasm', [shots(100)]).     sample 100 times~n~n"),
   format("  TEST SUITE~n"),
   format("    rp_test.                    run all fast tests~n~n"),
   format("~`=t~60|~n~n").
