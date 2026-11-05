# QCLP_G Changelog

## 2 Oct 2026: constants compiled correctly (independent review)

An independent review ran 41 edge-case problems of its own through the
classical solver, the fast simulator and the gates. Three bugs, all in
constants, made the circuit (and so `run/1`) mark the wrong states:

* **Product target too large for the product register.** The test
  compared only the low bits: `fd_product_eq(x, y, 17)` with x, y in
  0..3 (no solution) marked x = y = 1, since 17 mod 16 = 1; the
  exported circuit put 47% on it. A target that does not fit is now
  never met, in the microcode evaluator and in the gates.
* **Constant multiplier truncated to the register width.**
  `fd_product_eq(x, 5, 15)` with x in 0..3 multiplied by 1 (5 in 2
  bits), so x = 3 was never marked. The multiplier is now as wide as its
  widest operand, its product twice that, and narrower operands are
  zero-padded as for the adders.
* **Negative constants** were accepted, compiled into wrong marks and an
  invalid register name (`const_-1`). They are now refused, with a hint
  (`fd_sum_eq(y, 1, x)` for x + (-1) = y).

After the fixes, 37 of the 41 problems agree on the whole chain
(classical answer = fast-simulator marks = gate marks, ancillas clean).
The other 4 are refused as intended: two negative constants, one
`fd_abs_diff`, and one where every variable is fixed (nothing to
search). On real gates: x·5 = 15 gives
100% on x = 3; x·y = 17 stays uniform. Every shipped problem file was
re-checked state by state: no change.

**New tests**, category 9: the compiled oracle against the true answers
(the classical solver as the test's reference) on 8 constant edge
cases, then the gates against the oracle.

Also from the review:

* `solve/1` lists each solution's cost, and the minimum, for `fd_cost`
  problems (the README said it handled costs; it ignored them).
* `info` warns when `run`/`export` will refuse the problem; `show` no
  longer prints an oracle that leaves a constraint out.
* The microcode evaluator raises an error for an unknown name, operator
  or test, instead of reading it as "not marked".
* `decode` of a register-only index (from `run/1`, or typed by hand) no
  longer reports the constant registers as dirty ancillas.
* The microcode printer handles range checks; stale "solve + Grover
  simulate" wording in `info.` and comments is gone.

`rp_test` 84/84, `rp_test(full)` 87/87, `rp_pcode_test` 324/324.

## 2 Oct 2026: `decode/1,2` decodes pasted simulator output

`qsim_run/2` and `qasm3_expand_and_run/2` print raw state indices
(`|00000000000000000000000000000053>  25/100 (25.0%)`). `decode` now
takes such text, one line or a whole pasted block, or a plain index:

```prolog
?- export('examples/factor15.clp').
?- decode('  |00000000000000000000000000000053> ').
  |53>  [p=5,q=3]  ** solution **  (ancillas clean)
```

Each state is split into the problem's variables, checked against the
domains and constraints, and its ancillas are checked; counts and
percentages on the line are kept. The layout comes from the last
`export`, `run_qasm` or `run`, or from a named file:
`decode(Text, 'qasm/factor15.qasm')` (layout and ancillas from the
circuit) or `decode(Text, 'examples/factor15.clp')` (the exporter's
layout; ancillas not checked). `decode(Idx)` used to decode only an
index of the last fast-simulator run. The `help` listing in the User
Guide is brought up to date.

## 1 Oct 2026: the pcode is the fast simulator's oracle again

The oracle microcode (pcode) was designed so that the circuit's search
could be simulated quickly, without simulating its gates. The two
previous entries moved the fast simulator away from that: first to the
classical solution list, then to the constraint checker. It then
showed how Grover search behaves with an ideal oracle, not what the
exported circuit does. This entry restores the original design.

* **`run/1,2` simulates the circuit's oracle.** The oracle is the
  circuit's own pcode (clues substituted, range checks included),
  evaluated by `rp_pcode:pcode_marks/4` in the circuit's register
  widths: add/sub/xor reduced mod 2^W, two's-complement differences,
  sign-bit tests, the multiplier's Bits-wide operands. The state space
  is the circuit's register states (factor15: 256, not the 169 declared
  assignments), with the gate-level simulator's indices (p=3, q=5 is
  |83>). For the same K, the probabilities equal the gate-level
  simulation of the exported circuit.
* **Checked state by state.** Test category 6 compares the fast
  simulator with Grover theory for every state; category 7 also
  compares it with the gate-level circuit for every register state.
  New category 8 pushes every register state through the exported
  oracle's gates classically (X, CX, CCX only) and checks the oracle
  flag against the fast simulator's verdict, and that every ancilla is
  restored. Run on every problem file with at most 100,000 register
  states (31 files, up to 65,536 states): no disagreement, no dirty
  ancilla. The full gate-level simulation (oracle and diffuser, K = 1)
  agrees to rounding error (under 10^-15) on the 19 files small enough
  to finish within 15 minutes.
* **Empty oracle.** A problem with no hard constraints (maxcut) now
  gets an oracle that marks every state, as the microcode says; it
  marked none. The probabilities were the same (the two differ by a
  global phase), but the oracle was not.
* **New options.** `iterations(K)`: run exactly K iterations, no
  search, as an exported circuit with that K. `shots(N)`: sample the
  final state. `analysis(true)`: classify every state (diagnostics).
* **Unsupported constraints are refused** by `run`, `export` and
  `backend(exact)` alike (`rp_grover:circuit_supported/1`):
  `fd_weighted_sum`, `fd_abs_diff`, `fd_min`, `fd_max`, `fd_count`,
  and `fd_product_eq(X, Y, Z)` with Z a variable (the circuit tests the
  product against a constant). `export` used to print a note and write
  a circuit that left the constraint out (or, for `fd_weighted_sum`,
  got it wrong silently); with a variable product it crashed.
  Affected files: `test3` to `test7`, `prob4_cancer_genomics`,
  `prob5_order_partition`.
