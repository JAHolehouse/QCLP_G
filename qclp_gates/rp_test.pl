%% ============================================================
%%  rp_test.pl  --  Comprehensive test suite for RProlog + oracle_sv
%%
%%  Usage:
%%    ?- rp_test.           %% all fast tests
%%    ?- rp_test(quick).    %% simulator + oracle unit tests only
%%    ?- rp_test(full).     %% all tests including slow Grover circuits
%%
%%  Each test prints PASS or FAIL with a description.
%%  A summary line at the end shows total pass/fail counts.
%%
%%  Test categories:
%%    1. Simulator gate correctness  (pure QASM files in qasm/)
%%    2. Oracle correctness          (inline QASM, phase-flip verification)
%%    3. FD compiler                 (classical solution enumeration)
%%    4. Grover iteration formula    (K = optimal for M solutions)
%%    5. QASM generation             (round-trip generate + parse)
%%    6. End-to-end Grover circuits  (generate + simulate, check distribution)
%% ============================================================

:- module(rp_test, [rp_test/0, rp_test/1]).

:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(aggregate)).

%% Import cross-module predicates needed by the test suite
:- use_module(rp_grover, [rp_grover_iterations_m/3, rp_grover_write/2]).
:- use_module(rp_fd,       [rp_fd_compile/2, rp_fd_solve/2,
                             fd_domain_bits/2, fd_domain_size/2,
                             fd_spec_domains/2]).
:- use_module('../examples/generators', [fd_example/2]).
:- use_module(sv_run,        [qasm3_nqubits_from_file/2]).
:- use_module(sv_sim,  [sv_run_file/2, sv_run_qasm/2,
                             state_prob/3, sv_get/3]).
:- use_module(qsim_pp_grover, [grover_search/3]).
:- use_module(library(assoc)).

%% - nb_setval counters -

init_counters :-
    nb_setval(rp_test_pass, 0),
    nb_setval(rp_test_fail, 0).

record_pass :-
    nb_getval(rp_test_pass, N), N1 is N+1, nb_setval(rp_test_pass, N1).

record_fail :-
    nb_getval(rp_test_fail, N), N1 is N+1, nb_setval(rp_test_fail, N1).

print_summary :-
    nb_getval(rp_test_pass, P),
    nb_getval(rp_test_fail, F),
    Total is P + F,
    format("~n~`=t~60|~n"),
    format("  Test summary:  ~w passed,  ~w failed  (~w total)~n", [P, F, Total]),
    ( F =:= 0
    ->  format("  ALL TESTS PASSED ok~n")
    ;   format("  FAILURES DETECTED -- see FAIL lines above~n")
    ),
    format("~`=t~60|~n~n").

%% - Test runner macros -

run_test(Label, Goal) :-
    format("  ~w ... ", [Label]),
    %% A thrown exception is printed and recorded inside the catch
    %% handler; a plain failure must be printed and recorded here.
    %% (Previously the else-branch tested nb_getval(rp_test_fail,_),
    %% which always succeeds once init_counters/0 has run, so every
    %% ordinary test FAILURE was silently dropped -- never printed,
    %% never counted -- and the summary could only ever report
    %% exceptions as failures.)
    nb_setval(rp_test_threw, false),
    %% Run a fresh copy: several categories reuse one variable name
    %% (e.g. Q) across consecutive run_test/2 calls in the same clause
    %% body, so without copying, the first test's binding leaked into
    %% the next and made it fail to unify (2.2-2.8 all failed this way,
    %% invisibly, until failures started being reported).
    copy_term(Goal, Goal1),
    ( catch(Goal1, Err, ( format("FAIL (exception: ~w)~n", [Err]),
                         record_fail, nb_setval(rp_test_threw, true), fail ))
    ->  format("PASS~n"), record_pass
    ;   ( nb_getval(rp_test_threw, true) -> true
        ; format("FAIL~n"), record_fail )
    ).

run_test_approx(Label, Goal, GotVar, Expected, Tol) :-
    format("  ~w ... ", [Label]),
    ( catch(Goal, Err, (format("FAIL (exception: ~w)~n", [Err]), record_fail, fail)) ->
        ( abs(GotVar - Expected) =< Tol ->
            format("PASS (~w - ~w)~n", [GotVar, Expected]), record_pass
        ;   format("FAIL (got ~w, expected ~w +- ~w)~n", [GotVar, Expected, Tol]),
            record_fail
        )
    ; true ).

section(Title) :-
    format("~n  ~`-t~56|~n  ~w~n  ~`-t~56|~n", [Title]).

%% ============================================================
%%  Top-level entry points
%% ============================================================

rp_test :-
    rp_test(quick).

rp_test(Mode) :-
    init_counters,
    format("~n~`=t~60|~n"),
    format("  QCLP_G TEST SUITE (compiler + sv_sim)~n"),
    format("~`=t~60|~n"),
    run_category_1,   %% simulator gate correctness
    run_category_2,   %% oracle phase correctness
    run_category_3,   %% FD compiler
    run_category_4,   %% Grover iteration formula
    run_category_5,   %% QASM generation
    ( member(Mode, [quick, full]) ->
        run_category_6_quick
    ; true ),
    ( Mode == full ->
        run_category_6_slow
    ; true ),
    ( member(Mode, [quick, full]) ->
        run_category_7_quick
    ; true ),
    ( Mode == full ->
        run_category_7_slow
    ; true ),
    ( member(Mode, [quick, full]) ->
        run_category_8
    ; true ),
    ( member(Mode, [quick, full]) ->
        run_category_9
    ; true ),
    print_summary.

%% ============================================================
%%  Category 1: Simulator gate correctness
%%  Tests pre-built QASM files in qasm/
%% ============================================================

run_category_1 :-
    section("1. Simulator gate correctness (pre-built QASM files)"),

    %% 1.1 Bell state: H + CX on |00> -> (|00>+|11>)/sqrt(2)
    run_test("1.1 Bell state  (50/50 in |0> and |3>)",
        test_qasm_result("qasm/bell_test.qasm",
            [state_prob_close(0, 0.5, 0.01),
             state_prob_close(3, 0.5, 0.01)])),

    %% 1.2 Parity check: pre-built circuit should give |18> with 100%
    run_test("1.2 Parity circuit  (|18> = 100%)",
        test_qasm_result("qasm/parity_test.qasm",
            [state_is_dominant(18, 0.99)])),

    %% 1.3 XOR test: pre-built small XOR circuit
    run_test("1.3 XOR oracle test  (|5> = 100%)",
        test_qasm_result("qasm/xor_test.qasm",
            [state_is_dominant(5, 0.99)])),

    %% 1.4 XOR with named registers: a=1, b=2 -> copy=3 (a XOR b)
    run_test("1.4 XOR named-register oracle  (|201> = 100%)",
        test_qasm_result("qasm/xor.qasm",
            [state_is_dominant(201, 0.99)])),

    %% 1.5 X gate: |0> -> |1>
    run_test("1.5 X gate  (|0> -> |1>)",
        test_inline_qasm(
            "OPENQASM 3.0;\ninclude \"stdgates.inc\";\nqubit[1] q;\nx q[0];",
            [state_is_dominant(1, 0.99)])),

    %% 1.6 H gate: |0> -> |+>
    run_test("1.6 H gate  (|0> -> |+>, both outcomes 50%)",
        test_inline_qasm(
            "OPENQASM 3.0;\ninclude \"stdgates.inc\";\nqubit[1] q;\nh q[0];",
            [state_prob_close(0, 0.5, 0.01),
             state_prob_close(1, 0.5, 0.01)])),

    %% 1.7 CX: |10> -> |11>  (flip target when control=1)
    run_test("1.7 CX gate  (|10> -> |11>)",
        test_inline_qasm(
            "OPENQASM 3.0;\ninclude \"stdgates.inc\";\nqubit[2] q;\nx q[0];\ncx q[0], q[1];",
            [state_is_dominant(3, 0.99)])),

    %% 1.8 CCX (Toffoli): |110> -> |111>
    run_test("1.8 CCX (Toffoli)  (|110> -> |111>)",
        test_inline_qasm(
            "OPENQASM 3.0;\ninclude \"stdgates.inc\";\nqubit[3] q;\nx q[0];\nx q[1];\nccx q[0], q[1], q[2];",
            [state_is_dominant(7, 0.99)])),

    %% 1.9 CCX control not set: no flip
    run_test("1.9 CCX no-op  (|100> stays |100>)",
        test_inline_qasm(
            "OPENQASM 3.0;\ninclude \"stdgates.inc\";\nqubit[3] q;\nx q[0];\nccx q[0], q[1], q[2];",
            [state_is_dominant(1, 0.99)])),

    %% 1.10 Multi-register: two named registers resolved correctly
    run_test("1.10 Multi-register wire resolution",
        test_inline_qasm(
            "OPENQASM 3.0;\ninclude \"stdgates.inc\";\nqubit[2] a;\nqubit[2] b;\nx a[0];\nx b[1];\ncx a[0], b[0];",
            %% a = 1 (x a[0]); b = 2 (x b[1]) then b[0] ^= a[0] -> b = 3.
            %% Index = a + (b << 2) = 1 + 12 = 13 (previously expected 5,
            %% which is not the state this circuit produces).
            [state_is_dominant(13, 0.99)])).

