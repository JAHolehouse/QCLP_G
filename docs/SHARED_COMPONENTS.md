# Shared Components: QCLP_G and QCLP_Q

QCLP_G (Grover / logic-gate compiler) and QCLP_Q (QUBO / QAOA compiler)
are shipped as two separate packages, but they share code and test
problems. This file records what is shared, what is deliberately
different, and how the two drifted apart before the sync of 1 Oct 2026.
The same file ships in both packages (`docs/SHARED_COMPONENTS.md`).

## 1. What is shared

| Component | QCLP_G | QCLP_Q | Status |
|---|---|---|---|
| Statevector simulator core | `qclp_gates/sv_sim.pl` | `sv_sim/sv_sim.pl` | **Identical file** |
| Simulator utilities | `qclp_gates/sv_util.pl` | `sv_sim/sv_util.pl` | **Identical file** |
| Simulator driver (`qsim_run/1,2`) | `qclp_gates/sv_run.pl` | `sv_sim/sv_run.pl` | **Identical file** |
| QASM 3 macro expander | `qclp_gates/qasm3_macro_pp.pl` | `sv_sim/qasm3_macro_pp.pl` | **Identical file** |
| Grover iteration formula (K for a known M) | `qclp_gates/rp_grover.pl`: `rp_grover_iterations_m/3` | `grover_sim/rp_grover.pl` | **Same code**; the rest of G's file is the circuit generator. Searches do not use it (M is unknown); G uses it with M = 1 for the default K of an exported circuit |
| Grover search with unknown M (exponential search, BBHT) | `qclp_gates/qsim_pp_grover.pl` | `grover_sim/qsim_pp_grover.pl` | **Same search**, different oracles and state spaces (see §2) |
| Problem files | `clp/*.clp` | `tests/*.clp` | **Identical**, except `vaz.clp`, which is Q-only (`fd_xor`, unsupported by G's compiler) |

The four identical files can be copied from one package to the other
unchanged. After any edit to one of them, copy it across and check:

```bash
for f in sv_sim.pl sv_util.pl sv_run.pl qasm3_macro_pp.pl; do
  cmp QCLP_G/qclp_gates/$f QCLP_Q/sv_sim/$f || echo "OUT OF SYNC: $f"
done
```

## 2. What is deliberately different

**The Grover front end.** QCLP_Q's `grover_sim/` is *not* a copy of
QCLP_G's modules. It is a small, separate implementation that reuses
the module names `rp_fd`, `rp_pcode` and `rp_grover`:

| | QCLP_G (`rp_fd.pl`, ~1,150 lines) | QCLP_Q (`grover_sim/rp_fd.pl`, ~210 lines) |
|---|---|---|
| Role | Full constraint compiler: domains, oracle microcode, cost evaluation, classical reference solver, feeds the QASM circuit generator | Constraint check (the oracle) for `gsim` only |
| Spec it reads | Compiled `fd_spec(Domains, Constraints)` | The raw `problem_spec` list |
| List domains (`[0, 11]`) | Stored as the range `0..11` plus one `≠` constraint per gap | Stored as the actual value list |
| Search space for `prob1_number_partition` | N = 72,576 | N = 384 |
| Constraint checker | `check_constraint/2` | `holds/2`, mirrors `clp_evaluator` |
| `fd_xor` | Not supported (error) | Supported |
| Oracle of the fast simulator | The circuit's own microcode (pcode) in the circuit's register widths, over the circuit's register states: the same probabilities as the gate-level circuit | `holds/2` on each declared assignment |
| `fd_cost` | **Ignored** by `run/1` (no cost oracle yet) | `gsim/1` **ignores costs** too (use `eval/1` or `qsim/1` for optimisation) |

Because the module names collide, **never load both packages into one
Prolog session.**

The two `qsim_pp_grover.pl` files share the search: dense, real-valued
amplitudes, inversion about the mean, and the exponential search for an
unknown number of solutions (each round: K iterations with K drawn from
a growing range, one measurement, one check). Neither solves the
problem classically first. They differ in what they simulate. G's
simulates its exported circuit: the oracle is the circuit's pcode,
evaluated over the circuit's register states, so for the same K it
matches the gate-level simulation state by state. Q's searches the
declared assignments with the constraint check as its oracle, because
QCLP_Q builds no Grover circuit. Entry points: G `grover_search/3`,
Q `run_fdspec/2,3`.

## 3. How the packages drifted apart

Each package had its own fix passes, and fixes to shared files were not
copied across:

| Fix | Made in | Was missing from |
|---|---|---|
| In-memory macro expansion before every simulation; `qsim_run_string/1,2`; `qasm3_expand_and_run/1,2` | QCLP_G (`sv_run.pl`, `qasm3_macro_pp.pl`) | QCLP_Q |
| Accept unparenthesised gate headers and calls (`gate NAME a, b {`), the only form valid OpenQASM 3 allows without classical parameters (G fix report 2, note 3) | QCLP_G (`qasm3_macro_pp.pl`) | QCLP_Q |
| Grover iteration count chosen to maximise success probability (not the first K reaching 50%) | QCLP_Q (`grover_sim/rp_grover.pl`) | QCLP_G |
| Dense simulation, oracle evaluated once per state (test7 from >10 min to ~18 s) | QCLP_Q (`grover_sim/qsim_pp_grover.pl`) | QCLP_G |
| Search-space limit of 100,000 states with a clear error | QCLP_Q (`gsim`) | QCLP_G (`run`) |
| Diffusion over all N states (states passing through zero were lost) | Both, independently | — |

## 4. The sync of 1 Oct 2026

* `sv_run.pl` and `qasm3_macro_pp.pl`: QCLP_G's newer versions copied to
  QCLP_Q, after fixing two bugs in `sv_run.pl` (below).
* `rp_grover_iterations_m/3`: one rule for both packages (later the
  same day, both packages stopped choosing K from M: see §5). K maximises
  sin²((2K+1)θ) over **K ≥ 1**, taking the smallest K on a tie. QCLP_Q's
  earlier fix allowed K = 0. That is dropped, because K = 0 exports a
  circuit with no oracle. For moderate M/N some K ≥ 1 matches or beats
  K = 0 (M = 12, N = 16: K = 2, 75%). Only when nearly every state is a
  solution does K = 0 do better (M = 319, N = 327: 97.6% against 79.4%),
  and such a problem does not need Grover.
* QCLP_G's `qsim_pp_grover.pl`: QCLP_Q's dense simulator ported in.
* QCLP_G's `run/1,2`: QCLP_Q's 100,000-state limit ported in.
* Bugs fixed in both: `grover_top/1` failed when asked for more states
  than exist (`tiny_neq`, 4 states, `top(5)`). `sv_run.pl` registered
  `initialization(main, main)` unconditionally, so `swipl load.pl`
  printed the simulator's usage text and exited, and every scripted run
  ended with it. It also crashed when loaded on its own.

The full list is in each package's `CHANGELOG.md`.

## 5. No classical solve before the search (1 Oct 2026)

Both packages used to enumerate the solutions classically before
"searching", and took the number of solutions M, the oracle (QCLP_Q,
and G's fast simulator) and the minimum cost (G) from it. That is
removed from every quantum path. `gsim` and `run` use the exponential
search with unknown M; G's `export` takes K as an input (default:
optimum for one marked state). Later the same day G's fast simulator
was made to simulate its circuit's oracle (the pcode) again, and the
Dürr–Høyer optimisation briefly added to it was withdrawn, since the
circuit has no cost oracle. `eval` (Q) and
`solve` (G) remain as explicitly classical reference solvers.