* An error while evaluating the microcode is reported, not treated as
  "not marked" (which would silently search an empty oracle).
* **`fd_cost` is ignored by the search.** The circuit has no cost
  oracle, and neither does its simulation, so the Dürr–Høyer
  optimisation of the previous entry is withdrawn: it used the
  constraint checker as its oracle. `run` says so and finds a feasible
  state. A cost oracle needs test results held as qubits and a
  weighted sum of them (User Guide §6).
* **A measured state is checked against the constraints**, and a
  disagreement with the oracle's verdict is reported as an oracle
  fault.
* **Bug fixed: duplicate range checks.** A variable whose domain both
  started above 0 and ended below its register's maximum got two
  identical range checks (`(L > 0 ; H < Max)` succeeded twice). Each
  cost a condition flag. factor15: 39 qubits, 762 gates per iteration
  (was 43 and 826).
* Removed: `run_fdspec/2` (the old solve-first simulator; its test now
  uses the fast simulator), `fd_solve_grover/2`, the solution-set and
  optimal-cost oracles, the pcode-versus-constraints side check.

`rp_test` 76/76, `rp_test(full)` 79/79, `rp_pcode_test` 324/324.

## 1 Oct 2026: no classical solve before the quantum search

Until now every quantum path started with a classical brute-force
solve. The number of solutions M set Grover's iteration count, the
minimum cost from the classical optimiser defined the cost oracle, and
(in the previous entry) the fast simulator's oracle was membership in
the classical solution set. A quantum computer cannot know any of
these before searching, so the results overstated what Grover search
does. No quantum path now uses classical solutions, M or the minimum.

* **`run/1,2`: search with unknown M.** Exponential search
  (Boyer–Brassard–Høyer–Tapp): each round draws K uniformly from
  0..⌈m⌉−1, runs K iterations, measures one state and checks it; m grows
  by 6/5 per failed round, up to √N. Budget `budget(B)`·√N oracle calls
  (default 9), then "probably no solution". `seed(S)` makes a run
  repeatable. The oracle is the constraints evaluated on each state.
  (`qsim_pp_grover:grover_search/3`.)
* **`fd_cost`: Dürr–Høyer minimum finding.** Find a feasible state, then
  repeatedly search for a feasible state cheaper than the best so far,
  until a search finds nothing. All 16 cost files reach their true
  minimum.
* **`backend(exact)`: the same search on the gate-level circuit**
  (`rp_decode:exact_search/2`). A one-iteration circuit is generated;
  its preparation is simulated once and its iteration applied K times
  per round. Each measured shot is decoded and checked, including the
  ancillas. factor15: [p=5,q=3] after 30 oracle calls (seed 5). The
  circuit has no cost oracle, so this finds a feasible state.
* **`export`: K is an input.** `export(File, Out, [iterations(K)])`;
  the default is the optimum for one marked state over the circuit's
  register states (factor15: 12). The header says so.
* **`run_qasm`: shots, each checked.** The default output is what
  hardware gives: shots decoded and checked, with an ancilla check per
  shot. `analysis(true)` adds the simulator-only exact table.
* **Range checks without enumeration.** The variables needing a range
  check were chosen by listing the out-of-domain assignments that
  satisfy the constraints, which is solving the problem. Every variable
  whose domain does not fill its register now gets a check. factor15:
  43 qubits (was 37 with one check).
* **`info`, `show`** no longer print M, solutions or an M-based K.
* `solve/1` and `rp_fd_solve` remain as an explicitly classical
  reference. `run_fdspec/2` (the old solve-first simulator) is kept
  only for test category 6, which compares simulated circuits with
  Grover theory for a known M.

`rp_test` 69/69, `rp_test(full)` 72/72, `rp_pcode_test` 324/324.

## 1 Oct 2026: fast simulator oracle

`run/1`'s fast simulator used the compiled oracle microcode (the pcode)
as its oracle. The pcode covers only what the circuit compiler supports,
so for a problem **without `fd_cost`** that uses `fd_abs_diff`,
`fd_min`, `fd_max`, `fd_count` or `fd_weighted_sum`, `run/1` amplified
the wrong states. It still showed the correct `** solution **` labels,
because those come from the classical solver. Example, 2x + y = 5 on
0..3: every state at 6.25%, no amplification.

Problems with `fd_cost` already used the classical solution list, so no
file in `clp/` or `examples/` was affected; every file that uses those
constraints also has costs.

* The oracle is now membership in the classical solution set, looked up
  by state index (`solution_index_set/3`, `qsim_pp_grover.pl`). It is
  correct for every constraint. The example now gives 94.5% on its two
  solutions.
* The cost path uses the same lookup, replacing a linear search of the
  solution list per state.
* The pcode is still run on every state, as a cross-check of the
  circuit compiler. When it disagrees with the classical solutions,
  `run/1` prints a NOTE: the exported circuit would be wrong.
