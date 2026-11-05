# QCLP_G User Guide

This guide covers the constraint compiler: writing `.clp` problem files,
every command, the two simulators, optimisation with `fd_cost`, and the
statevector simulator. For installation and a five-minute start, see
the package `README.md`. For a single problem taken end to end with real
output, see `factor15_walkthrough.md`.

This guide replaces the separate RProlog v4 Tutorial, RProlog(FD)
Tutorial and `QUICKSTART.md`. All output below was captured from the current
code.

---

## 1. How it works

```
.clp file ──► constraints ──► oracle microcode (pcode) ──┬─► QASM circuit       export/1,2,3
                                                          │     ├─► gate-level search     run/2 backend(exact)
                                                          │     └─► run as written, shots run_qasm/1,2
                                                          │
                                                          └─► fast simulator    run/1
                                                                (the same oracle, evaluated directly)
```

**The pcode is the oracle.** The constraints are compiled once into
oracle microcode, the *pcode*: a short list of steps such as
`fd_anc1 := p*q` and `test fd_anc1 = 15`. The circuit generator turns
each step into reversible gates. The fast simulator evaluates the same
steps directly, in the same register widths, over the same register
states. So for the same number of iterations K, `run/1` gives the
probabilities the gate-level simulation of the exported circuit gives,
in a fraction of the time. The test suite checks this state by state.

**No path solves the problem first.** The number of solutions M is
never computed, as it could not be on real hardware. `run` uses the
exponential search of Boyer, Brassard, Høyer and Tapp: each round picks
a random iteration count K from a range that grows by 6/5 per round,
runs the search, measures one state and checks it. Checking a candidate
is cheap; finding one is what Grover search is for. The expected number
of oracle calls is O(√(N/M)) without knowing M.

**Limits.**

- Constraints the pcode cannot express yet (`fd_weighted_sum`,
  `fd_abs_diff`, `fd_min`, `fd_max`, `fd_count`, and `fd_product_eq`
  with a variable product) are refused by `run`, `export` and
  `backend(exact)` alike (§2).
- There is no cost oracle yet: `fd_cost` is ignored by the search, which
  finds a state satisfying the hard constraints (§6).

`solve/1` is a separate, explicitly classical reference solver. No
quantum path uses it.

The application only ever reads `.clp` files. Parametric families
(`factor(N)`, `queens(N)`, ...) are written out as `.clp` files by a
separate tool (§8).

---

## 2. Writing a `.clp` file

A `.clp` file holds one Prolog fact, `problem_spec/1`:

```prolog
problem_spec([
    fd_domain(q0, 0, 3), fd_domain(q1, 0, 3),
    fd_domain(q2, 0, 3), fd_domain(q3, 0, 3),
    fdalldifferent([q0, q1, q2, q3]),
    fdsumneq(q0, 1, q1), fdsumneq(q1, 1, q0),
    ...
]).
```

This is the same format QCLP_Q uses. `clp/` here and QCLP_Q's `tests/`
hold the same files.

### Names

Variables may be lowercase atoms (`q0`, `alpha`) or capitalised names
(`StartA`, `X`). Capitalised names are read as their own names. A bare
`_` is an error.

### Domains

```prolog
fd_domain(x, 0, 5)           % x in {0..5}
fd_domain(x, [1, 3, 7])      % x in {1, 3, 7}
fd_domain(x, [1-3, 5-7])     % x in {1,2,3,5,6,7}   (Lo-Hi is a range, never subtraction)
fd_eq(x, 42)                 % a clue: x is fixed to 42
```

All restrictions on a variable are intersected, in any order: several
`fd_domain` declarations, and `fd_eq(V, C)` clues. An empty intersection
warns and gives 0 solutions.

A list domain with gaps is stored as its full range plus one `≠`
constraint per missing value. So `[0, 11]` costs 12 states in the search
space, not 2. (QCLP_Q stores only the listed values.)

In the exported circuit each variable is a register that holds its
**value**, so it needs enough qubits for the largest value: ⌈log₂(High+1)⌉
(`b` in 6..10 needs 4). All search registers share the widest width. A
clue variable (one value, e.g. `fd_eq(prod, 21)`) is a constant: it is
substituted into the constraints and gets no register. Negative domain
values, and negative constants in constraints, are not supported by the
circuit backend: its registers are unsigned. Write `x + (-1) = y` as
`fd_sum_eq(y, 1, x)`.

### Constraints

The "Oracle" column says whether the constraint can be compiled into the
oracle. `run`, `export` and `backend(exact)` all use that oracle, so a
problem with a "no" constraint is refused by all three. `solve/1` (the
classical reference solver) supports everything.