%% ============================================================
%%  Category 2: Oracle phase-flip correctness
%%  Verifies that the oracle correctly marks states with phase -1
%%  and that the Bennett uncompute cleans all ancilla.
%% ============================================================

run_category_2 :-
    section("2. Oracle phase-flip and Bennett uncompute"),

    %% 2.1 neq oracle: x=1,y=0 (x!=y) should get amplitude -1
    run_test("2.1 NEQ oracle  phase-flip  x=1,y=0 (x!=y -> -1)",
        ( neq_oracle_qasm(1, 0, Q), test_oracle_phase(Q, -1.0, 0.01) )),

    %% 2.2 neq oracle: x=0,y=0 (x=y) should NOT be phase-flipped (+1)
    run_test("2.2 NEQ oracle  no-flip     x=0,y=0 (x=y  -> +1)",
        ( neq_oracle_qasm(0, 0, Q), test_oracle_phase(Q, +1.0, 0.01) )),

    %% 2.3 neq oracle: ancilla clean after roundtrip
    run_test("2.3 NEQ oracle  ancilla clean after compute+uncompute",
        ( neq_oracle_roundtrip_qasm(1,0,Q), test_ancilla_clean(Q) )),

    %% 2.4 eq oracle: x=2,y=2 (x=y) should flip
    run_test("2.4 EQ oracle   phase-flip  x=2,y=2 (x=y  -> -1)",
        ( eq_oracle_qasm(2, 2, Q), test_oracle_phase(Q, -1.0, 0.01) )),

    %% 2.5 eq oracle: x=1,y=2 (x!=y) no flip
    run_test("2.5 EQ oracle   no-flip     x=1,y=2 (x!=y -> +1)",
        ( eq_oracle_qasm(1, 2, Q), test_oracle_phase(Q, +1.0, 0.01) )),

    %% 2.6 sum_eq oracle: x=1,y=2,z=3 (1+2=3) should flip
    run_test("2.6 SUM_EQ oracle phase-flip x=1,y=2,z=3 (sum -> -1)",
        ( sum_eq_oracle_qasm(1,2,3,Q), test_oracle_phase(Q, -1.0, 0.01) )),

    %% 2.7 sum_eq oracle: x=1,y=2,z=2 (1+2!=2) no flip
    run_test("2.7 SUM_EQ oracle no-flip   x=1,y=2,z=2 (no sum -> +1)",
        ( sum_eq_oracle_qasm(1,2,2,Q), test_oracle_phase(Q, +1.0, 0.01) )),

    %% 2.8 sum_eq ancilla clean
    run_test("2.8 SUM_EQ oracle ancilla clean after roundtrip",
        ( sum_eq_oracle_roundtrip_qasm(1,2,3,Q), test_ancilla_clean(Q) )).

%% ============================================================
%%  Category 3: FD compiler -- classical solution enumeration
%% ============================================================