* Output header: "Probabilities (fast simulator, ...)" (was "pcode
  simulator").

`rp_test` 69/69, `rp_pcode_test` 324/324.

## 1 Oct 2026: `rprolog.pl` renamed `rp_engine.pl`; `rprolog/1,2` renamed `run_pcode/1,2`

The reversible Prolog compiler core is now `qclp_gates/rp_engine.pl`,
module `rp_engine`. References are updated in `load.pl`,
`rp_commands.pl`, `rp_ui.pl`, `rp_demo.pl`, comments in `rp_fd.pl` and
`examples/generators.pl`, the README, the user guide and the reversible
Prolog tutorial. The predicates it exports (`rp_compile/3`, `rp_run/3`,
`rp_show/1`, `rp_qasm/2,3`, `rp_set_bits/1`, ...) are unchanged, as is
`rp/1`. Code that loaded the file directly (`use_module(rprolog)`) must
use `use_module(rp_engine)`.

Also in `rp.pl`, two internal predicates are renamed for what they do:

* `rprolog/1,2` → **`run_pcode/1,2`**: the fast (pcode) pipeline behind
  `run/1,2`. It does the classical solve, or the minimum-cost solve when
  there are `fd_cost` terms, then the Grover simulation.
* its helper `rp_fd_oracle_mc/2` → **`pcode_dommap/2`**: it builds the
  index-decoding map for the optimal-cost oracle. It had the same name
  as the real oracle compiler in `rp_fd.pl`.

Neither is a user command; `run/1,2` behaves as before.

## 1 Oct 2026 (evening): shared ancilla registers

Every constraint block in the oracle computes its arithmetic ancillas,
tests them into a condition flag, and uncomputes them before the next
block starts. So the blocks no longer need registers of their own. The
k-th ancilla of every block now uses register `anc_poolK`, which is as
wide as the widest k-th ancilla. A narrower use passes only the low bits
it needs, so the gate logic is unchanged (`anc_pool/4`, `phys_reg/2`,
`phys_arg/2` in `rp_grover.pl`).

Total qubits (registers plus all ancillas):

| Problem | Original (often wrong) | Before | Now |
|---|---|---|---|
| queens4 | 164 | 164 | **75** |
| queens4_anchor1 | 119 | 119 | **66** |
| sparse_test | 175 | 175 | **111** |
| prob3_vertex_cover | 96 | 80 | **52** |
| test1 | 92 | 89 | **61** |
| assign4 | 37 | 60 | **45** |
| number_partition | 57 | 70 | **56** |
| bestcost | 51 | 51 | **42** |
| vertex_cover_triangle | 32 | 32 | **22** |
| factor15, factor21, cubic3, pythagorean | | | unchanged (one constraint block) |
| **All 28 checked circuits** | 1,390 | 1,494 | **1,151** |

Gate counts are unchanged.

**Verification.**

* Every oracle was re-checked classically on every register input. The
  same 21 circuits flag exactly the classical solutions and restore
  every ancilla, as before this change.
* `rp_test(full)` 72/72; `rp_pcode_test` 324/324.

**What dominates now.** In queens4, 34 of the 75 qubits are the
condition flags and AND scratch that combine its 18 constraints. That
is the next place to look.

## 1 Oct 2026 (later still): exact-backend register layout fixed

The exported circuit stores each variable's value directly in its
register, but four things did not follow that through. Circuits whose
domains did not exactly fill their registers were wrong:

| # | Problem | Fix (`rp_grover.pl`, `rp_fd.pl`) |
|---|---|---|
| 1 | Register width came from the number of values, ⌈log₂(High−Low+1)⌉, so larger values could not be stored (`b` in 6..10 got 3 qubits) | `fd_domain_bits/2` is now ⌈log₂(High+1)⌉, the width needed to hold the largest value; `fd_register_bits/2` gives the shared width |
| 2 | A clue (`fd_eq(prod, 21)`) became an ordinary register, put into superposition with `h` | Clues are substituted into the constraints as constants and get no register |
| 3 | Nothing rejected register values outside the declared domain, so the oracle marked "wraparound" states (factor15 also found 1 × 15 and 15 × 1) | The oracle adds a range test `Low ≤ V ≤ High` (phase kind `in_range`, done on the register bits: no subtractor, no constant register). It is added only where needed: QCLP_G enumerates the out-of-domain register assignments that would satisfy the constraints and picks the fewest variables whose tests reject them all (greedy set cover; above 200,000 register states every candidate is checked) |
| 4 | The diffuser sized each variable by its own domain while the registers used the shared width, so with unequal domains it reflected only part of some registers | The diffuser uses the shared width |
| 5 | K was computed for the declared search space, not the register states the circuit really searches | K is chosen for the register space; `info/1` shows both counts and both K values |

The new `rp_grover_circuit_spec/2` builds the spec the oracle is
compiled from. `show/1` prints the circuit's microcode, including the
range checks.

**Verification.** The oracle uses only X, CX and CCX, so it can be
checked classically on every register input. A circuit passes if it
flags exactly the classical solutions and restores every ancilla. Of
the 28 problem files small enough to check:

* before this change: 6 correct;
* after: **21 correct**.

The other 7 use constraints or costs the circuit cannot compile yet
(maxcut, prob2_maxcut, test3–test6). They print a NOTE, or are listed
under known limitations below.

On the gate-level simulator:

* factor21 went from 0% to **99.99%** on a = 3, b = 7.
* factor15 now puts all its probability on the two declared
  factorisations; it no longer shows wraparound states (see the
  walkthrough).

New test 7.8 (offset domains plus a clue) checks the whole circuit
against Grover theory. Results: `rp_test(full)` 72/72,
`rp_pcode_test` 324/324.

**Qubit cost.** A first version added separate `V ≥ Low` and
`V ≤ High` tests on every variable. Each test needs its own condition
qubit plus AND scratch, so factor15 rose to 43 qubits. The final
version merges the two bounds into one test, and adds tests only where
an out-of-domain assignment could otherwise be marked. Domain qubits
(registers plus all ancillas):

| Problem | Before (often wrong) | First fix | Now |
|---|---|---|---|
| factor15 | 35 | 43 | 37 |
| factor21 | 29 | 43 | 37 |
| factor35 | 38 | 61 | 46 |
| assign4 | 37 | 68 | 60 |
| number_partition | 57 | 72 | 70 |
| queens4, simple_neq, bestcost | unchanged | unchanged | unchanged |

What remains comes from two sources:

* All search registers share the widest width. In carry_chain, the
  0/1 variables are padded to 2 qubits and need range checks.
* Domains starting above 0 (assign4's 1..4) need a wider register plus
  a check.

Per-variable register widths and offset encoding would reduce both;
neither is done yet.

Removed from the known limitations below: register width.
`prob4_cancer_genomics` and `prob5_order_partition` still cannot be
exported (`fd_product_eq` with a variable result), as before.

## 1 Oct 2026 (later): decoded results for the exact backend

* **New `run_qasm/1,2`** (`qclp_gates/rp_decode.pl`). It simulates an
  exported circuit and maps every state back to the problem's
  variables. The `.clp` comes from the circuit's `// Example:` header
  or from `source(File)`. It reports:
  - exact probabilities per assignment, summed over the ancillas;
  - `** solution **` / `** wraparound **` markers;
  - a summary, and a check that every ancilla was restored;
  - with `shots(N)`, sampled shots tallied by assignment.
* `run(File, [backend(exact) | Opts])` now prints this decoded report.
  `amplitudes(true)` or `output_reg(N)` still give the raw simulator
  view.
* **Bug found by the decoder (fixed in the entry above): register width.** A
  domain register's width comes from the number of values, but it holds
  the value itself, so domains whose upper values exceed the register
  are broken. `clp/factor21.clp` (`b` in 6..10 in 3 qubits; clue
  `prod` = 21 in a 3-qubit register) exports a circuit with 0% on the
  real answer. Listed as open step 1 in fix report 4; now documented in
  the user guide (§4).

## 1 Oct 2026: bug fixes, sync with QCLP_Q, documentation

### Bugs fixed

| # | Where | Problem | Fix |
|---|---|---|---|
| 1 | `qsim_pp_grover.pl` | `run/1` on a search space smaller than `top(N)` failed (`tiny_neq`: 4 states, default `top(5)`): `length/append` cannot take 5 of 4 | Shows `min(N, states)` |
| 2 | `qsim_pp_grover.pl` | `grover_top/1` prefers a stored `grover_last_solutions`, which only the cost path set. After any `fd_cost` problem, later runs in the same session marked the previous problem's solutions (queens4 after maxcut: no `** solution **` markers) | Every run stores its own solutions |
| 3 | `sv_run.pl` | `:- initialization(main, main)` fired whenever the simulator was loaded as a library: `swipl load.pl` printed the simulator's usage text and **exited** before the prompt, and every scripted `swipl -g ... -t halt` run ended with it | The command-line entry point is registered only when `sv_run.pl` itself is the file launched |
| 4 | `sv_run.pl` | Standalone use (`swipl sv_run.pl -- file.qasm`) crashed: the loader read the global `rprolog_dir` (set only by `load.pl`), and its fallback named a non-existent module (`sv_sim_util`). The usage text named a non-existent `qsim.pl` | Siblings loaded by relative path; usage text corrected |
| 5 | `rp_commands.pl` | `show/1` printed `(296-40 more lines ...)`: the arithmetic was printed, not evaluated | Evaluated |
| 6 | `qasm/` | The four circuits read by test category 1 (`bell_test`, `parity_test`, `xor_test`, `xor`) were missing from the package, so `rp_test` reported 4 failures | Reconstructed from the tests' own descriptions and expected results (each file says so). `rp_test`: 68/68; `rp_test(full)`: 71/71 |
| 7 | `clp/prob5_order_partition.clp` | `fd_cost(10, fd_neq(rt1e, 5))` charged 10 when risk **was** balanced, the reversed-weight mistake QCLP_Q fixed in four other files. It went unnoticed because every value-balanced partition here is also risk-balanced | `fd_cost(10, fd_eq(rt1e, 5))`; header comment corrected (only risk factor 1 is modelled). Same change in QCLP_Q |
| 8 | `clp/prob2_maxcut.clp` | Comment claimed {0,1,2} vs {3,4,5} is optimal; it cuts 5 edges, the optimum {0,1,2,5} vs {3,4} cuts 6 | Comment corrected |

### Changed behaviour

* **Grover iteration count** (`rp_grover.pl`, `rp_grover_iterations_m/3`).
  K now **maximises** the success probability sin²((2K+1)θ) over K ≥ 1,
  taking the smallest K on a tie. It used to stop at the first K reaching
  50%. M/N ≤ 1/2 searches the first period; M/N > 1/2 searches K = 1..8.
  This is now the same code as QCLP_Q's `gsim`. Effects:

  | Problem | M / N | Before | After |
  |---|---|---|---|
  | factor15 | 2 / 169 | K=4, 69% | K=7, 99.6% |
  | queens4 | 2 / 256 | K=4, 51% | K=8, 99.6% |
  | queens4_anchor1 | 1 / 64 | K=3, 59% | K=6, 99.7% |
  | maxcut (cost oracle) | 4 / 32 | K=1, 78% | K=2, 94.5% |
  | tiny_neq | 2 / 4 | K=2 (float rounding), 50% | K=1, 50% |

  Exported circuits contain more iterations, so exact-backend runs take
  longer: factor15 runs in about two minutes.
* **Fast Grover simulator** (`qsim_pp_grover.pl`): QCLP_Q's dense,
  real-valued simulation ported in. The oracle is evaluated once per
  state, not once per state per iteration.
* **`run/1,2` refuses search spaces above 100,000 states** with a clear
  message, as QCLP_Q's `gsim` does. It used to run for minutes or forever
  (sudoku4: N = 67,108,864; prob5: N ≈ 1.8 × 10³³).
* **User-visible names.** The `info/1` banners, generated QASM headers
  (`// Generated by QCLP_G`), the `rp/1` demo output and the test-suite
  title said "RProlog" or "RProlog(FD)". They now say QCLP_G.

### Known limitations (unchanged, now documented)

* The exact backend has no oracle for `fd_abs_diff`, `fd_min`, `fd_max`
  or `fd_count`. `export` prints a NOTE and leaves the constraint **out**
  of the circuit.
* `fd_weighted_sum` as a hard constraint is compiled into the oracle,
  but with too narrow a result register, so the circuit is wrong. **No
  NOTE is printed.**
* Exported circuits ignore `fd_cost`. Only the fast simulator has the
  optimal-cost oracle.
* List domains with gaps become the full range plus `≠` constraints, so
  the search space is larger than QCLP_Q's (prob1: 72,576 states against
  384).
* `rp_verify_adder`, `rp_verify_mod/1` and `rp_verify_mul` compare Prolog
  arithmetic with itself (see fix report 2). They do not test the gates.

### Documentation

* New `README.md` at the package root (replaces `docs/QUICKSTART.md`).
* New `docs/User_Guide.md` merges `RProlog_v4_Tutorial.md`,
  `RProlog_FD_Tutorial.md` and the command reference from the factor15
  walkthrough. Corrected along the way:
  - commands on named examples (`solve(simple_neq)`): only `.clp` paths work;
  - the old iteration-count rule and its table;
  - "clue variables are hidden from output" (they are shown);
  - "uppercase names cause errors" (they work);
  - the dense/sparse simulator threshold (always sparse now);
  - pre-widening qubit counts.
  The guide also documents the constraints the exact backend cannot
  compile.
* `docs/tutorial.md` → `docs/Reversible_Prolog_Tutorial.md`. Removed
  `rp_shor_demo`, `modexp_k_demo`, `rp_shor.pl` and `rp_modexp.pl`, none
  of which exist. The 8-bit adder is 48 qubits, not 128.
* `docs/factor15_walkthrough.md` re-captured with current output.
* Archived to `docs/archive/` with an explanatory README:
  - `EXTENSION_TUTORIAL.md` (`rp_repl`, `qsim_macro` and the Shor
    package do not ship);
  - `rprolog_fd_reference_manual.docx` (documents the retired `rp_fd/1`
    interface).
* `qclp_gates/FIX_REPORT*.md` merged into this file (below).
* New `docs/SHARED_COMPONENTS.md`.

## Fix report 4 (30 Sep 2026): QCLP front-end conformance

*Originally `qclp_gates/FIX_REPORT_PART4.md`; reproduced unchanged. File names refer to `qclp_gates/`; at the time the package was called RProlog.*

QCLP's 29 test files (identical to RProlog's `clp/` folder, plus
`vaz.clp`) were checked against an independent SWI-Prolog CLP(FD)
reference. As written, RProlog's classical solver got the right
feasible set for 13 of them. After these fixes it gets 25. vaz now
stops with a clear error, and sudoku4, sudoku9 and prob5 still time
out in the brute-force solver. Full details are in the
"RProlog vs QCLP conformance report" doc.

