%% ============================================================
%%  qsim_pp_grover.pl  --  fast Grover simulator (run/1)
%%
%%  Simulates the exported circuit's Grover search without simulating
%%  its gates. The oracle is the circuit's own microcode (the pcode,
%%  rp_fd_oracle_mc/2 on the circuit spec), evaluated per basis state
%%  in the circuit's fixed-width registers (rp_pcode:pcode_marks/4).
%%  So:
%%
%%    * The state space is the circuit's register space: Bits qubits
%%      per search variable, NCirc = 2^(Bits * #vars) basis states,
%%      binary little-endian indices in register order -- the same
%%      indices sv_sim reports for the circuit (ancillas clean).
%%    * A state is marked iff the circuit's oracle marks it. For the
%%      same K, the probabilities equal those of the gate-level
%%      simulation of the exported circuit (run_qasm/2), in a fraction
%%      of the time. Any difference is a fault in the gate generator.
%%    * Constraints the pcode cannot express are refused
%%      (rp_grover:circuit_supported/1), as export refuses them.
%%    * fd_cost is not in the oracle (the circuit has no cost oracle
%%      yet); a search finds a state satisfying the hard constraints.
%%
%%  Nothing is solved classically. The search does not know the number
%%  of solutions: exponential search (Boyer, Brassard, Hoyer, Tapp).
%%  Each measured state is checked classically (domains and
%%  constraints), which is the cheap verification step of Grover
%%  search; if the check and the oracle disagree on a measured state,
%%  that is reported as an oracle fault.
%%
%%  grover_search(+FDSpec, +Opts, -Result)
%%     Opts: seed(S), budget(B) [9: B*sqrt(NCirc) oracle calls],
%%           iterations(K): no search, run exactly K iterations (as the
%%           exported circuit with that K does).
%%     Result = found(Assignment, K, Calls) | not_found(Calls)
%%            | fixed(K) | refused
%%  grover_show(+Opts)        final state of the last run: top(N),
%%                            shots(N), analysis(true)
%%  grover_top(+N), grover_decode(+Idx, -Assignment)
%% ============================================================

:- module(qsim_pp_grover, [
    grover_search/3,
    grover_show/1,
    grover_decode/2,
    grover_top/1
]).

:- use_module(library(lists)).
:- use_module(library(assoc)).
:- use_module(library(apply)).
:- use_module(library(pairs)).
:- use_module(library(random)).
:- use_module(rp_fd,     [rp_fd_oracle_mc/2, fd_spec_domains/2]).
:- use_module(rp_pcode,  [pcode_marks/4]).
:- use_module(rp_namer,  [rp_rename/2]).

%% ============================================================
%%  The circuit's oracle over its register space
%% ============================================================

%%  oracle_space(+FDSpec, -Space)
%%  Space = space(Regs, Bits, NCirc, MC, Widths, Fixed, Domains, Hard)
%%    Regs: search variables in register order (register i holds
%%          bits i*Bits .. i*Bits+Bits-1 of the index)
%%    Fixed: clue variables, V-Value
%%    Domains, Hard: the declared problem, for checking a measured state
oracle_space(FDSpec, space(Regs, Bits, NCirc, MC, Widths, Fixed, Domains, Hard)) :-
    rp_grover:circuit_supported(FDSpec),
    catch(rp_grover:rp_grover_circuit_spec(FDSpec, circuit(CSpec, Bits, NCirc)),
          error(_, context(_, Msg)),
          ( format("[grover] ERROR: ~w~n", [Msg]), fail )),
    CSpec = fd_spec(Search, _),
    maplist([dom(V,_,_), V]>>true, Search, Regs),
    fd_spec_domains(FDSpec, Domains),
    findall(V-C, member(dom(V, C, C), Domains), Fixed),
    FDSpec = fd_spec(_, Cons),
    exclude([con(cost, _)]>>true, Cons, Hard),
    %% Same microcode and register widths as rp_grover_qasm/3.
    rp_fd_oracle_mc(CSpec, RawMC),
    rp_rename(RawMC, MC),
    include([next(_,_)]>>true, MC, NextMC),
    rp_grover:anc_width_map(NextMC, Bits, Widths).

%% register values of a basis state
index_regs(Idx, Regs, Bits, Pairs) :-
    Mask is (1 << Bits) - 1,
    index_regs_(Regs, Idx, Bits, Mask, Pairs).

index_regs_([], _, _, _, []).
index_regs_([V|Vs], I, B, M, [V-X|Ps]) :-
    X is I /\ M, I1 is I >> B,
    index_regs_(Vs, I1, B, M, Ps).

%% An evaluation error is a compiler fault: it is raised, not treated
%% as "not marked" (which would silently search an empty oracle).
marked_state(space(Regs, Bits, _, MC, Widths, _, _, _), Idx) :-
    index_regs(Idx, Regs, Bits, A),
    pcode_marks(MC, Widths, Bits, A).

%% the measured state checked classically: in its domain, constraints hold
check_state(space(Regs, Bits, _, _, _, Fixed, Domains, Hard), Idx, A, Ok) :-
    index_regs(Idx, Regs, Bits, A0),
    append(A0, Fixed, A),
    (   forall(member(dom(V,L,H), Domains), (memberchk(V-X, A), X >= L, X =< H)),
        catch(forall(member(C, Hard), rp_fd:check_constraint(A, C)), _, fail)
    ->  Ok = true
    ;   Ok = false
    ).

%% ============================================================
%%  grover_search(+FDSpec, +Opts, -Result)
%% ============================================================
grover_search(FDSpec, Opts, Result) :-
    (   oracle_space(FDSpec, Space)
    ->  catch(grover_search_(Space, FDSpec, Opts, Result), E,
              ( format("[grover] ERROR evaluating the oracle microcode: ~q~n", [E]),
                Result = refused ))
    ;   Result = refused
    ).


grover_search_(Space, FDSpec, Opts, Result) :-
    ( memberchk(seed(Seed), Opts) -> set_random(seed(Seed)) ; true ),
    ( memberchk(budget(B), Opts) -> true ; B = 9 ),
    Space = space(Regs, Bits, N, _, _, _, _, _),
    length(Regs, NR),
    format("[grover] circuit oracle (pcode): ~w registers x ~w qubits = ~w register states~n",
           [NR, Bits, N]),
    N1 is N - 1,
    findall(F, ( between(0, N1, I), ( marked_state(Space, I) -> F = -1.0 ; F = 1.0 ) ), Flips),
    Amp is 1.0 / sqrt(float(N)),
    length(V0, N), maplist(=(Amp), V0),
    nb_setval(grover_last_space, Space),
    nb_setval(grover_last_n, N),
    (   FDSpec = fd_spec(_, Cs), memberchk(con(cost, _), Cs)
    ->  format("[grover] note: fd_cost is not in the oracle (the circuit has no cost oracle~n"),
        format("[grover]   yet); this finds a state satisfying the hard constraints.~n")
    ;   true
    ),
    (   memberchk(iterations(K), Opts), integer(K), K >= 0
    ->  format("[grover] ~w Grover iterations (iterations(K)); no search~n", [K]),
        dense_iterate(K, N, Flips, V0, VF),
        store_state(VF, K),
        Result = fixed(K)
    ;   Budget is ceiling(B * sqrt(float(N))),
        format("[grover] exponential search (unknown M), budget ~w oracle calls~n", [Budget]),
        SqrtN is sqrt(float(N)),
        bbht_round(1.0, SqrtN, N, Space, Flips, V0, Budget, 1, 0, Result),
        (   Result = found(A, _, Calls)
        ->  assign_text(A, T),
            format("[grover] found ~w after ~w oracle calls~n", [T, Calls])
        ;   Result = not_found(Calls),
            format("[grover] no solution found within ~w oracle calls (probably none)~n", [Calls])
        )
    ).

bbht_round(M, SqrtN, N, Space, Flips, V0, Budget, Round, Calls0, Result) :-
    (   Calls0 >= Budget
    ->  Result = not_found(Calls0)
    ;   KMax is max(1, ceiling(M)), KTop is KMax - 1,
        random_between(0, KTop, K),
        dense_iterate(K, N, Flips, V0, VF),
        sample_index(VF, I),
        Calls1 is Calls0 + K,
        check_state(Space, I, A, Ok),
        assign_text(A, T),
        nth0(I, Flips, F),
        oracle_consistency(F, Ok, I, T),
        (   Ok == true
        ->  format("[grover]   round ~w: K=~w, measured |~w> ~w: checked, a solution~n", [Round, K, I, T]),
            store_state(VF, K),
            Result = found(A, K, Calls1)
        ;   format("[grover]   round ~w: K=~w, measured |~w> ~w: checked, not a solution~n", [Round, K, I, T]),
            M1 is min(M * 6 / 5, SqrtN), Round1 is Round + 1,
            bbht_round(M1, SqrtN, N, Space, Flips, V0, Budget, Round1, Calls1, Result)
        )
    ).

%% The oracle and the classical check must agree on every state.
oracle_consistency(F, Ok, I, T) :-
    ( F < 0 -> Marked = true ; Marked = false ),
    (   Marked == Ok -> true
    ;   Marked == true
    ->  format("[grover] WARNING: the oracle marks |~w> ~w, but it fails the check:~n", [I, T]),
        format("[grover]   the compiled oracle (and the exported circuit) is wrong.~n")
    ;   format("[grover] WARNING: |~w> ~w is a solution the oracle does not mark:~n", [I, T]),
        format("[grover]   the compiled oracle (and the exported circuit) is wrong.~n")
    ).

%% Dense real-valued Grover iteration: phase flip, inversion about the mean.
dense_iterate(0, _, _, V, V) :- !.
dense_iterate(K, N, Flips, V0, VF) :-
    maplist([F, A, B]>>(B is F * A), Flips, V0, V1),
    sum_list(V1, Sum), Mean is Sum / float(N),
    maplist([A, B]>>(B is 2.0 * Mean - A), V1, V2),
    K1 is K - 1,
    dense_iterate(K1, N, Flips, V2, VF).

sample_index(V, I) :-
    random(R),
    sample_acc(V, R, 0, 0.0, I).
sample_acc([A|As], R, I0, Acc0, I) :-
    Acc is Acc0 + A*A,
    ( ( R < Acc ; As == [] ) -> I = I0 ; I1 is I0 + 1, sample_acc(As, R, I1, Acc, I) ).

store_state(VF, K) :-
    nb_setval(grover_last_vector, VF),
    nb_setval(grover_last_k, K).

%% ============================================================
%%  Display (same layout as run_qasm/2)
%% ============================================================

%%  grover_show(+Opts): the final state of the last run.
%%    top(N) [5] states listed, each decoded and checked
%%    shots(N)          sample N measurements from it, tallied
%%    analysis(true)    every state classified (a classical check of
%%                      all states: diagnostics, not part of the search)
grover_show(Opts) :-
    nb_getval(grover_last_k, K),
    ( memberchk(top(TopN), Opts) -> true ; TopN = 5 ),
    format("~nFinal state after K=~w (simulator view, not measurable on hardware):~n", [K]),
    grover_top(TopN),
    (   memberchk(shots(S), Opts), integer(S), S > 0
    ->  show_shots(S, TopN)
    ;   true
    ),
    (   memberchk(analysis(true), Opts)
    ->  show_analysis
    ;   true
    ).

%%  grover_top(+N): the N most probable basis states of the last run
grover_top(N) :-
    (   catch(nb_getval(grover_last_vector, VF), _, fail), VF \== []
    ->  true
    ;   format("[grover_top] No simulation result stored yet.~n"), fail
    ),
    nb_getval(grover_last_space, Space),
    nb_getval(grover_last_n, Total),
    findall(P-I, ( nth0(I, VF, A), P is A*A ), PI),
    sort(1, @>=, PI, Desc),
    length(Desc, NA), Show is min(N, NA),
    length(Top, Show), append(Top, _, Desc),
    format("Top ~w of ~w register states by probability:~n", [Show, Total]),
    forall(member(P-I, Top),
           ( state_label(Space, I, T, Lbl), Pct is P*100,
             format("  |~w>  ~t~4f~18|%  ~w  ~s~n", [I, Pct, T, Lbl]) )).

state_label(Space, I, T, Lbl) :-
    check_state(Space, I, A, Ok),
    assign_text(A, T),
    (   Ok == true -> Lbl = "** solution **"
    ;   Space = space(_, _, _, _, _, _, Domains, Hard),
        catch(forall(member(C, Hard), rp_fd:check_constraint(A, C)), _, fail),
        \+ forall(member(dom(V,L,H), Domains), (memberchk(V-X, A), X >= L, X =< H))
    ->  Lbl = "** wraparound ** (solves it, outside declared domain)"
    ;   Lbl = ""
    ).

grover_decode(Idx, Assignment) :-
    nb_getval(grover_last_space, Space),
    check_state(Space, Idx, A, _),
    maplist([V-X, V=X]>>true, A, Assignment).

show_shots(S, TopN) :-
    nb_getval(grover_last_vector, VF),
    nb_getval(grover_last_space, Space),
    length(Is, S), maplist([I]>>sample_index(VF, I), Is),
    msort(Is, Sorted), clumped(Sorted, C0),
    maplist([I-C, C-I]>>true, C0, C1), sort(1, @>=, C1, Counts),
    length(Counts, ND), Show is min(TopN, ND),
    format("~nShot results (~w samples, ~w distinct states, top ~w; each checked):~n", [S, ND, Show]),
    length(Top, Show), append(Top, _, Counts),
    forall(member(C-I, Top),
           ( state_label(Space, I, T, Lbl), Pct is C*100/S,
             format("  ~t~w~6|/~w (~1f%)  ~w  ~s~n", [C, S, Pct, T, Lbl]) )).

show_analysis :-
    nb_getval(grover_last_vector, VF),
    nb_getval(grover_last_space, Space),
    format("~n[analysis] every state checked classically -- diagnostics, not part of the search~n"),
    findall(Lbl-P, ( nth0(I, VF, A), P is A*A, state_label(Space, I, _, Lbl) ), LP),
    sum_label(LP, "** solution **", PS, NS),
    sum_label(LP, "** wraparound ** (solves it, outside declared domain)", PW, NW),
    PO is 1.0 - PS - PW,
    format("  solutions in declared domain   ~t~2f~42|%   (~w states)~n", [PS*100, NS]),
    ( NW > 0 -> format("  wraparound solutions           ~t~2f~42|%   (~w states)~n", [PW*100, NW]) ; true ),
    format("  non-solutions                  ~t~2f~42|%~n", [PO*100]).

sum_label(LP, L, P, N) :-
    findall(Pi, member(L-Pi, LP), Ps), sum_list(Ps, P), length(Ps, N).

assign_text(A, T) :-
    maplist([V-X, S]>>format(atom(S), "~w=~w", [V,X]), A, Ss),
    atomic_list_concat(Ss, ',', Body), format(atom(T), "[~w]", [Body]).