| Constraint | Meaning | Oracle |
|---|---|---|
| `fd_eq(X, Y)` | X = Y | yes |
| `fd_neq(X, Y)` | X ≠ Y | yes |
| `fd_lt(X, Y)`, `fd_le(X, Y)` | X < Y, X ≤ Y | yes |
| `fd_gt(X, Y)`, `fd_ge(X, Y)` | X > Y, X ≥ Y | yes |
| `fdsumeq(X, K, Y)` / `fd_sum_eq` | X + K = Y | yes |
| `fdsumneq(X, K, Y)` / `fd_sum_neq` | X + K ≠ Y (queens diagonals) | yes |
| `fdalldifferent(L)` / `fd_all_different` | all distinct | yes (pairwise ≠) |
| `fd_product_eq(X, Y, Z)` | X × Y = Z | yes, Z a constant or clue |
| `fd_weighted_sum([W1*X1, ...], T)` | Σ Wi·Xi = T | **no** |
| `fd_abs_diff(X, Y, D)` | \|X − Y\| = D | **no** |
| `fd_min(L, M)`, `fd_max(L, M)` | M = min / max of L | **no** |
| `fd_count(L, V, N)` | exactly N of L equal V | **no** |
| `fd_cost(W, C)` | soft constraint (§6) | **no**: ignored by the search |

Each operand may be a variable, a non-negative integer, or a clue-fixed
variable. Constants may be larger than the registers: a multiplier or
adder is widened to fit them (`fd_product_eq(x, 5, 15)` with x in
0..3), and a target no register value can reach is simply never met
(`fd_product_eq(x, y, 17)` with x, y in 0..3 has no solution).

Not supported by QCLP_G at all: `fd_xor`, `fd_implies`, `fd_or`,
`fd_atmost`, `fd_atleast` (QCLP_Q supports them). An unrecognised
constraint, or a name with no domain, is an **error**:

```
Domain error: `fd_constraint' expected, found `fd_foo(x)'
(fd_foo(x): not a recognised constraint. Supported: fd_eq, fd_neq, fd_lt,
fd_le, fd_gt, fd_ge, fd_sum_eq/fdsumeq, fd_sum_neq/fdsumneq,
fd_all_different/fdalldifferent, fd_product_eq, fd_weighted_sum,
fd_abs_diff, fd_min, fd_max, fd_count, fd_cost)
```

A problem with a "no" constraint, or a negative constant, is refused
(`info` says so too, and `show` prints no microcode for it):

```
[circuit] ERROR: fd_abs_diff cannot be compiled into the oracle yet.
[circuit]   The circuit, and run/1 (which simulates the circuit's oracle),
[circuit]   would mark the wrong states, so they refuse.
[circuit]   solve/1 gives the classical answer.
```

---

## 3. Commands

All commands are loaded into the Prolog prompt by `[load]`. Each takes
the path of a `.clp` file, as written; there is no automatic `clp/`
prefix.

```prolog
?- help.
```
```
============================================================
  QCLP_G commands (available at the Prolog prompt)
============================================================
  run(File)           Grover search, number of solutions unknown, on
                      the fast simulator of the circuit's oracle
  run(File,Opts)      seed(S), top(N), shots(N), analysis(true),
                      iterations(K): run K iterations, no search
                      backend(exact): the search on the real gates
  run_qasm(Qasm)      run an exported circuit as written: shots,
  run_qasm(Qasm,Opts) each decoded and checked (shots(N), top(N),
                      analysis(true) = simulator-only full state)
  solve(File)         CLASSICAL reference solver (not used by the
                      quantum paths)
  info(File)          qubits, register states, default iterations
  show(File)          deep dive: oracle microcode + QASM preview
  export(File)        write QASM to qasm/<basename>.qasm
  export(File,Out)    write QASM to custom file
  export(File,Out,[iterations(K)])  choose the iteration count
  top(N)              show top N states from last simulation
  top                 show top 10 states
  decode(Text)        decode simulator output, e.g.
                      decode('  |0000000053>  25/100 (25.0%)')
  decode(Text,File)   ... for circuit File (.qasm or .clp)
  examples            list .clp files in clp/ and examples/
  help                this list
  set_qasm_dir(Dir)   change QASM output directory

  File is always a path to a .clp file. To generate one from a
  built-in generator (factor(N), queens(N), coloring(N), ...):
    ?- ['examples/generators'].
    ?- gen_clp(queens(4), 'examples/queens4.clp').
============================================================
```

`info.` (no argument) prints a shorter overview.

### `run(File)`: Grover search on the fast simulator

```prolog
?- run('examples/factor15.clp', [seed(1), top(4)]).
```
```
[rp] examples/factor15.clp
[grover] circuit oracle (pcode): 2 registers x 4 qubits = 256 register states
[grover] exponential search (unknown M), budget 144 oracle calls
[grover]   round 1: K=0, measured |198> [p=6,q=12]: checked, not a solution
[grover]   round 2: K=0, measured |151> [p=7,q=9]: checked, not a solution
[grover]   round 3: K=1, measured |127> [p=15,q=7]: checked, not a solution
...
[grover]   round 7: K=0, measured |9> [p=9,q=0]: checked, not a solution
[grover]   round 8: K=3, measured |53> [p=5,q=3]: checked, a solution
[grover] found [p=5,q=3] after 6 oracle calls

Final state after K=3 (simulator view, not measurable on hardware):
Top 4 of 256 register states by probability:
  |53>     16.8577%  [p=5,q=3]  ** solution **
  |83>     16.8577%  [p=3,q=5]  ** solution **
  |0>       0.2610%  [p=0,q=0]
  |1>       0.2610%  [p=1,q=0]
```

The search runs over the circuit's **register states**: p and q are
4-qubit registers, so there are 256 states, including values such as
p = 15 or q = 0 that the registers can hold but the domains exclude
(the oracle's range checks reject them). A state's index is the one
the gate-level simulator reports: register p is bits 0–3, q is bits
4–7, so |83⟩ = `0101 0011` is q = 5, p = 3.

Each round's K, the measured state and the result of checking it are
shown. The final listing is the simulator's view of the last round's
state; hardware would give only the measurement. Every listed state is
checked, which gives its label.

To see what an exported circuit with a fixed K does, use
`iterations(K)`. No search is done, and `shots(N)` samples the result
as `run_qasm` would on the real gates:

```prolog
?- run('examples/factor15.clp', [iterations(12), shots(100), top(3)]).
```
```
[grover] 12 Grover iterations (iterations(K)); no search

Final state after K=12 (simulator view, not measurable on hardware):
Top 3 of 256 register states by probability:
  |53>     32.0816%  [p=5,q=3]  ** solution **
  |83>     32.0816%  [p=3,q=5]  ** solution **
  |0>       0.1411%  [p=0,q=0]

Shot results (100 samples, 30 distinct states, top 3; each checked):
    39/100 (39.0%)  [p=5,q=3]  ** solution **
    29/100 (29.0%)  [p=3,q=5]  ** solution **
     2/100 (2.0%)  [p=11,q=0]
```

This takes under a second. The same circuit on the gate-level
simulator takes several minutes and gives the same probabilities.

Options:

| Option | Effect |
|---|---|
| `top(N)` | states listed at the end (default 5) |
| `seed(S)` | fix the random choices, for a reproducible run |
| `budget(B)` | give up after B·√N oracle calls (default 9); "probably no solution" |
| `iterations(K)` | no search: run exactly K iterations, as an exported circuit with that K |
| `shots(N)` | also sample N measurements from the final state |
| `analysis(true)` | also classify every state (a classical check of all states: diagnostics only) |
| `backend(exact)` | run the search on the gate-level circuit (§4) |

`run` refuses circuits with more than **100,000 register states**
(the simulator evaluates the oracle on every one):

```
[rp] ERROR: the circuit has 549755813888 register states; run/1,2 simulates at most 100000.
```

### `solve(File)`: classical reference solver

```prolog
?- solve('clp/queens4.clp').
```
```
  Classical solutions (2):
    q0=1  q1=3  q2=0  q3=2
    q0=2  q1=0  q2=3  q3=1
```

A plain classical brute-force enumeration, for comparison and checking.
No quantum path uses it. Above 100,000 states it stops after the first
20 solutions. With `fd_cost`, each solution is listed with its cost,
followed by the minimum:

```
  Classical solutions (6):
    w1=0  w2=1  w3=2   cost -8
    ...
    w1=2  w2=1  w3=0   cost -9

  Minimum cost -9 (1 solution(s)):
    w1=2  w2=1  w3=0
```

### `info(File)`: qubits and register states

```prolog
?- info('examples/factor15.clp').
```
```
=======================================================
  QCLP_G -- Constraint Summary
=======================================================

  Domains:
    p  in  2..14  (13 values, 4 qubits)
    q  in  2..14  (13 values, 4 qubits)

  Constraints:
    p * q  #=   15

  Qubit budget:
    p: 4 qubits to hold values up to 14 (domain 2..14)
    q: 4 qubits to hold values up to 14 (domain 2..14)
  Registers share the widest width: 2 x 4 qubits
  ...
=======================================================
  QCLP_G -- Grover Circuit Statistics
=======================================================
  Variables:          2  (2 searched, 0 fixed)
  Constraints:        1
  Search space N:     169
  Circuit registers:  2 x 4 qubits = 256 register states
  Default iterations: 12  (optimal if exactly 1 state is marked)
  Domain qubits:      8
  Total qubits:       9 (+ ancilla)
  (The number of solutions is not computed: it is unknown, as on
   real hardware. run/1,2 search with unknown M.)
=======================================================
```

The problem has 169 declared assignments, but the registers hold 256
combinations; the oracle rejects those outside the domains. Both
simulators search the 256 register states. "Total qubits" counts
the domain registers and the oracle flag only. The exported circuit
adds ancillas for arithmetic, comparisons and the diffuser.

### `show(File)`: microcode and QASM preview

`info`, then the oracle microcode (the *pcode*) and the first 40 lines
of the circuit. Nothing is written to disk and nothing is solved.

```
-- Oracle Microcode (circuit) --
  next(fd_anc1, p*q)
  flag_test(fd_anc1, eq_const(15))
  flag_test(p, in_range(2,14))
  flag_test(q, in_range(2,14))

-- Grover QASM (first 40 lines) --
OPENQASM 3.0;
include "stdgates.inc";
// Generated by QCLP_G -- structured Grover circuit
...
```

### `export(File)`, `export(File, Out)`, `export(File, Out, [iterations(K)])`

```prolog
?- export('examples/factor15.clp').
Written: qasm/factor15.qasm  (search space 169, 256 register states, 12 Grover iterations)

?- export('examples/factor15.clp', 'qasm/f15_k3.qasm', [iterations(3)]).
```

A circuit has a fixed number of Grover iterations. Without the number
of solutions there is no single right K, so `export` writes the K you
give, or by default the optimum for exactly one marked state. On
hardware with unknown M, run circuits for several K, as the exponential
search does (`run/2` with `backend(exact)` does this on the simulator).

`export/1` writes `qasm/<basename>.qasm` (the directory is created if
needed); `set_qasm_dir(Dir)` changes it. The circuit uses only `h`,
`x`, `cx`, `ccx`, with gate definitions for the arithmetic blocks. Read
the warning in §2 before exporting a file with unsupported constraints
or costs.

### `top`, `top(N)`: re-inspect the last run

```prolog
?- top(3).
```

The most probable states of the last `run/1`'s final state (simulator
view). `top` with no argument shows 10.

### `decode(Text)`, `decode(Text, File)`: decode simulator output

`qsim_run/2` and `qasm3_expand_and_run/2` print raw states: the index of
the whole multi-qubit state, in decimal, zero-padded. Paste a line, or
a whole block of lines, into `decode`:

```prolog
?- export('examples/factor15.clp').
?- decode('  |00000000000000000000000000000053> ').
```
```
[decode] layout from qasm/factor15.qasm (examples/factor15.clp)
  |53>  [p=5,q=3]  ** solution **  (ancillas clean)
```
```prolog
?- decode('  |00000000000000000000000000000083>  25/100 (25.0%)
  |00000000000000000000000000000053>  24/100 (24.0%)
  |00000000000000000000000000000127>  1/100 (1.0%)').
```
```
[decode] layout from qasm/factor15.qasm (examples/factor15.clp)
  |83>  [p=3,q=5]  ** solution **  (ancillas clean)   25/100 (25.0%)
  |53>  [p=5,q=3]  ** solution **  (ancillas clean)   24/100 (24.0%)
  |127>  [p=15,q=7]  not a solution  (ancillas clean)   1/100 (1.0%)
```

Each state is split into the problem's variables, checked against the
domains and constraints, and its ancillas are checked against their
starting values. The rest of each line (counts, percentages) is kept.
A plain index works too: `decode(83)`.

Which circuit? By default the last one used: the last `export`,
`run_qasm` or `run` (or `decode/2`). To name it, pass the file:

* `decode(Text, 'qasm/factor15.qasm')`: the register layout is read
  from the circuit, and the ancillas are checked.
* `decode(Text, 'examples/factor15.clp')`: the layout `export` would
  use (search variables first, from qubit 0). The ancillas cannot be
  checked; it says whether the qubits above the registers are all 0.

An index that covers only the variable registers (from `run/1`, or
typed by hand) is decoded too; it says the ancillas were not checked.

### `examples`

Lists the `.clp` files in `clp/` and `examples/`.

---

## 4. The fast simulator and the gate-level circuit

| | Fast simulator (`run/1`) | Gate-level (`run/2` + `backend(exact)`, `run_qasm`) |
|---|---|---|
| What runs | The oracle's microcode, evaluated per register state; inversion about the mean | The QASM circuit, gate by gate |
| State space | The circuit's register states (factor15: 256) | All qubits: registers and ancillas (factor15: 39 qubits) |
| Index of a state | Binary over the registers | Binary over all qubits; the low bits are the registers |
| Result for a given K | **The same probabilities** | **The same probabilities** |
| Constraints, costs | Oracle-compilable constraints only (§2); costs ignored | The same |
| Limit | 100,000 register states | Time: each iteration is hundreds of gates on every amplitude |
| Use it to | Explore the search quickly | Check the gates themselves; ancilla clean-up |

The fast simulator does not model the ancillas: it evaluates each
microcode step as a number in a register of the circuit's width. If the
gates compute those steps correctly and clean up after themselves, the
two give identical results. The test suite checks this state by state
(categories 6, 7 and 8), and a search run checks each measured state
against the constraints and warns if the oracle's verdict differs:

```
[grover] WARNING: the oracle marks |..> [...], but it fails the check:
[grover]   the compiled oracle (and the exported circuit) is wrong.
```

### Grover search on the gate-level circuit

```prolog
?- run('examples/factor15.clp', [backend(exact), seed(5)]).
```
```
[exact] examples/factor15.clp: 39 qubits, 762 gates per Grover iteration, 256 register states
[decode] variables: p = qubits 0..3  q = qubits 4..7
[exact] exponential search (unknown M), budget 144 oracle calls
[exact]   round 1: K=0, measured [p=11,q=8]: checked, not a solution
[exact]   round 2: K=1, measured [p=3,q=10]: checked, not a solution
...
[exact]   round 14: K=0, measured [p=14,q=4]: checked, not a solution
[exact]   round 15: K=8, measured [p=5,q=3]: checked, a solution
[exact] found [p=5,q=3] after 30 oracle calls (last round K=8)
```

The circuit is generated with one Grover iteration. Its preparation is
simulated once, and the iteration (oracle and diffuser, real gates) is
applied as many times as each round needs. Every measured shot is
decoded to the problem's variables and checked: the values must lie in
their domains, the constraints must hold, and every ancilla must be back
at its starting value. This run took about 5 minutes. Add
`analysis(true)` to see the simulator-only view of the final state
(exact probabilities per assignment).

### Running an exported circuit as written: `run_qasm`

```prolog
?- export('examples/simple_neq.clp').
?- run_qasm('qasm/simple_neq.qasm', [shots(200), top(4)]).
```
```
[decode] circuit: qasm/simple_neq.qasm
[decode] problem: examples/simple_neq.clp
[sv] 9 qubits, 121 gates
[decode] variables: x = qubits 0..1  y = qubits 2..3

Shot results (200 samples, 16 distinct assignments, top 4; each checked):
    19/200 (9.5%)  [x=1,y=3]  ** solution **
    18/200 (9.0%)  [x=1,y=2]  ** solution **
    18/200 (9.0%)  [x=3,y=2]  ** solution **
    16/200 (8.0%)  [x=0,y=0]
  ancillas: clean in every shot (uncompute OK)
```

This is what hardware would give: shots, each decoded and checked. The
`.clp` file is found from the circuit's `// Example:` header line, or
from `source(File)`.

Options:

* `shots(N)` (100), `top(N)` (10), `source(File)`.
* `raw(true)`: also print the simulator's undecoded output.
* `analysis(true)`: add the simulator-only view of the whole final
  state: exact probabilities per assignment, the probability on
  solutions, and an exact ancilla check.

`qsim_run/2` and `qasm3_expand_and_run/2` give the raw view, one state
index per line; `decode/1` (§3) turns those lines into variables. By
hand: the `[sv] registers:` line gives each register's first qubit and
width (`reg(v_x,0,2)` is qubits 0–1), and the value is little-endian
(qubit 0 is the lowest bit). So state 13 = `11 01` is x = 1, y = 3.

### How the circuit encodes the problem

* **Registers.** Each search variable is a register holding its value;
  clues are constants.
* **Range checks.** The registers can hold values the domain does not
  allow (16 values for p in 2..14), so the oracle adds a range check
  Low ≤ V ≤ High for every such variable, tested directly on the
  register bits (no arithmetic). `≠` checks reject gaps in list
  domains. Only assignments inside the declared domains are marked.
* **Ancilla sharing.** The oracle evaluates one constraint at a time
  (compute, test, uncompute), so all constraints share a small pool of
  ancilla registers (`anc_pool0`, ...). queens4 needs 7 ancilla qubits
  for its 18 constraints, not 96. What grows with the number of
  constraints is one condition flag each, plus scratch to AND them.

Domains whose size is not a power of two, and domains starting above 0,
cost extra qubits: wider registers and range checks. Domains such as
0..3 or 0..7 cost nothing extra.

A `** wraparound **` label marks a register state that satisfies the
constraints but lies outside the domains (factor15: p = 1, q = 15). The
oracle must not mark it, so it should have the same small probability
as any non-solution. If it has more, the range checks are missing or
wrong. Before 1 Oct 2026 there were none, and in factor15 those two
states took 45% of the probability.

---

## 5. Problems with few or many solutions

The exponential search starts with small K and grows the range slowly.
When solutions are common, the first rounds (often K = 0, which is just
measuring the uniform superposition, i.e. a random guess) succeed
quickly. `simple_neq` (x ≠ y on 0..3) has 12 solutions among 16 states:

```
[grover]   round 1: K=0, measured |0> [x=0,y=0]: checked, not a solution
[grover]   round 2: K=1, measured |0> [x=0,y=0]: checked, not a solution
[grover]   round 3: K=0, measured |9> [x=1,y=2]: checked, a solution
[grover] found [x=1,y=2] after 1 oracle calls
```

Round 2 shows why K is drawn at random. With 12 of 16 states marked,
one iteration rotates the state exactly onto the 4 non-solutions
(sin²(3θ) = 0 with θ = 60°): K = 1 can never succeed here. A search
that fixed K would fail every time; drawing K from a range avoids
that without knowing M. Grover's speed-up matters when solutions are rare: the expected
number of oracle calls grows like √(N/M), against N/M for guessing.

When there is no solution, the search runs until its budget (9·√N
oracle calls by default) and reports "probably none". That is a
probabilistic conclusion, as it would be on a quantum computer.

Keep the register space small for simulation: it is 2^(bits per
register × number of variables), and every register is as wide as the
largest value in any domain needs. Five variables over 0..3 give
4⁵ = 1,024 states; one domain reaching 8 makes every register 4 qubits
wide. Clue-fixed variables (`fd_eq(V, C)`) cost nothing.

---

## 6. Optimisation with `fd_cost`

`fd_cost(W, C)` adds a soft constraint, with the same rule as QCLP_Q:

- **W > 0 is a penalty**, added when C is **violated**.
- **W < 0 is a reward**, added when C **holds**.
- W = 0 has no effect.

**The search ignores costs.** There is no cost oracle yet: `run`,
`export` and `backend(exact)` all search for a state satisfying the
hard constraints, and say so:

```prolog
?- run('clp/maxcut.clp', [seed(2), top(3)]).
```
```
[grover] circuit oracle (pcode): 5 registers x 1 qubits = 32 register states
[grover] note: fd_cost is not in the oracle (the circuit has no cost oracle
[grover]   yet); this finds a state satisfying the hard constraints.
[grover] exponential search (unknown M), budget 51 oracle calls
[grover]   round 1: K=0, measured |8> [v0=0,v1=0,v2=0,v3=1,v4=0]: checked, a solution
[grover] found [v0=0,v1=0,v2=0,v3=1,v4=0] after 0 oracle calls
```

`maxcut.clp` has no hard constraints, so every state is "a solution"
and the first measurement ends the search. To find the minimum today,
use `solve/1` (classical) or QCLP_Q's QUBO/QAOA route.

**What a cost oracle needs.** Dürr–Høyer minimum finding searches
repeatedly for "feasible and cost < T", lowering T to each better
state found. That needs the cost computed inside the oracle: each soft
constraint's truth value held in a qubit, and a weighted sum of those
bits compared with T. The microcode cannot yet hold a test result as a
value; adding that would also give `fd_count`, `fd_min`, `fd_max` and
`fd_abs_diff` (§2).

---

## 7. Choosing K, the number of Grover iterations

With M marked states out of N, K iterations find a marked state with
probability

  P(K) = sin²((2K+1)·θ),  θ = arcsin(√(M/N)).

The best K depends on M, which is unknown unless the problem has
already been solved. So QCLP_G never chooses K from M:

* **`run/1`, `run/2` with `backend(exact)`:** exponential search
  (Boyer–Brassard–Høyer–Tapp). In each round, K is drawn uniformly from
  0..⌈m⌉−1, with m starting at 1 and growing by 6/5 after each failed
  round (capped at √N). The expected cost is O(√(N/M)) oracle calls for
  any M ≥ 1. Use `seed(S)` for a repeatable run.
* **`export`:** a circuit needs a fixed K. It is either given
  (`iterations(K)`) or defaults to the optimum for exactly one marked
  state, `rp_grover_iterations_m(N, 1, K)`, with N the circuit's
  register states.

`rp_grover_iterations_m/3`, the K that maximises P(K) for a given M
(shared with QCLP_Q), is still used for that default with M = 1, and
by the test suite, which compares simulated circuits with theory.

Before 1 Oct 2026, K was chosen from M, which came from a classical
brute-force solve.

---

## 8. Generating `.clp` files from built-in families

`examples/generators.pl` is a separate tool, not loaded by the
application. It defines the parametric families `factor(N)`,
`queens(N)`, `coloring(N)` and `pythagorean(Max)`, plus the fixed
problems `simple_neq`, `sum_eq` and `send_more_money`. `gen_clp/1,2`
writes one out as an ordinary `.clp` file:

```prolog
?- ['examples/generators'].
?- gen_clp(factor(21), 'examples/factor21.clp').
[gen] .clp written: examples/factor21.clp  (3 goal(s))

?- gen_clp(queens(6)).          % default path: examples/queens6.clp
```

Once written, the file is a `.clp` file like any other. Pre-generated
files in `examples/`: `coloring3`, `factor15`, `factor35`, `factor217`,
`pythagorean7`, `pythagorean13`, `queens4`, `queens4_anchor1`, `queens5`,
`simple_neq`, `sum_eq`.

To add a family, add an `fd_example(Name, Goals)` clause to
`examples/generators.pl`:

```prolog
fd_example(my_problem, [
    fd_domain(a, 0, 3),
    fd_domain(b, 0, 3),
    fd_domain(c, 0, 6),
    fd_sum_eq(a, b, c),
    fd_lt(a, b)
]).
```

---

## 9. The statevector simulator

`qsim_run/1,2` runs any OpenQASM 3.0 file. Gate macros and `for` loops
are expanded in memory first.

```prolog
?- qsim_run("qasm/simple_neq.qasm").
?- qsim_run("qasm/simple_neq.qasm", [shots(500)]).
```

| Option | Effect |
|---|---|
| `shots(N)` | Sample N times and show a histogram |
| `amplitudes(true)` | Print the full complex amplitudes |
| `output_reg(Bits)` | Decode a Bits-wide value from qubit 0 up |

The file is looked for as given, then under `qasm/`.

From the shell, without loading QCLP_G:

```bash
swipl qclp_gates/sv_run.pl -- qasm/simple_neq.qasm --shots 500
```

The state is stored sparsely: only non-zero amplitudes, in an AVL tree.
Grover circuits with Bennett uncompute keep their ancillas at |0⟩, so a
circuit with dozens of qubits often holds only a few hundred non-zero
amplitudes. Gates acting only on qubits that are currently zero are
skipped.

---

## 10. Low-level API

For scripts, the compiler can be driven directly:

```prolog
?- Goals = [fd_domain(x,0,3), fd_domain(y,0,3), fd_lt(x,y)],
   rp_fd_compile(Goals, FDSpec),
   rp_grover_write(FDSpec, 'qasm/lt_example.qasm', [iterations(2)]).
```

| Predicate | Purpose |
|---|---|
| `rp_fd_compile(+Goals, -FDSpec)` | Compile a goal list to an FD spec |
| `grover_search(+FDSpec, +Opts, -Result)` | The search behind `run/1`: the circuit's oracle (pcode), unknown M |
| `rp_fd_solve(+FDSpec, -Solutions)` | Classical reference solver (as `solve/1`; no quantum path uses it) |
| `rp_fd_solve(+FDSpec, +Max, -solutions(List, Flag))` | First Max classical solutions |
| `rp_fd_info(+FDSpec)` | Print the constraint summary |
| `rp_grover_qasm(+FDSpec, -Lines)`, `rp_grover_qasm(+FDSpec, +Opts, -Lines)` | Circuit as a list of lines; `Opts`: `iterations(K)` |
| `rp_grover_write(+FDSpec, +File)`, `rp_grover_write(+FDSpec, +File, +Opts)` | Write the circuit |
| `grover_top(+N)`, `grover_decode(+Idx, -A)` | As `top/1`; the assignment of a register-state index of the last run |
| `rp_decode:decode_state(+Text)`, `decode_state(+Text, +File)` | As `decode/1,2` |

---

## 11. Tests

```prolog
?- rp_test.          % 84 fast tests
?- rp_test(full).    % 87, including larger circuits
?- rp_pcode_test.    % 324 cases: pcode evaluator against the classical checker
```

Category 6 runs the fast simulator at the theoretically best K for the
true number of solutions (the test knows it; the simulator does not)
and compares every state's probability with Grover theory. Category 7
does the same for the gate-level circuit, and also checks that the
fast simulator gives the same probability as the gates for every
register state. Category 8 pushes every register state through the
exported oracle's gates classically (they are only X, CX and CCX) and
checks that the oracle flag equals the fast simulator's verdict and
that every ancilla returns to its starting value. Category 9 checks the
compiled oracle against the true answers on edge cases with constants
(the test knows the answers; the simulator does not).

Category 1 reads circuits from `qasm/` (`bell_test`, `parity_test`,
`xor_test`, `xor`). Run the tests from the `QCLP_G` directory.

---

## 12. Troubleshooting

| Symptom | Fix |
|---|---|
| Stack limit exceeded | Start with `swipl --stack_limit=256M` (or more for large exact runs) |
| `run` error: more than 100,000 register states | Use `info` or `export`, or shrink the domains: the widest domain sets every register's width |
| `[circuit] ERROR: ... cannot be compiled into the oracle yet` | The problem uses a constraint the oracle cannot express (§2). Use `solve/1` for the classical answer |
| `[grover] WARNING: the oracle marks ...` | The compiled oracle disagrees with the constraints on a measured state: a compiler bug. Please report it |
| `[grover] note: fd_cost is not in the oracle` | Expected: the search finds a feasible state, not a minimum (§6) |
| "found a solution after 0 oracle calls" | Solutions are common, so a K = 0 round (a random guess) succeeded (§5) |
| "probably no solution" | No marked state was measured within the budget; raise `budget(B)` to search longer |
| `qsim_run` fails | File not found. Check the working directory, or give the `qasm/` path |
| `decode/1` gives values outside the domains | Register states include values the registers can hold but the domains exclude (p = 15 for p in 2..14); the oracle never marks them |
| `decode/1` decodes against the wrong problem | It uses the last circuit used; name it: `decode(Text, 'qasm/file.qasm')` |
| `run_qasm`: few shots are solutions | The circuit's fixed K suits a different number of solutions (§7). `run(File, [iterations(K)])` shows quickly what each K gives; or use `backend(exact)` |
| `** wraparound **` states with more probability than non-solutions | The range checks are wrong: please report it (§4) |
| Error naming a constraint or a variable | Not in the vocabulary (§2), or no `fd_domain` for that name |

---

## 13. Source files (`qclp_gates/`)

| File | Contents |
|---|---|
| `load.pl` | Loads everything (the top-level `load.pl` loads this) |
| `rp_commands.pl` | The command interface: `run`, `run_qasm`, `solve`, `info`, `show`, `export`, `top`, `decode`, `examples`, `help`, `set_qasm_dir` |
| `rp.pl` | Pipeline engine behind `run/1,2` (internal) |
| `rp_spec.pl` | `.clp` loader |
| `rp_fd.pl` | Constraint compiler, oracle microcode, cost evaluation, classical reference solver |
| `rp_grover.pl` | Grover circuit generator and the iteration formula |
| `rp_gates.pl` | Gate library: adders, subtractors, XOR, multiplier, comparators |
| `rp_pcode.pl` | Microcode evaluator: `pcode_marks/4` (fixed-width, as the circuit computes; the fast simulator's oracle) and `pcode_eval/2` (exact arithmetic; `rp_pcode_test`) |
| `qsim_pp_grover.pl` | Fast simulator of the circuit's Grover search over its register states: unknown-M search, `grover_top/1`, `grover_decode/2` |
| `rp_decode.pl` | Gate-level search (`backend(exact)`), `run_qasm/1,2` (shots decoded and checked), `decode/1,2` (pasted output) |
| `sv_sim.pl`, `sv_util.pl` | Statevector simulator |
| `sv_run.pl` | Simulator driver: `qsim_run/1,2`, command-line entry |
| `qasm3_macro_pp.pl` | QASM 3 macro and `for`-loop expander |
| `rp_engine.pl`, `rp_ui.pl`, `rp_arith.pl`, `rp_namer.pl`, `rp_fold.pl`, `rp_ite.pl`, `rp_demo.pl`, `rp_costs.pl` | Reversible Prolog compiler, `rp/1` (see `Reversible_Prolog_Tutorial.md`) |
| `rp_test.pl`, `rp_pcode_test.pl` | Test suites |