### Changes

| File | Change |
|------|--------|
| `rp_fd.pl` | **List domains follow QCLP:** each element is `N` or `Lo-Hi` (Lo to Hi inclusive; negative bounds fine), and overlaps merge. `Lo-Hi` is a term, never subtraction. Previously `[0,2-3]` became −1..0 and gaps were lost. Bad lists (`[6-2]`, `[]`, `[1,a]`) are errors naming the variable. |
| `rp_fd.pl` | **Domains intersect:** every restriction on a variable (`fd_domain/3`, `fd_domain/2`, an `fd_eq(V,C)` clue) is read as a value set, and all of them are intersected in any order. Previously the first won, so QCLP's usual "domain, then clue" order dropped every clue, including all sudoku givens. An empty intersection warns and gives 0 solutions. Sets are interval lists, so large ranges stay cheap. |
| `rp_fd.pl` | **Gaps** are stored as `dom(V,Min,Max)` plus one `con(neq,[V,Gap])` per missing value, so the classical solver, pcode and the exact circuit all see them unchanged. |
| `rp_fd.pl` | **No silent failures:** an unrecognised constraint (e.g. `fd_xor`) is now an error listing what is supported; it used to be `con(unknown,_)`, treated as always satisfied. `fd_cost` is validated at compile time (numeric weight, known inner constraint, no nesting). |
| `rp_fd.pl` | **Costs use the full evaluator:** `check_one_cost/2` now reuses `check_constraint/2`, so every constraint type can carry a cost. The old evaluator covered 9 types and scored 0 for the rest, e.g. `fd_cost(W, fdsumeq(...))`. |
| `rp_fd.pl` | The "Minimum cost" message printed the solution list; it now prints the count. |
| `rp_spec.pl` | **Capitalised names** (`StartA`, `M`, `N`) are read with `variable_names` and bound to their own names, instead of staying Prolog variables that no constraint could match (bestcost, test5 and test6 had 0 solutions). An anonymous `_` in a spec is an error. |
| `rp_test.pl` | New tests 3.11–3.23 for all of the above. |