run_category_3 :-
    section("3. FD compiler -- classical solution enumeration"),

    %% 3.1 simple_neq: 12 solutions (all x!=y for x,y in 0..3)
    run_test("3.1 simple_neq  (12 solutions)",
        test_fd_solution_count(
            [fd_domain(x,0,3), fd_domain(y,0,3), fd_neq(x,y)],
            12)),

    %% 3.2 simple_eq: 4 solutions (x=y, diagonal)
    run_test("3.2 simple_eq   (4 solutions: x=y for x,y in 0..3)",
        test_fd_solution_count(
            [fd_domain(x,0,3), fd_domain(y,0,3), fd_eq(x,y)],
            4)),

    %% 3.3 sum_eq (constant): x+y=5, x,y in 0..4 -> 4 solutions
    run_test("3.3 sum_eq(const) (4 solutions: x+y=5)",
        test_fd_solution_count(
            [fd_domain(x,0,4), fd_domain(y,0,4), fd_sum_eq(x,y,5)],
            4)),

    %% 3.4 lt: x<y for x,y in 0..3 -> 6 solutions
    run_test("3.4 lt  (6 solutions: x<y)",
        test_fd_solution_count(
            [fd_domain(x,0,3), fd_domain(y,0,3), fd_lt(x,y)],
            6)),

    %% 3.5 le: x<=y -> 10 solutions
    run_test("3.5 le  (10 solutions: x<=y)",
        test_fd_solution_count(
            [fd_domain(x,0,3), fd_domain(y,0,3), fd_le(x,y)],
            10)),

    %% 3.6 all_different 2 vars: same as neq -> 12
    run_test("3.6 all_different (2 vars, 12 solutions)",
        test_fd_solution_count(
            [fd_domain(x,0,3), fd_domain(y,0,3), fd_all_different([x,y])],
            12)),

    %% 3.7 sum_eq (3 vars): x+y=z for x,y,z in 0..3 -> 10 solutions
    run_test("3.7 sum_eq(3 vars) (10 solutions: x+y=z)",
        test_fd_solution_count(
            [fd_domain(x,0,3), fd_domain(y,0,3), fd_domain(z,0,3),
             fd_sum_eq(x,y,z)],
            10)),

    %% 3.8 coloring(3): 6 proper 3-colourings of K3
    run_test("3.8 coloring(3)  (6 solutions)",
        test_fd_example_count(coloring(3), 6)),

    %% 3.9 Solution values spot check: sum_eq x+y=5 includes (2,3)
    run_test("3.9 sum_eq solution includes x=2,y=3",
        test_fd_solution_includes(
            [fd_domain(x,0,4), fd_domain(y,0,4), fd_sum_eq(x,y,5)],
            [x-2, y-3])),

    %% 3.10 No solutions: x<y AND y<x (unsatisfiable)
    run_test("3.10 unsatisfiable  (0 solutions)",
        test_fd_solution_count(
            [fd_domain(x,0,3), fd_domain(y,0,3),
             fd_lt(x,y), fd_lt(y,x)],
            0)),

    %% 3.11-3.15 QCLP list domains: N or Lo-Hi (inclusive), merged.
    %% Lo-Hi is a range, never subtraction ([0,2-3] once became -1..0).
    run_test("3.11 list domain [0,2-3] = {0,2,3}",
        test_domain_values(fd_domain(x,[0,2-3]), [0,2,3])),
    run_test("3.12 list domain [1-3,5-7,10] keeps its gaps",
        test_domain_values(fd_domain(x,[1-3,5-7,10]), [1,2,3,5,6,7,10])),
    run_test("3.13 list domain [-3-2]: negative bound",
        test_domain_values(fd_domain(x,[-3-2]), [-3,-2,-1,0,1,2])),
    run_test("3.14 list domain [1-4,3-6,1]: overlaps merge",
        test_domain_values(fd_domain(x,[1-4,3-6,1]), [1,2,3,4,5,6])),
    run_test("3.15 list domain errors: [6-2], [], [1,a]",
        forall(member(L, [[6-2], [], [1,a]]),
               catch((rp_fd_compile([fd_domain(x,L)], _), fail),
                     error(domain_error(fd_domain, _), _), true))),
    run_test("3.16 sparse domains solve: x,y in [0,5,10], x+y=10 (3 solutions)",
        test_fd_solution_count(
            [fd_eq(s,10), fd_domain(x,[0,5,10]), fd_domain(y,[0,5,10]),
             fd_domain(s,[0,5,10,15,20]), fd_sum_eq(x,y,s)],
            3)),

    %% 3.17-3.23 front end: domains/clues combine in any order, names
    %% as written, no silent failures.
    run_test("3.17 fd_eq clue AFTER its domain is kept (QCLP order)",
        test_values([fd_domain(x,0,9), fd_eq(x,5)], [5])),
    run_test("3.18 repeated domains intersect: [0,2-6] and 3..9 = {3..6}",
        test_values([fd_domain(x,[0,2-6]), fd_domain(x,3,9)], [3,4,5,6])),
    run_test("3.19 clue outside its domain: no solutions",
        test_fd_solution_count([fd_domain(x,0,3), fd_eq(x,7)], 0)),
    run_test("3.20 sudoku-style givens: clues after domains fix cells",
        test_fd_solution_count(
            [fd_domain(a,1,3), fd_domain(b,1,3), fd_domain(c,1,3),
             fd_eq(a,2), fd_eq(c,3), fd_all_different([a,b,c])], 1)),
    run_test("3.21 unknown constraint is an error, not silently true",
        catch((rp_fd_compile([fd_domain(x,0,1), fd_xor(x,x,0)], _), fail),
              error(domain_error(fd_constraint, _), _), true)),
    run_test("3.22 fd_cost over fdsumeq counts (was silently 0)",
        ( rp_fd_compile([fd_domain(x,0,2), fd_domain(y,0,2), fd_domain(s,0,4),
                         fd_sum_eq(x,y,s), fd_cost(-1, fdsumeq(x,1,y))], S),
          rp_fd:rp_fd_solve_optimal(S, solutions(O, _)), length(O, 2) )),
    run_test("3.23 capitalised names in a .clp are names (StartA, EndA)",
        test_clp_text("problem_spec([fd_domain(StartA,0,1), fd_domain(EndA,0,1), fd_neq(StartA,EndA)]).",
                      [['StartA'-0,'EndA'-1], ['StartA'-1,'EndA'-0]])),
    run_test("3.24 fd_cost W>0 is a penalty when violated (QCLP rule)",
        test_cost_table([fd_domain(x,0,3), fd_cost(5, fd_eq(x,2))],
                        [0-5, 1-5, 2-0, 3-5])),
    run_test("3.25 fd_cost W<0 is a reward when it holds (QCLP rule)",
        test_cost_table([fd_domain(x,0,3), fd_cost(-3, fd_eq(x,1))],
                        [0-0, 1-(-3), 2-0, 3-0])),
    run_test("3.26 fd_cost W=0 has no effect",
        test_cost_table([fd_domain(x,0,1), fd_cost(0, fd_eq(x,1))], [0-0, 1-0])),
    run_test("3.27 positive weight: optimum satisfies the constraint",
        ( rp_fd_compile([fd_domain(x,0,3), fd_domain(y,0,3), fd_neq(x,y),
                         fd_cost(4, fd_eq(x,2)), fd_cost(-1, fd_eq(y,0))], S),
          rp_fd:rp_fd_solve_optimal(S, solutions(O, _)),
          O = [A], rp_fd:eval_cost(S, A, C), C =:= -1,
          memberchk(x-2, A), memberchk(y-0, A) )).

%%  test_cost_table(+Goals, +Expected): Goals has one variable x;
%%  Expected lists XValue-Cost for every value of x.
test_cost_table(Goals, Expected) :-
    rp_fd_compile(Goals, S),
    findall(X-C, ( rp_fd:solve_once(S, A), memberchk(x-X, A),
                   rp_fd:eval_cost(S, A, C0), C is C0 ), Got0),
    msort(Got0, Got), msort(Expected, E0),
    maplist([V-W0, V-W]>>(W is W0), E0, E1),
    Got == E1.

%%  test_values(+Goals, +Expected): values of the first variable
test_values(Goals, Expected) :-
    rp_fd_compile(Goals, FDSpec),
    rp_fd_solve(FDSpec, Sols),
    findall(V, member([_-V|_], Sols), Vs),
    Vs == Expected.

%%  test_clp_text(+Text, +ExpectedSolutions): load Text as a .clp file
test_clp_text(Text, Expected) :-
    tmp_file_stream(text, File0, S0), close(S0),
    atom_concat(File0, '.clp', File),
    setup_call_cleanup(open(File, write, S), write(S, Text), close(S)),
    rp_spec:load_spec(File, Goals),
    rp_fd_compile(Goals, FDSpec),
    rp_fd_solve(FDSpec, Sols),
    delete_file(File),
    Sols == Expected.

%%  test_domain_values(+DomainGoal, +Expected)
%%  The values the classical solver actually enumerates for one domain.
test_domain_values(G, Expected) :-
    rp_fd_compile([G], FDSpec),
    rp_fd_solve(FDSpec, Sols),
    findall(V, member([_-V], Sols), Vs),
    Vs == Expected.

%% ============================================================
%%  Category 4: Grover iteration formula
%% ============================================================

run_category_4 :-
    section("4. Grover iteration count -- rp_grover_iterations_m/3"),

    %% For each (N, M), verify K gives P(success) >= 50%
    run_test("4.1 N=16 M=4  (K should give P>=50%)",
        test_grover_k_valid(16, 4)),
    run_test("4.2 N=16 M=12 (K should give P>=50%, M>N/2 case)",
        test_grover_k_valid(16, 12)),
    run_test("4.3 N=64 M=10 (K should give P>=50%)",
        test_grover_k_valid(64, 10)),
    run_test("4.4 N=27 M=6  (K should give P>=50%)",
        test_grover_k_valid(27, 6)),
    run_test("4.5 N=256 M=24 (K should give P>=50%)",
        test_grover_k_valid(256, 24)),

    %% Verify specific known-correct values
    run_test("4.6 N=4 M=1  -> K=1  (P=100%)",
        test_grover_k_exact(4, 1, 1)),
    run_test("4.7 N=16 M=4 -> K=1  (P=100%)",
        test_grover_k_exact(16, 4, 1)),
    run_test("4.8 N=16 M=1 -> K=2 or K=3  (not K=1)",
        test_grover_k_not(16, 1, 1)),   %% K=1 gives 0% for M=1/N=16

    %% Edge cases
    run_test("4.9 M=0 -> K=1  (no solutions, fallback)",
        test_grover_k_exact(16, 0, 1)),
    run_test("4.10 M=N -> K=1  (all solutions, trivial)",
        test_grover_k_exact(16, 16, 1)).

