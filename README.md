# QCLP_G — Quantum Constraint Logic Programming (Grover / logic gates)

QCLP_G compiles finite-domain constraint problems into Grover search
circuits built from reversible logic gates (X, CX, CCX, H), written as
OpenQASM 3.0. You write the problem as a `.clp` file of domains and
constraints. QCLP_G compiles it into oracle microcode (the *pcode*),
from which it builds the circuit. A fast simulator evaluates the same
pcode over the circuit's register states, so it shows what the circuit
does without simulating its gates; the gate-level statevector
simulator runs the circuit itself. For the same number of iterations
the two give the same probabilities.

No quantum path solves the problem classically first: the number of
solutions is never computed, and the search works without it, as it
would have to on a quantum computer.

QCLP_Q, the sibling package, compiles the same `.clp` files to QUBO and
QAOA circuits instead. See `docs/SHARED_COMPONENTS.md` for what the two
packages share.

> **Formerly RProlog.** The package, its folder (`rprolog/` → `qclp_gates/`)
> and its messages were renamed QCLP_G. The internal module names
> (`rp_fd`, `rp_grover`, `rp_engine`, ...) and the `rp/1` command keep the
> old prefix.

## 1. Prerequisites

SWI-Prolog 9.x (tested with 9.0.4 on Win11).

```bash
# Ubuntu/Debian
sudo apt-get install swi-prolog-nox
# macOS
brew install swi-prolog
```

## 2. Layout

```
QCLP_G/
├── load.pl            entry point: load this file
├── README.md          this page
├── CHANGELOG.md       what changed, and why
├── VERSION
├── qclp_gates/        the compiler, simulators and tests (Prolog source)
├── clp/               hand-written .clp problems (same files as QCLP_Q's tests/)
├── examples/          generated .clp problems + generators.pl (separate tool)
├── qasm/              QASM output from export/1, plus test fixtures
└── docs/
    ├── User_Guide.md                  writing .clp files, every command, backends
    ├── factor15_walkthrough.md        one problem end to end, with real output
    ├── Reversible_Prolog_Tutorial.md  rp/1: compile Prolog predicates to circuits
    ├── SHARED_COMPONENTS.md           files shared with QCLP_Q
    └── archive/                       retired documents
```

## 3. Quick start

From the `QCLP_G` directory:

```bash
swipl --stack_limit=256M
```
```prolog
?- [load].
```
```
QCLP_G commands loaded. Type help. for usage.

QCLP_G loaded.  Type  info.  for more information.
```

You can also start with `swipl --stack_limit=256M load.pl`.

```prolog
?- help.                          % the command list
?- examples.                      % .clp files in clp/ and examples/
?- run('examples/factor15.clp', [seed(1), top(3)]).  % Grover search, unknown M
```
```
[rp] examples/factor15.clp
[grover] circuit oracle (pcode): 2 registers x 4 qubits = 256 register states
[grover] exponential search (unknown M), budget 144 oracle calls
[grover]   round 1: K=0, measured |198> [p=6,q=12]: checked, not a solution
...
[grover]   round 8: K=3, measured |53> [p=5,q=3]: checked, a solution
[grover] found [p=5,q=3] after 6 oracle calls

Final state after K=3 (simulator view, not measurable on hardware):
Top 3 of 256 register states by probability:
  |53>     16.8577%  [p=5,q=3]  ** solution **
  |83>     16.8577%  [p=3,q=5]  ** solution **
  |0>       0.2610%  [p=0,q=0]
```

Each round runs the search for a random number of iterations K from a
slowly growing range, measures one state, and checks it. This finds a
solution in O(√(N/M)) oracle calls without knowing M.

## 4. Commands

Every command takes the path of a `.clp` file.

| Command | What it does |
|---|---|
| `run(File)`, `run(File, Opts)` | Grover search with unknown M on the fast simulator of the circuit's oracle; `iterations(K)` runs a fixed K instead, `shots(N)` samples the result |
| `run(File, [backend(exact) \| Opts])` | The same search, on the gate-level circuit |
| `run_qasm(Qasm, Opts)` | Run an exported circuit as written: shots, decoded to variables, checked, with an ancilla check |
| `solve(File)` | Classical reference solver (not used by any quantum path) |
| `info(File)` | Domains, qubit budget, search space, register states |
| `show(File)` | `info` plus oracle microcode and the first 40 QASM lines |
| `export(File)`, `export(File, Out)`, `export(File, Out, [iterations(K)])` | Write the OpenQASM 3.0 circuit (default `qasm/<name>.qasm`, K optimal for one solution) |
| `top`, `top(N)` | Re-inspect the last run's final state |
| `decode(Text)`, `decode(Text, File)` | Decode pasted simulator output, e.g. `decode('  \|0000000053>  25/100 (25.0%)')`: variables, check, ancillas |
| `qsim_run("f.qasm", Opts)` | Simulate any QASM 3 file |
| `rp_test`, `rp_test(full)` | Test suite (84 fast tests; 87 with the slow circuit tests) |

The full guide, including the constraint language, is
`docs/User_Guide.md`.

**Current limits.** `fd_weighted_sum`, `fd_abs_diff`, `fd_min`,
`fd_max`, `fd_count` and `fd_product_eq` with a variable product cannot be compiled into the oracle yet, so
`run`, `export` and `backend(exact)` refuse problems that use them.
`fd_cost` is ignored by the search (there is no cost oracle yet).
`solve/1` handles both, classically: it lists every solution, with its
cost and the minimum when there are costs. Negative constants are
refused by the circuit path (registers are unsigned).

## 5. Two subsystems

1. **Constraint compiler** (`run`, `export`, `run_qasm`, ...): `.clp` file
   → Grover oracle → circuit. Covered by `docs/User_Guide.md`.
2. **Reversible Prolog compiler** (`rp/1`): an ordinary Prolog predicate
   → reversible circuit (adders, modular arithmetic, ...). Covered by
   `docs/Reversible_Prolog_Tutorial.md`.

Do not load QCLP_G and QCLP_Q into the same Prolog session. Some of
their internal modules share names.