### Verification

* `rp_test(full)`: 67/67. `rp_pcode_test`: 324/324.
* Mutation check: tests 3.17–3.23 all fail on the pre-fix code, as do
  3.11, 3.12, 3.14 and 3.16 on the old list parser.
* QCLP files as written, compared set by set with the reference:
  25/29 match (previously 13).
* Exact circuits unchanged, as expected: their remaining problems
  are in the exact backend (next steps below). bestcost's circuit is
  now correct as written.

### Addendum (30 Sep): `fd_cost` now follows QCLP's rule

| File | Change |
|------|--------|
| `rp_fd.pl` | `fd_cost(W, C)`: a positive W is a **penalty** added when C is **violated**; a negative W is a **reward** added when C **holds**; W = 0 has no effect. This is QCLP's rule (its evaluator, QUBO compiler and README). RProlog used to add W whenever C held, whatever its sign; negative weights behave the same under both rules, so only positive weights changed. |
| `clp/` | assign4, bestcost, prob3_vertex_cover and prob4_cancer_genomics replaced by QCLP's corrected versions; they had been written for the old reading. `clp/` is now identical to QCLP's `tests/` (QCLP also has `vaz.clp`). |
| `docs/RProlog_v4_Tutorial.md` | States the rule. |
| `rp_test.pl` | Tests 3.24–3.27. 3.24 and 3.27 fail on the old rule. |