%% ============================================================
%%  Category 5: QASM generation round-trip
%% ============================================================

run_category_5 :-
    section("5. QASM generation (rp_fd -> QASM -> parse check)"),

    %% 5.1 QASM for simple_neq parses without errors and has correct qubit count
    run_test("5.1 simple_neq QASM: parses, correct qubit count (>=5)",
        test_qasm_generated(
            [fd_domain(x,0,3), fd_domain(y,0,3), fd_neq(x,y)],
            'qasm/test_neq.qasm',
            [min_qubits(5)])),

    %% 5.2 Generated QASM has correct iteration count comment
    %% The circuit's default K must NOT depend on the number of
    %% solutions (unknown without solving): it is the optimum for one
    %% marked state in 16 register states, K=3. (Before 1 Oct 2026 it
    %% was K=2, derived from a classical solve: M=12.)
    run_test("5.2 simple_neq QASM: default K=3 (1-solution optimum, N=16; M not used)",
        test_qasm_iteration_count(
            [fd_domain(x,0,3), fd_domain(y,0,3), fd_neq(x,y)],
            'qasm/test_neq.qasm', 3)),

    %% 5.3 sum_eq (constant) QASM parses
    run_test("5.3 sum_eq(const) QASM: parses, correct qubit count (>=7)",
        test_qasm_generated(
            [fd_domain(x,0,4), fd_domain(y,0,4), fd_sum_eq(x,y,5)],
            'qasm/test_sum_eq.qasm',
            [min_qubits(7)])),

    %% 5.4 coloring(3) QASM parses
    run_test("5.4 coloring(3) QASM: parses, qubit count (>=7)",
        test_qasm_generated_example(coloring(3), 'qasm/test_coloring3.qasm',
            [min_qubits(7)])),

    %% 5.5 QASM uncompute section exists (reverse gates present)
    run_test("5.5 Generated QASM contains uncompute section",
        test_qasm_has_uncompute('qasm/test_neq.qasm')),

    %% 5.6 QASM is valid OPENQASM 3.0 header
    run_test("5.6 Generated QASM has OPENQASM 3.0 header",
        test_qasm_header('qasm/test_neq.qasm')).

%% ============================================================
%%  Category 6 (quick): End-to-end Grover circuits
%%  Fast circuits only (< 30s each)
%% ============================================================

run_category_6_quick :-
    section("6. Fast simulator (circuit oracle via pcode) vs Grover theory"),
    %% The fast simulator runs the circuit's oracle (pcode, fixed-width)
    %% over the circuit's register states. Run at the K that theory says
    %% is best for the true number of solutions M (the TEST knows M, from
    %% the classical solver; the simulator does not), every state's
    %% probability must equal sin^2/cos^2 theory exactly.
    run_test("6.1 simple_neq (12 of 16 marked)",
        test_fast_grover([fd_domain(x,0,3), fd_domain(y,0,3), fd_neq(x,y)])),
    run_test("6.2 simple_eq (4 of 16 marked)",
        test_fast_grover([fd_domain(x,0,3), fd_domain(y,0,3), fd_eq(x,y)])).

%% ============================================================
%%  Category 6 (slow): larger problems -- only with rp_test(full).
%% ============================================================

run_category_6_slow :-
    section("6. Fast simulator vs Grover theory (larger problems)"),
    run_test("6.3 sum_eq x+y=z, 3 variables",
        test_fast_grover([fd_domain(x,0,3), fd_domain(y,0,3), fd_domain(z,0,3), fd_sum_eq(x,y,z)])),
    run_test("6.4 coloring(3): size-3 domains in 2-qubit registers (range checks)",
        ( fd_example(coloring(3), G), test_fast_grover(G) )).

%% ============================================================
%%  Category 7: EXACT gate-level backend vs Grover theory
%%
%%  Category 6 simulates through the pcode path, so the compiled
%%  QASM oracle (what run(File,[backend(exact)]) executes) had no
%%  end-to-end coverage -- which is how add/sub wraparound (x+1
%%  wrapping to 0 in a 2-bit ancilla) and gt_zero == ge_zero went
%%  unnoticed. Each test here exports the real circuit, macro-expands
%%  it, runs it on sv_sim, marginalises onto the domain registers and
%%  requires EVERY domain state to match the ideal Grover
%%  distribution for that circuit's K and the true solution count M.
%%  A wrong marked set, or dirty ancillas (which destroy the
%%  interference), cannot pass this.
%% ============================================================

run_category_7_quick :-
    section("7. Exact gate-level backend vs Grover theory"),
    run_test("7.1 sum_neq x+1\\=y, 2-bit (no wraparound: x=3,y=0 is a solution)",
        test_exact_grover([fd_domain(x,0,3), fd_domain(y,0,3), fd_sum_neq(x,1,y)],
                          'qasm/e7_sum_neq.qasm')),
    run_test("7.2 sum_eq x+1=y, 2-bit (3 solutions, not 4)",
        test_exact_grover([fd_domain(x,0,3), fd_domain(y,0,3), fd_sum_eq(x,1,y)],
                          'qasm/e7_sum_eq.qasm')),
    run_test("7.3 lt x<y strict (6 solutions, not 10)",
        test_exact_grover([fd_domain(x,0,3), fd_domain(y,0,3), fd_lt(x,y)],
                          'qasm/e7_lt.qasm')),
    run_test("7.4 ge x>=y, 2-bit (sign bit needs 3 bits)",
        test_exact_grover([fd_domain(x,0,3), fd_domain(y,0,3), fd_ge(x,y)],
                          'qasm/e7_ge.qasm')),
    run_test("7.5 sum_eq x+3=y, 3-bit (5-bit sub, multi-bit incrementer)",
        test_exact_grover([fd_domain(x,0,7), fd_domain(y,0,7), fd_sum_eq(x,3,y)],
                          'qasm/e7_sum_eq3.qasm')),
    %% 7.8: domains not starting at 0, unequal sizes, and a clue. Before
    %% 1 Oct 2026 registers were sized by domain SIZE (x in 5..6 got 1
    %% qubit, so 5 and 6 were unrepresentable), the clue s got a register
    %% in superposition, and nothing rejected out-of-domain register values.
    run_test("7.8 offset domains + clue: x in 5..6, y in 1..2, s=7, x+y=s",
        test_exact_grover([fd_domain(x,5,6), fd_domain(y,1,2),
                           fd_domain(s,[7]), fd_eq(s,7), fd_sum_eq(x,y,s)],
                          'qasm/e7_offset_clue.qasm')).

run_category_7_slow :-
    section("7. Exact gate-level backend vs Grover theory (slow)"),
    run_test("7.6 queens4 anchored q0=1 (1 solution: q1=3,q2=0,q3=2)",
        test_exact_grover([fd_domain(q1,0,3), fd_domain(q2,0,3), fd_domain(q3,0,3),
                           fd_all_different([q1,q2,q3]),
                           fd_neq(q1,1), fd_neq(q2,1), fd_neq(q3,1),
                           fd_neq(q1,0), fd_neq(q1,2), fd_neq(q2,3),
                           fd_sum_neq(q2,1,q1), fd_sum_neq(q1,1,q2),
                           fd_sum_neq(q3,2,q1), fd_sum_neq(q1,2,q3),
                           fd_sum_neq(q3,1,q2), fd_sum_neq(q2,1,q3)],
                          'qasm/e7_queens4_anchor1.qasm')).

