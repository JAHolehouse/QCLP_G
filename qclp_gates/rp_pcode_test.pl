%% ============================================================
%%  rp_pcode_test.pl  --  pcode interpreter correctness tests
%%
%%  Verifies that pcode_eval/2 agrees with check_constraint/2
%%  for every assignment in the search space.
%%
%%  Strategy: for each test example, enumerate ALL assignments
%%  exhaustively.  For each assignment check both paths and
%%  compare.  Any disagreement is a bug in the pcode interpreter
%%  or in rp_fd_oracle_mc/2.
%%
%%  Usage:
%%    ?- rp_pcode_test.
%% ============================================================

:- module(rp_pcode_test, [rp_pcode_test/0]).

:- use_module(rp_fd).
:- use_module('../examples/generators', [fd_example/2]).
:- use_module(rp_pcode).
:- use_module(library(lists)).
:- use_module(library(apply)).


%% ============================================================
%%  Top-level entry point
%% ============================================================

rp_pcode_test :-
    format("~n============================================================~n"),
    format("  rp_pcode  CORRECTNESS TEST SUITE~n"),
    format("  Strategy: pcode_eval vs check_constraint, all assignments~n"),
    format("============================================================~n~n"),
    nb_setval(pcode_pass, 0),
    nb_setval(pcode_fail, 0),

    run_pcode_test("simple_neq",   simple_neq),
    run_pcode_test("sum_eq",       sum_eq),
    run_pcode_test("coloring(3)",  coloring(3)),
    run_pcode_test("queens(4)",    queens(4)),

    nb_getval(pcode_pass, P),
    nb_getval(pcode_fail, F),
    Total is P + F,
    format("~n============================================================~n"),
    ( F =:= 0
    ->  format("  ALL ~w TESTS PASSED~n", [Total])
    ;   format("  ~w passed,  ~w FAILED  (of ~w)~n", [P, F, Total])
    ),
    format("============================================================~n~n").


%% ============================================================
%%  run_pcode_test(+Label, +ExampleName)
%%
%%  For each test:
%%    1. Compile FDSpec from example
%%    2. Generate pcode (OracleMC)
%%    3. Enumerate all assignments in the search space
%%    4. Compare pcode_eval vs check_constraint for each
%%    5. Report summary
%% ============================================================

run_pcode_test(Label, ExampleName) :-
    format("  --- ~w ---~n", [Label]),
    fd_example(ExampleName, Goals),
    rp_fd_compile(Goals, FDSpec),
    FDSpec = fd_spec(Domains, Constraints),
    rp_fd_oracle_mc(FDSpec, OracleMC),

    %% Build domain map: list of Var-[Val0,Val1,...] for enumeration
    maplist(domain_vals, Domains, VarValLists),
    maplist([dom(V,_,_), V]>>true, Domains, Vars),

    %% Enumerate all assignments
    findall(Assignment,
        ( maplist([Var-Vals, Var-Val]>>(member(Val, Vals)),
                  VarValLists, Assignment) ),
        Assignments),
    length(Assignments, NTotal),

    %% Cross-check each assignment
    foldl(check_one(Constraints, OracleMC, Vars), Assignments,
          counts(0,0,0), counts(NSol, NNonSol, NMismatch)),

    ( NMismatch =:= 0
    ->  format("    ~w assignments: ~w solutions, ~w non-solutions  PASS~n",
               [NTotal, NSol, NNonSol]),
        N1 is NTotal,
        nb_getval(pcode_pass, P), P1 is P + N1, nb_setval(pcode_pass, P1)
    ;   format("    ~w MISMATCHES out of ~w assignments  FAIL~n",
               [NMismatch, NTotal]),
        nb_getval(pcode_fail, F), F1 is F + NMismatch, nb_setval(pcode_fail, F1)
    ).

domain_vals(dom(Var, Low, High), Var-Vals) :-
    numlist(Low, High, Vals).


%% ============================================================
%%  check_one(+Constraints, +OracleMC, +Vars, +Assignment,
%%            +CountsIn, -CountsOut)
%%
%%  Checks a single assignment against both paths.
%%  CountsIn/Out = counts(NSol, NNonSol, NMismatch).
%% ============================================================

check_one(Constraints, OracleMC, _Vars, Assignment,
          counts(NS, NN, NM), counts(NS1, NN1, NM1)) :-
    %% Path A: check_constraint
    ( maplist(check_constraint(Assignment), Constraints)
    ->  PathA = solution
    ;   PathA = non_solution
    ),

    %% Path B: pcode_eval
    pcode_flag_result(OracleMC, Assignment, PathB),

    %% Compare
    ( PathA == PathB
    ->  ( PathA == solution -> NS1 is NS+1 ; NS1 = NS ),
        ( PathA == non_solution -> NN1 is NN+1 ; NN1 = NN ),
        NM1 = NM
    ;   format("    MISMATCH: ~w  check=~w  pcode=~w~n",
               [Assignment, PathA, PathB]),
        NS1 = NS, NN1 = NN, NM1 is NM+1
    ).