Verification: `rp_test(full)` 71/71, `rp_pcode_test` 324/324. All 17
example files with costs that RProlog can finish give the same optimal
set and the same minimum cost as the independent CLP(FD) reference under
QCLP's rule, so RProlog and QCLP's `eval` now agree on all of them.

### Not changed (next steps, in order)

1. Exact backend: store values relative to the domain's low end and
   reject out-of-range register values (fixes most wrong circuits).
2. Oracle support for `fd_xor`, `fd_abs_diff`, `fd_min`, `fd_max`,
   `fd_count`, `fd_weighted_sum`, and `fd_product_eq` with a
   variable result.
3. Decide how the exact backend treats costs (today the oracle marks
   the optimal assignments found classically).
4. A faster classical solver (propagation, or SWI CLP(FD)).

Known limitation: a domain with big gaps, e.g. `[0,300]`, becomes 299
`≠` constraints. A single "value in set" constraint would be better
and fits naturally with step 1.

## Fix report 3: exact-backend arithmetic

*Originally `qclp_gates/FIX_REPORT_PART3.md`; reproduced unchanged. File names refer to `qclp_gates/`; at the time the package was called RProlog.*

### Symptom

`run('examples/queens4_anchor1.clp', [backend(exact)])` came back exactly
uniform at every iteration count K, while the pcode backend showed
correct amplification (59% on q1=3, q2=0, q3=2).

### Root cause: modular wraparound in add/sub ancillas

Every add/sub result register was declared at the **domain width**
(2 bits for 0..3), so the oracle computed `X+Y` and `X+Y−Z` mod 4.

* `fd_sum_neq(q1,1,q2)` with q1=3, q2=0: 3+1 = 4 ≡ 0 = q2, a false
  diagonal clash. That rejects the only solution of queens4_anchor1, so
  the oracle marked **zero** states. Grover with an empty marked set is
  the identity on the uniform state, hence "uniform at K=1, 2, 4".
* Full queens4 lost **both** of its solutions the same way (oracle
  marked 0 of 2). Queens5 was lucky: 3-bit registers happen to leave
  its 10 solutions intact.
* The same width problem breaks the sign-bit tests behind
  `fd_lt/le/gt/ge`. A difference of two 2-bit values needs 3 bits of
  two's complement (0−3 = −3 = `01b` in 2 bits, so the sign bit is clear).

### Fixes

| # | File | Change |
|---|------|--------|
| 1 | `rp_grover.pl` | New `anc_width_map/3`: an add/sub result is **one bit wider than its widest operand** (integer operands count at their own bit length). The exact sum or difference always fits, so no chain of add/sub can wrap. xor keeps its operand width; mul keeps 2·Bits. `effective_bits/4` consults the map. |
| 2 | `rp_grover.pl` | Operands narrower than the gate are **zero-extended at the call site** from dedicated all-\|0⟩ pad registers (`pad_a`, `pad_b`; kept separate because the Cuccaro adder uses operand *a* as its carry chain). |
| 3 | `rp_grover.pl` | `gt_zero` was the bare sign-bit test, identical to `ge_zero`, so `fd_lt`/`fd_gt` behaved as `≤`/`≥`. It is now (sign clear) XOR (value = 0). |
| 4 | `rp_gates.pl` | `rp_inc_qasm` (the +1 inside subtraction) emitted its MCX steps **LSB-first**. Each step must read the original lower bits, so it must go MSB-first as its own comment says. This was invisible at ≤3 bits (a single MCX) but wrong at 4+, which the widened registers now reach. |
| 5 | `rp_gates.pl` | `inc_mcx_line` for I ≥ 4 only ANDed Z0, Z1, Z[I−2], Z[I−1]. That is right for I=4 but drops bits from I=5 up. Replaced with a general clean AND ladder. |
| 6 | `qsim_pp_grover.pl` (pcode backend) | The diffuser only updated states already in the sparse map, and states whose amplitude hit 0 were pruned. So a state that passed through zero never came back: simple_neq (M=12, N=16) lost all 12 solutions after iteration 1 and reported 0% instead of 75%. It now diffuses over all N states. |

### Test-suite fixes (these hid failures)

* **`run_test/2` never reported ordinary failures.** Its else-branch
  checked `nb_getval(rp_test_fail, _)`, which always succeeds once the
  counters exist, so any failing goal that did not throw was neither
  printed nor counted. With that fixed, the original code shows
  **18 failures out of 54** tests (not "36/36 passed").
* Consecutive tests in one clause shared variable names (`Q`), so the
  first test's binding made the next one fail to unify (2.2–2.8).
  `run_test/2` now runs a `copy_term` of each goal.
* Stale fixtures: category 2 read a dense `sv(...)` state (the
  simulator returns `sparse/2`); 1.10 expected index 5 (the circuit
  gives a=1, b=3, so index 13); 5.5 searched for the word "uncompute"
  (the emitter writes `inv @`); 6.4 indexed pcode results in binary,
  but pcode uses mixed radix (this only differs for non-power-of-2
  domains).