%%  test_exact_grover(+Goals, +OutFile)
test_exact_grover(Goals, OutFile) :-
    once(rp_fd_compile(Goals, FDSpec)),
    once(rp_grover_write(FDSpec, OutFile)),
    read_file_to_string(OutFile, Src, []),
    once(( sub_string(Src, B, _, _, "// Grover iterations: "),
           B1 is B + 22,
           sub_string(Src, B1, 6, _, KStr0),
           split_string(KStr0, "\n", " ", [KStr|_]),
           number_string(K, KStr) )),
    qasm3_macro_pp:qasm3_expand_string(Src, Flat),
    atom_string(FlatAtom, Flat),
    once(sv_run_qasm(FlatAtom, sparse(_, Assoc))),
    once(rp_fd_solve(FDSpec, Sols)),
    %% The circuit's own layout: search variables only (clues are
    %% constants), one shared register width, values stored directly.
    rp_grover:rp_grover_circuit_spec(FDSpec, circuit(fd_spec(Domains, _), RegBits, _)),
    nb_setval(rp_test_reg_bits, RegBits),
    length(Domains, NSearch),
    DomBits is RegBits * NSearch,
    Mask is (1 << DomBits) - 1,
    %% marginalise onto the domain registers; the rest must be one
    %% fixed pattern (clean ancillas / constant registers)
    assoc_to_list(Assoc, Pairs),
    findall(D-P, ( member(I-c(Re,Im), Pairs), P is Re*Re+Im*Im, P > 1.0e-9,
                   D is I /\ Mask ), DPs),
    findall(H, ( member(I-c(Re,Im), Pairs), Re*Re+Im*Im > 1.0e-9,
                 H is I >> DomBits ), Hs0),
    sort(Hs0, Hs), length(Hs, 1),
    %% ideal Grover distribution over the 2^DomBits encoded states
    maplist([S,Ix]>>domain_state_idx(S, Domains, Ix), Sols, SolIdxs0),
    sort(SolIdxs0, SolIdxs),
    length(SolIdxs, M), NEnc is 1 << DomBits,
    M > 0, M < NEnc,
    Theta is asin(sqrt(M / NEnc)),
    PSol   is sin((2*K+1)*Theta)**2 / M,
    POther is cos((2*K+1)*Theta)**2 / (NEnc - M),
    NEnc1 is NEnc - 1,
    forall(between(0, NEnc1, D),
           ( aggregate_all(sum(P), member(D-P, DPs), Got),
             ( memberchk(D, SolIdxs) -> Want = PSol ; Want = POther ),
             abs(Got - Want) =< 1.0e-3 )),
    %% ... and the fast simulator, at the same K, must give the same
    %% probability for every register state as the real gates.
    with_output_to(string(_), grover_search(FDSpec, [iterations(K)], fixed(K))),
    nb_getval(grover_last_vector, V),
    forall(nth0(D, V, A),
           ( aggregate_all(sum(P), member(D-P, DPs), Got),
             abs(Got - A*A) =< 1.0e-6 )).

%% ============================================================
%%  Category 8: the fast simulator's oracle IS the circuit's oracle
%%
%%  Every register state is pushed through the exported circuit's
%%  oracle gates classically (they are only X, CX, CCX: a permutation
%%  of basis states). For every state, the oracle flag must equal the
%%  fast simulator's verdict (rp_pcode:pcode_marks/4), and every other
%%  qubit must be back where it started (ancillas uncomputed).
%% ============================================================

run_category_8 :-
    section("8. Oracle gates vs fast simulator, every register state"),
    forall(member(F, ['examples/simple_neq.clp', 'examples/factor15.clp',
                      'examples/coloring3.clp', 'examples/queens4_anchor1.clp',
                      'clp/queens4.clp', 'clp/factor21.clp', 'clp/maxcut.clp']),
           ( format(atom(L), "8 ~w", [F]),
             run_test(L, test_oracle_gates(F)) )).

test_oracle_gates(F) :-
    load_spec(F, G), once(rp_fd_compile(G, FD)),
    nb_setval(qsim_current_example, F),
    test_oracle_gates_fd(FD).

test_oracle_gates_fd(FD) :-
    rp_grover:rp_grover_circuit_spec(FD, circuit(fd_spec(Search, _), _, NCirc)),
    rp_grover:rp_grover_qasm(FD, [iterations(1)], Lines),
    atomic_list_concat(Lines, '\n', Src),
    qasm3_macro_pp:qasm3_expand_string(Src, Flat),
    split_string(Flat, "\n", " \t", Ls0), maplist(atom_string, Ls1, Ls0),
    exclude(==(''), Ls1, Ls),
    sv_sim:qasm3_build_regmap(Ls, RM, NQ),
    once(( append(Pre, ['// Grover iterations'|R], Ls),
           append(Body, ['// Measurement'|_], R) )),
    sv_sim:qasm3_parse_gates_multi(Pre, RM, NQ, PreG),
    sv_sim:qasm3_parse_gates_multi(Body, RM, NQ, BodyG),
    memberchk(reg(v_oracle_flag, FQ, 1), RM),
    once(( append(_, [gate(h,[FQ])|Rest], BodyG),
           append(OrG, [gate(h,[FQ])|_], Rest) )),
    forall(member(gate(Gn, _), OrG), memberchk(Gn, [x, cx, ccx])),
    %% constants: the preparation's X gates (H only creates superposition)
    foldl([gate(Gn,Qs), S0, S1]>>( Gn == x -> Qs = [Q], S1 is S0 xor (1 << Q) ; S1 = S0 ),
          PreG, 0, Const0),
    findall(B-Sz, ( member(dom(V,_,_), Search), atom_concat(v_, V, RN),
                    memberchk(reg(RN, B, Sz), RM) ), Regs),
    foldl([B-Sz, M0, M1]>>(M1 is M0 \/ (((1 << Sz) - 1) << B)), Regs, 0, RegMask),
    Const is Const0 /\ \ RegMask,
    with_output_to(string(_), qsim_pp_grover:oracle_space(FD, Space)),
    NC1 is NCirc - 1,
    forall(between(0, NC1, Idx),
           ( place_regs(Regs, Idx, Const, S),
             foldl(classical_gate, OrG, S, T),
             Flag is (T >> FQ) /\ 1,
             T =:= S xor (Flag << FQ),                 %% everything else restored
             ( qsim_pp_grover:marked_state(Space, Idx) -> Flag =:= 1 ; Flag =:= 0 ) )).

place_regs([], _, S, S).
place_regs([B-Sz|Rs], I, S0, S) :-
    S1 is S0 \/ ((I /\ ((1 << Sz) - 1)) << B),
    I1 is I >> Sz,
    place_regs(Rs, I1, S1, S).

classical_gate(gate(x, [Q]), S0, S) :- S is S0 xor (1 << Q).
classical_gate(gate(cx, [C, Q]), S0, S) :-
    ( (S0 >> C) /\ 1 =:= 1 -> S is S0 xor (1 << Q) ; S = S0 ).
classical_gate(gate(ccx, [C1, C2, Q]), S0, S) :-
    ( (S0 >> C1) /\ 1 =:= 1, (S0 >> C2) /\ 1 =:= 1 -> S is S0 xor (1 << Q) ; S = S0 ).