* **New category 7: exact backend vs Grover theory.** Each test exports
  the real circuit, runs it on `sv_sim`, marginalises onto the domain
  registers, and requires every state to match
  sin²((2K+1)θ)/M or cos²((2K+1)θ)/(N−M) within 1e-3. It also requires
  a single fixed pattern on all non-domain qubits (clean ancillas).
  Before this, the "end-to-end" tests only ran the pcode path, so the
  compiled oracle had no end-to-end coverage. All 6 new tests fail on
  the old code and pass on the new.

### Verification

* `rp_test(full)`: **54/54** (old code: 36/54 once failures are counted).
  `rp_pcode_test`: **324/324** (unchanged).
* Exhaustive classical oracle check, independent of the simulator. The
  oracle is X/CX/CCX only, so I bit-simulated it on every in-domain
  input and checked flag ⇔ constraints plus all ancillas restored.
  Passes: queens4, queens4_anchor1, queens5, coloring3, pythagorean7/13,
  sum_eq, simple_neq, and every constraint kind (neq, lt, le, gt, ge,
  sum_eq, sum_neq, const operands) at 2-, 3- and 4-bit domains.
  No file got worse than on the old code.
* queens4_anchor1 on the exact backend: **59.138%** on (q1,q2,q3)=(3,0,2),
  0.6486% on each other state. That matches theory for N=64, M=1, K=3
  to four decimals.

### Cost

Wider registers mean more qubits: queens4_anchor1 91→119,
queens4 117→164, queens5 253→326. The sparse simulator ran
queens4_anchor1 in ~80 s.

### Not changed / worth knowing

* The iteration count heuristic picks the **first** K with P ≥ 50%.
  For queens4_anchor1 that is K=3 (59%). K=6 would give 99.7%.
* `rp_pcode_test`'s 324 cases compare the pcode evaluator with the
  classical checker. They do not exercise the gate-level circuit.
* Some `clp/` files (weighted sums, costs, products) aren't handled by
  my external checker, and weren't re-verified by it. Their pass/fail
  status there is identical before and after these changes.

## Fix report 2: the gate array-parameter bug

*Originally `qclp_gates/FIX_REPORT_PART2.md`; reproduced unchanged. File names refer to `qclp_gates/`; at the time the package was called RProlog.*

This continues `FIX_REPORT.md` (the `rp/2` typo). This part covers the
much larger fix: the same `gate` array-parameter defect found and
fixed in mu_RProlog, present here too — plus several more bugs found
along the way while actually trying to get a real circuit to parse
*and* verify correctly, not just parse.

### Bottom line

**Fully fixed and numerically verified**: any constraint built from
`rev_xor` (equality/inequality-style constraints: `simple_neq`,
`simple_eq`, and similar) now compiles to real, valid OpenQASM 3.0
that Qiskit loads and simulates correctly — confirmed to match Grover
theory exactly (see below).

**Partially fixed**: constraints using `rev_add`/`rev_sub`
(`sum_eq` and similar) now compile to syntactically valid QASM that
Qiskit loads without error — but numeric verification uncovered a
genuine, pre-existing mathematical bug in the adder's own gate
sequence (`rp_adder_qasm` in `rp_gates.pl`), unrelated to QASM3 syntax
and **not fixed**. See "What's still broken" below.

### Fixed and verified (syntax + composition)

1. **The core bug**: `gate` bodies had array-typed formal parameters
   with internal indexing (`gate xor_2bit(a, b, c) { cx a[0], c[0];
   ... }`) — invalid OpenQASM3. Fixed generally: every register
   becomes scalar per-bit parameters (`gate_def_lines2/5`), and any
   inline scratch declaration found in a gate body is stripped,
   promoted to a real top-level register, and threaded through as an
   extra parameter everywhere it's used. This turned out to be
   necessary almost everywhere — even the diffuser's own
   multi-control chain needed it, not just multiplication.

2. **`carry` was never declared anywhere**, not even inline — a more
   basic defect than the array-parameter issue. Fixed by synthesizing
   the missing declaration so the same generic mechanism picks it up.

3. **Gate qubit-parameter lists must not be parenthesized** in
   OpenQASM3 when there's no classical parameter list (confirmed by
   tracing Qiskit's own parser: `gateStatement.qubits` is a separate
   grammar production from the optional `(...)` classical-parameter
   list). The original code — and my first pass — had this wrong.

4. **Reserved-word collisions**: domain variables named `x`/`y`
   collide with the built-in Pauli-X/Y gates in `stdgates.inc`. Fixed
   with a uniform `v_` prefix (`safe_reg_name/2`) applied consistently
   everywhere a wire name becomes a QASM identifier.

5. **Classical integer operands passed as qubit arguments** (e.g. the
   `5` in `x + y = 5` was emitted as `5[0], 5[1], 5[2]` — the same bug
   class fixed in mu_RProlog). Fixed by synthesizing a `const_V`
   register per distinct value, prepared via X-gates once before the
   Grover loop, and threading it through like any other scratch
   parameter — including keeping a raw `Value-Width` form until the
   last possible moment so the value is still available for the
   X-gate preparation step (`const_prep_lines/2`), not just the name.

6. **A self-controlled Toffoli in the diffuser's N≥4-control chain**
   (`ccx diff_anc1[0], y0, diff_anc1[0]`) — the same bug class already
   fixed once in the *other* uploaded project (`meta_complete2`).
   Root cause: `diff_chain_fwd/5` independently reconstructed an
   ancilla name at each recursion level using an index the caller had
   already assigned to a different register. Rewritten so each
   recursion level allocates a strictly fresh index and folds its own
   newly-produced accumulator directly into the next level's control
   list — provably no index is ever reused.