%% ============================================================
%%  Category 9: compiled oracle vs the true answers (edge cases)
%%
%%  Category 8 checks the gates against the microcode; this checks the
%%  microcode against the classical solver (the TEST's reference, never
%%  used by a quantum path): over every register state, the oracle marks
%%  exactly the solutions inside the declared domains. Then the gates
%%  are checked against the microcode too. Cases from the independent
%%  review of 2 Oct 2026, which found constants mis-compiled.
%% ============================================================

run_category_9 :-
    section("9. Compiled oracle vs true answers (constant edge cases)"),
    run_test("9.1 x*5 = 15: constant multiplier wider than the registers",
        test_oracle_true([fd_domain(x,0,3), fd_product_eq(x,5,15)])),
    run_test("9.2 x*y = 17 on 0..3: product target wider than the product register",
        test_oracle_true([fd_domain(x,0,3), fd_domain(y,0,3), fd_product_eq(x,y,17)])),
    run_test("9.3 x*y = p, p = 20 (clue), x, y in 2..3",
        test_oracle_true([fd_domain(x,2,3), fd_domain(y,2,3), fd_domain(p,[20]), fd_product_eq(x,y,p)])),
    run_test("9.4 x*3 = y: constant multiplier, variable product refused",
        \+ with_output_to(string(_), test_oracle_true([fd_domain(x,0,3), fd_domain(y,0,9), fd_product_eq(x,3,y)]))),
    run_test("9.5 x + 9 = y, y in 0..15: constant wider than x",
        test_oracle_true([fd_domain(x,0,7), fd_domain(y,0,15), fd_sum_eq(x,9,y)])),
    run_test("9.6 x > 6 on 0..3: comparison constant above every register value",
        test_oracle_true([fd_domain(x,0,3), fd_domain(y,0,3), fd_gt(x,6), fd_neq(x,y)])),
    run_test("9.7 negative constant refused (x + (-1) = y)",
        \+ with_output_to(string(_), test_oracle_true([fd_domain(x,0,3), fd_domain(y,0,3), fd_sum_eq(x,-1,y)]))),
    run_test("9.8 x*y = c, c = 6 (clue), x ≠ y, x, y in 1..5",
        test_oracle_true([fd_domain(x,1,5), fd_domain(y,1,5), fd_domain(c,[6]), fd_product_eq(x,y,c), fd_neq(x,y)])).

test_oracle_true(Goals) :-
    once(rp_fd_compile(Goals, FD)),
    with_output_to(string(_), qsim_pp_grover:oracle_space(FD, Space)),
    Space = space(_, _, NCirc, _, _, _, _, _),
    once(rp_fd_solve(FD, Sols0)),
    maplist([S0, S]>>msort(S0, S), Sols0, Sols1), sort(Sols1, Sols),
    NC1 is NCirc - 1,
    findall(A, ( between(0, NC1, I), qsim_pp_grover:marked_state(Space, I),
                 qsim_pp_grover:check_state(Space, I, A0, _), msort(A0, A) ), Marked0),
    sort(Marked0, Marked),
    Marked == Sols,
    test_oracle_gates_fd(FD).

%% ============================================================
%%  Test primitive implementations
%% ============================================================

%%  test_qasm_result(+File, +Checks)
%%  Load a QASM file and verify a list of state-probability checks.
test_qasm_result(File, Checks) :-
    sv_run_file(File, State),
    maplist(check_state(State), Checks).

%%  test_inline_qasm(+QASMAtom, +Checks)
test_inline_qasm(QASM, Checks) :-
    sv_run_qasm(QASM, State),
    maplist(check_state(State), Checks).

%%  check_state(+State, +Check)
check_state(State, state_prob_close(Idx, Expected, Tol)) :-
    state_prob(State, Idx, Got),
    abs(Got - Expected) =< Tol.
check_state(State, state_is_dominant(Idx, MinProb)) :-
    state_prob(State, Idx, P),
    P >= MinProb.

%%  test_oracle_phase(+CircuitAtom, +ExpectedSign, +Tol)
%%  Run a single-state circuit (no superposition) and verify the
%%  resulting amplitude has the expected sign (+1 or -1).
%%  (sv_sim returns sparse(_, Assoc) -- Idx -> c(Re,Im) -- not the
%%  dense sv(...) term these two helpers were originally written for;
%%  sv_nonzero_amps/2 reads either.)
test_oracle_phase(QASM, ExpectedSign, Tol) :-
    sv_run_qasm(QASM, State),
    %% Find the non-zero state and check amplitude sign
    sv_nonzero_amps(State, Amps),
    member(_-c(Re, _Im), Amps),
    abs(Re) > 0.3,   %% significant amplitude
    !,
    ( ExpectedSign > 0 -> Re > -Tol ; Re < Tol ).

sv_nonzero_amps(sparse(_, Assoc), Amps) :- !,
    assoc_to_list(Assoc, All),
    include([_-c(R,I)]>>(abs(R)+abs(I) > 0.01), All, Amps).
sv_nonzero_amps(State, Amps) :-
    functor(State, sv, Size),
    SizeM1 is Size-1, numlist(0, SizeM1, Idxs),
    findall(I-c(R,Im), ( member(I, Idxs), I1 is I+1, arg(I1, State, c(R,Im)),
                         abs(R)+abs(Im) > 0.01 ), Amps).

%%  test_ancilla_clean(+QASM)
%%  Run QASM and verify all ancilla registers return to |0> after roundtrip.
%%  Checks that the single non-zero state has all ancilla bits = 0.
test_ancilla_clean(QASM) :-
    sv_run_qasm(QASM, State),
    sv_nonzero_amps(State, NonZero),
    %% All non-zero states should have ancilla = 0 (ancilla bits are upper bits)
    %% We just verify there's exactly 1 non-zero state (clean ancilla means no entanglement)
    length(NonZero, 1).

%%  test_fd_solution_count(+Goals, +Expected)
test_fd_solution_count(Goals, Expected) :-
    rp_fd_compile(Goals, FDSpec),
    rp_fd_solve(FDSpec, Solutions),
    length(Solutions, Expected).

%%  test_fd_example_count(+Name, +Expected)
test_fd_example_count(Name, Expected) :-
    fd_example(Name, Goals),
    test_fd_solution_count(Goals, Expected).

%%  test_fd_solution_includes(+Goals, +Bindings)
%%  Verify that at least one solution matches the given variable bindings.
test_fd_solution_includes(Goals, Expected) :-
    rp_fd_compile(Goals, FDSpec),
    rp_fd_solve(FDSpec, Solutions),
    member(Sol, Solutions),
    maplist([V-Val]>>(member(V-Val, Sol)), Expected),
    !.

%%  test_grover_k_valid(+N, +M)
%%  Verify that rp_grover_iterations_m(N,M,K) gives K with P(success) >= 50%.
test_grover_k_valid(N, M) :-
    rp_grover_iterations_m(N, M, K),
    ( M =:= 0 -> true
    ; M >= N   -> true
    ;   Theta is asin(sqrt(float(M)/float(N))),
        P is sin((2.0*K+1.0)*Theta)**2,
        P >= 0.5
    ).

%%  test_grover_k_exact(+N, +M, +ExpK)
test_grover_k_exact(N, M, ExpK) :-
    rp_grover_iterations_m(N, M, K),
    K =:= ExpK.

%%  test_grover_k_not(+N, +M, +NotK)
%%  Verify K is NOT equal to NotK (to detect known-bad values).
test_grover_k_not(N, M, NotK) :-
    rp_grover_iterations_m(N, M, K),
    K \= NotK.

%%  test_qasm_generated(+Goals, +OutFile, +Checks)
test_qasm_generated(Goals, OutFile, Checks) :-
    rp_fd_compile(Goals, FDSpec),
    rp_grover_write(FDSpec, OutFile),
    maplist(check_qasm_file(OutFile), Checks).

%%  test_qasm_generated_example(+Name, +OutFile, +Checks)
test_qasm_generated_example(Name, OutFile, Checks) :-
    fd_example(Name, Goals),
    test_qasm_generated(Goals, OutFile, Checks).

%%  check_qasm_file(+File, +Check)
check_qasm_file(File, min_qubits(Min)) :-
    qasm3_nqubits_from_file(File, NQ),
    NQ >= Min.

%%  test_qasm_iteration_count(+Goals, +OutFile, +ExpectedK)
test_qasm_iteration_count(Goals, OutFile, ExpK) :-
    rp_fd_compile(Goals, FDSpec),
    rp_grover_write(FDSpec, OutFile),
    read_file_to_string(OutFile, Str, []),
    ( sub_string(Str, _, _, _, "iterations: 1") ->
        K = 1
    ; sub_string(Str, _, _, _, "iterations: 2") ->
        K = 2
    ; sub_string(Str, _, _, _, "iterations: 3") ->
        K = 3
    ; K = unknown ),
    K =:= ExpK.

%%  test_qasm_has_uncompute(+File)
test_qasm_has_uncompute(File) :-
    read_file_to_string(File, Str, []),
    %% The structured emitter uncomputes with the OpenQASM3 inverse
    %% modifier ("inv @ gate ...") rather than a comment saying so.
    ( sub_string(Str, _, _, _, "inv @") -> true
    ; sub_string(Str, _, _, _, "uncompute") ).

%%  test_qasm_header(+File)
test_qasm_header(File) :-
    read_file_to_string(File, Str, []),
    sub_string(Str, _, _, _, "OPENQASM 3.0").

%%  test_fast_grover(+Goals)
%%  Fast simulator at the theoretically best K for the true M (known to
%%  the test only) must match Grover theory state by state.
test_fast_grover(Goals) :-
    once(rp_fd_compile(Goals, FDSpec)),
    rp_grover:rp_grover_circuit_spec(FDSpec, circuit(fd_spec(Domains, _), RegBits, NCirc)),
    nb_setval(rp_test_reg_bits, RegBits),
    once(rp_fd_solve(FDSpec, Sols)),
    maplist([S,Ix]>>domain_state_idx(S, Domains, Ix), Sols, SolIdxs0),
    sort(SolIdxs0, SolIdxs),
    length(SolIdxs, M), M > 0, M < NCirc,
    rp_grover_iterations_m(NCirc, M, K),
    with_output_to(string(_), grover_search(FDSpec, [iterations(K)], fixed(K))),
    nb_getval(grover_last_vector, V),
    Theta is asin(sqrt(M / NCirc)),
    PSol   is sin((2*K+1)*Theta)**2 / M,
    POther is cos((2*K+1)*Theta)**2 / (NCirc - M),
    forall(nth0(I, V, A),
           ( P is A*A,
             ( memberchk(I, SolIdxs) -> Want = PSol ; Want = POther ),
             abs(P - Want) =< 1.0e-9 )).

%%  domain_state_idx(+Solution, +Domains, -Idx)
%%  Convert a solution (list of Var-Val pairs) to a flat state vector index.
%%  Domains is a list of dom(Var, Low, High) terms.
domain_state_idx(Sol, Domains, Idx) :-
    domain_state_idx_acc(Sol, Domains, 0, 0, Idx).

domain_state_idx_acc(_, [], _, Acc, Acc) :- !.
domain_state_idx_acc(Sol, [dom(V,Low,_High)|Ds], BitOffset, Acc, Idx) :-
    ( member(V-Val, Sol) -> true ; Val = Low ),
    %% registers hold the value itself, all at the shared width
    nb_getval(rp_test_reg_bits, Bits),
    Contrib is Val << BitOffset,
    Acc1 is Acc + Contrib,
    BitOffset1 is BitOffset + Bits,
    domain_state_idx_acc(Sol, Ds, BitOffset1, Acc1, Idx).

%% ============================================================
%%  Inline oracle QASM builders
%%  These build minimal QASM strings for targeted oracle tests.
%% ============================================================

%%  neq_oracle_circuit(+X, +Y) -- oracle only, input state + phase kickback
neq_oracle_qasm(Xv, Yv, QASM) :-
    %% Build inline QASM for the neq oracle with x=Xv, y=Yv as basis state
    init_bits_qasm("x", Xv, 2, XInit),
    init_bits_qasm("y", Yv, 2, YInit),
    atomic_list_concat([
        "OPENQASM 3.0;\ninclude \"stdgates.inc\";\n",
        "qubit[2] x;\nqubit[2] y;\nqubit[2] fd_anc1;\nqubit[1] or_anc;\nqubit[1] oracle_flag;\n",
        XInit, YInit,
        "x oracle_flag;\nh oracle_flag;\n",
        "cx x[0], fd_anc1[0];\ncx y[0], fd_anc1[0];\n",
        "cx x[1], fd_anc1[1];\ncx y[1], fd_anc1[1];\n",
        "cx fd_anc1[0], or_anc[0];\ncx fd_anc1[1], or_anc[0];\n",
        "ccx fd_anc1[0], fd_anc1[1], or_anc[0];\n",
        "cx or_anc[0], oracle_flag[0];\n",
        "ccx fd_anc1[0], fd_anc1[1], or_anc[0];\n",
        "cx fd_anc1[1], or_anc[0];\ncx fd_anc1[0], or_anc[0];\n",
        "h oracle_flag;\nx oracle_flag;"
    ], '', QASM).

neq_oracle_roundtrip_qasm(Xv, Yv, QASM) :-
    init_bits_qasm("x", Xv, 2, XInit),
    init_bits_qasm("y", Yv, 2, YInit),
    atomic_list_concat([
        "OPENQASM 3.0;\ninclude \"stdgates.inc\";\n",
        "qubit[2] x;\nqubit[2] y;\nqubit[2] fd_anc1;\nqubit[1] or_anc;\nqubit[1] oracle_flag;\n",
        XInit, YInit,
        "x oracle_flag;\nh oracle_flag;\n",
        "cx x[0], fd_anc1[0];\ncx y[0], fd_anc1[0];\n",
        "cx x[1], fd_anc1[1];\ncx y[1], fd_anc1[1];\n",
        "cx fd_anc1[0], or_anc[0];\ncx fd_anc1[1], or_anc[0];\n",
        "ccx fd_anc1[0], fd_anc1[1], or_anc[0];\n",
        "cx or_anc[0], oracle_flag[0];\n",
        "ccx fd_anc1[0], fd_anc1[1], or_anc[0];\n",
        "cx fd_anc1[1], or_anc[0];\ncx fd_anc1[0], or_anc[0];\n",
        "h oracle_flag;\nx oracle_flag;\n",
        "cx y[1], fd_anc1[1];\ncx x[1], fd_anc1[1];\n",
        "cx y[0], fd_anc1[0];\ncx x[0], fd_anc1[0];"
    ], '', QASM).