7. **A silently-dropped constraint step.** `oracle_body_lines2_`
   (and the *original*, pre-my-fix `oracle_body_lines/4` — this one
   predates my changes) assumed every `next(Anc,Expr)` event is
   immediately followed by its own `flag_test(Anc,Kind)`. Multi-step
   constraints like `sum_eq` actually produce
   `[next(Anc1,X+Y), next(Anc2,Anc1-Z), flag_test(Anc2,eq_zero)]` —
   two chained `next` events before one `flag_test`. The old pattern
   silently skipped the first `next` entirely (no error, no warning —
   `fd_anc1` just stayed at `|0⟩` forever). Fixed by generalizing to
   consume a whole run of chained `next` events, computing each in
   order, phase-testing the last one, then uncomputing in reverse.

Each of these was found by chasing the *previous* one's fix through
to an actual Qiskit parse/simulate, the same way as mu_RProlog. All
were re-verified against the full 35-test suite after every change:
**still 35/35 throughout.**

### Numeric verification

**`simple_neq`** (`rev_xor` only): built the real circuit, ran it on
`qiskit-aer`, and measured `P(solution) = 0.7533` over 20,000 shots —
matching the exact Grover-theory prediction of `0.75` for this
M=12,N=16,K=2 case (the angle happens to put K=1 at a dead zone and
K=2 back at the uniform baseline — verified this is expected, not a
bug, by hand-deriving the same value from `sin²((2k+1)θ)`).

**`sum_eq`** (`rev_add`/`rev_sub`, exercises `carry` and the constant
register): parses correctly, and `add_3bit` in isolation *does*
correctly compute `c = a+b`. But it *also* leaves `b` modified — for
`x=1, y=4`: after `add_3bit`, `fd_anc1 = 5` (correct sum) but `y` also
reads back as `5`, not restored to `4`. This is a real defect in
`rp_adder_qasm`'s own Cuccaro-derived gate sequence (in `rp_gates.pl`,
a file I did not modify), not something introduced by this fix. Given
the compute/uncompute pairing this whole system relies on assumes `b`
is either preserved or correctly restored, this breaks the oracle's
marking for any add/sub-based constraint — confirmed by checking the
oracle-only phase kickback: **every** state (marked and unmarked
alike) comes back with identical `+0.125` amplitude, meaning the
oracle never actually flips a phase.

### What's still broken (found, not fixed — out of scope for this pass)

**The adder's own gate sequence doesn't preserve its `b` operand.**
This is a mathematical/gate-design bug in `rp_gates.pl`, not a syntax
bug — fixing it means re-deriving or re-verifying the actual
Cuccaro-adapted circuit (present in `rp_adder_qasm`/`rp_sub_qasm`), a
genuinely different kind of work from what this pass covered.
`rp_gates.pl` also ships an `rp_verify_adder/0` "verification"
predicate — worth flagging clearly: it's tautological
(`sim_add(A,B,S) :- S is A+B.` compared against `E is A+B` — these are
the same computation, so the check can never fail regardless of
whether the real gate sequence is correct). It always reports "all
correct" and does not touch the actual generated gates at all — the
same pattern found in every one of these projects' self-tests this
session.

**Not attempted**: multiplication (`rev_mul`) and mod (`rev_mod`) —
the general array-parameter/scratch-hoisting mechanism should apply to
them structurally the same way it did everywhere else, but I haven't
run them, and given `rp_adder_qasm` (which `rev_mul` presumably builds
on top of, per its own module comment) has the `b`-preservation bug
above, multiplication almost certainly inherits it too.

### Files changed

```
rp.pl         -- rp/2 typo + doc fixes (see FIX_REPORT.md)
rp_grover.pl  -- everything else above
```

`rp_gates.pl` (the arithmetic gate bodies themselves) was **not**
modified — the bug found there is reported, not fixed.

## Fix report 1: the `rp/2` typo

*Originally `qclp_gates/FIX_REPORT.md`; reproduced unchanged. File names refer to `qclp_gates/`; at the time the package was called RProlog.*

### What was fixed

**One-line bug**, `rp.pl` line 88:
```prolog
rprolog(Source) :- rp(Source, []).      % before: calls nonexistent rp/2
rprolog(Source) :- rprolog(Source, []). % after: fixed
```
`rp/2` doesn't exist anywhere in the codebase (only `rprolog/2` does, and an
unrelated `rp/1` in `rp_ui.pl` for a different subsystem's command
dispatcher). Every call to the single-argument `rprolog(File)` — the
form the load banner itself advertises — crashed with
`Unknown procedure: rp:rp/2`.

**Seven documentation corrections**, same file: every example command
that said `rp('tests/queens4.clp')` (in header comments, the `help`
text, and the load-time banner) now correctly says
`rprolog('tests/queens4.clp')`. This was the actual root cause of the
confusion — the code was internally consistent (`rprolog/1` calling
`rprolog/2`, once fixed), but every place a user would learn the
command name told them to call something else entirely, which happened
to collide with an unrelated predicate in a different subsystem.

### Verification

```prolog
?- [load], rprolog('../tests/tiny_neq.clp'), halt.
```
now runs the full pipeline directly — loads the file, solves it
classically (2 solutions, matching the original QCLP tool's result for
this same file), and runs the Grover simulation — with no workaround
needed.

Full existing test suite re-run after the change: **35 passed, 0
failed** (unchanged from before — this fix didn't touch anything the
suite exercises, since the suite calls the FD compiler directly and
never went through the broken entry point in the first place, which is
exactly how this bug went uncaught).

### Not fixed (see prior message for full detail)

The `gate` array-parameter bug (same defect class as mu_RProlog, but
recurring at three nested levels here — primitive gates, the oracle
gate, and the diffuser gate) is still present. Scoped but not
attempted, pending a decision on whether to take on that larger pass.

### Files changed

```
rp.pl   -- only file touched
```