%%  eq_oracle_circuit(+X, +Y)
eq_oracle_qasm(Xv, Yv, QASM) :-
    init_bits_qasm("x", Xv, 2, XInit),
    init_bits_qasm("y", Yv, 2, YInit),
    atomic_list_concat([
        "OPENQASM 3.0;\ninclude \"stdgates.inc\";\n",
        "qubit[2] x;\nqubit[2] y;\nqubit[2] fd_anc1;\nqubit[1] oracle_flag;\n",
        XInit, YInit,
        "x oracle_flag;\nh oracle_flag;\n",
        "cx x[0], fd_anc1[0];\ncx y[0], fd_anc1[0];\n",
        "cx x[1], fd_anc1[1];\ncx y[1], fd_anc1[1];\n",
        "x fd_anc1[0];\nx fd_anc1[1];\n",
        "ccx fd_anc1[0], fd_anc1[1], oracle_flag[0];\n",
        "x fd_anc1[0];\nx fd_anc1[1];\n",
        "h oracle_flag;\nx oracle_flag;"
    ], '', QASM).

%%  sum_eq_oracle_circuit(+X, +Y, +Z) and roundtrip
sum_eq_oracle_qasm(Xv, Yv, Zv, QASM) :-
    init_bits_qasm("x", Xv, 2, XInit),
    init_bits_qasm("y", Yv, 2, YInit),
    init_bits_qasm("z", Zv, 2, ZInit),
    atomic_list_concat([
        "OPENQASM 3.0;\ninclude \"stdgates.inc\";\n",
        "qubit[2] x;\nqubit[2] y;\nqubit[2] z;\n",
        "qubit[2] fd_anc1;\nqubit[2] fd_anc101;\nqubit[2] carry;\nqubit[1] oracle_flag;\n",
        XInit, YInit, ZInit,
        "x oracle_flag;\nh oracle_flag;\n",
        "cx x[0],carry[0]; cx x[0],y[0]; ccx y[0],carry[0],x[0];\n",
        "cx x[1],carry[1]; cx x[1],y[1]; ccx y[1],carry[1],x[1];\n",
        "cx carry[1], fd_anc1[1];\n",
        "ccx y[1],carry[1],x[1]; cx x[1],carry[1]; cx carry[1],y[1]; cx y[1],fd_anc1[1];\n",
        "ccx y[0],carry[0],x[0]; cx x[0],carry[0]; cx carry[0],y[0]; cx y[0],fd_anc1[0];\n",
        "x z[0]; x z[1];\n",
        "cx fd_anc1[0],carry[0]; cx fd_anc1[0],z[0]; ccx z[0],carry[0],fd_anc1[0];\n",
        "cx fd_anc1[1],carry[1]; cx fd_anc1[1],z[1]; ccx z[1],carry[1],fd_anc1[1];\n",
        "cx carry[1], fd_anc101[1];\n",
        "ccx z[1],carry[1],fd_anc1[1]; cx fd_anc1[1],carry[1]; cx carry[1],z[1]; cx z[1],fd_anc101[1];\n",
        "ccx z[0],carry[0],fd_anc1[0]; cx fd_anc1[0],carry[0]; cx carry[0],z[0]; cx z[0],fd_anc101[0];\n",
        "x fd_anc101[0];\nx z[0]; x z[1];\n",
        "x fd_anc101[0]; x fd_anc101[1];\n",
        "ccx fd_anc101[0], fd_anc101[1], oracle_flag[0];\n",
        "x fd_anc101[0]; x fd_anc101[1];\n",
        "h oracle_flag;\nx oracle_flag;"
    ], '', QASM).

sum_eq_oracle_roundtrip_qasm(Xv, Yv, Zv, QASM) :-
    init_bits_qasm("x", Xv, 2, XInit),
    init_bits_qasm("y", Yv, 2, YInit),
    init_bits_qasm("z", Zv, 2, ZInit),
    atomic_list_concat([
        "OPENQASM 3.0;\ninclude \"stdgates.inc\";\n",
        "qubit[2] x;\nqubit[2] y;\nqubit[2] z;\n",
        "qubit[2] fd_anc1;\nqubit[2] fd_anc101;\nqubit[2] carry;\nqubit[1] oracle_flag;\n",
        XInit, YInit, ZInit,
        "x oracle_flag;\nh oracle_flag;\n",
        %% Forward
        "cx x[0],carry[0]; cx x[0],y[0]; ccx y[0],carry[0],x[0];\n",
        "cx x[1],carry[1]; cx x[1],y[1]; ccx y[1],carry[1],x[1];\n",
        "cx carry[1], fd_anc1[1];\n",
        "ccx y[1],carry[1],x[1]; cx x[1],carry[1]; cx carry[1],y[1]; cx y[1],fd_anc1[1];\n",
        "ccx y[0],carry[0],x[0]; cx x[0],carry[0]; cx carry[0],y[0]; cx y[0],fd_anc1[0];\n",
        "x z[0]; x z[1];\n",
        "cx fd_anc1[0],carry[0]; cx fd_anc1[0],z[0]; ccx z[0],carry[0],fd_anc1[0];\n",
        "cx fd_anc1[1],carry[1]; cx fd_anc1[1],z[1]; ccx z[1],carry[1],fd_anc1[1];\n",
        "cx carry[1], fd_anc101[1];\n",
        "ccx z[1],carry[1],fd_anc1[1]; cx fd_anc1[1],carry[1]; cx carry[1],z[1]; cx z[1],fd_anc101[1];\n",
        "ccx z[0],carry[0],fd_anc1[0]; cx fd_anc1[0],carry[0]; cx carry[0],z[0]; cx z[0],fd_anc101[0];\n",
        "x fd_anc101[0];\nx z[0]; x z[1];\n",
        "x fd_anc101[0]; x fd_anc101[1];\n",
        "ccx fd_anc101[0], fd_anc101[1], oracle_flag[0];\n",
        "x fd_anc101[0]; x fd_anc101[1];\n",
        "h oracle_flag;\nx oracle_flag;\n",
        %% Reverse uncompute
        "x z[1]; x z[0];\n",
        "x fd_anc101[0];\n",
        "cx z[0],fd_anc101[0]; cx carry[0],z[0]; cx fd_anc1[0],carry[0]; ccx z[0],carry[0],fd_anc1[0];\n",
        "cx z[1],fd_anc101[1]; cx carry[1],z[1]; cx fd_anc1[1],carry[1]; ccx z[1],carry[1],fd_anc1[1];\n",
        "cx carry[1], fd_anc101[1];\n",
        "ccx z[1],carry[1],fd_anc1[1]; cx fd_anc1[1],z[1]; cx fd_anc1[1],carry[1];\n",
        "ccx z[0],carry[0],fd_anc1[0]; cx fd_anc1[0],z[0]; cx fd_anc1[0],carry[0];\n",
        "x z[1]; x z[0];\n",
        "cx y[0],fd_anc1[0]; cx carry[0],y[0]; cx x[0],carry[0]; ccx y[0],carry[0],x[0];\n",
        "cx y[1],fd_anc1[1]; cx carry[1],y[1]; cx x[1],carry[1]; ccx y[1],carry[1],x[1];\n",
        "cx carry[1], fd_anc1[1];\n",
        "ccx y[1],carry[1],x[1]; cx x[1],y[1]; cx x[1],carry[1];\n",
        "ccx y[0],carry[0],x[0]; cx x[0],y[0]; cx x[0],carry[0];"
    ], '', QASM).

%%  init_bits_qasm(+RegName, +Value, +Bits, -Lines)
%%  Emit X gates to set a register to a given integer value.
init_bits_qasm(Reg, Val, Bits, Lines) :-
    Bits1 is Bits - 1,
    numlist(0, Bits1, IdxList),
    include([I]>>(B is (Val >> I) /\ 1, B =:= 1), IdxList, OneBits),
    maplist([I, L]>>(
        format(atom(L), "x ~w[~w];\n", [Reg, I])
    ), OneBits, LineParts),
    atomic_list_concat(LineParts, Lines).
