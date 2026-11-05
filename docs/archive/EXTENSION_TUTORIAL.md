# Writing an RProlog Extension Application

> **⚠ Out of date: the REPL has been removed.** This tutorial's Part 1
> ("The REPL extension mechanism") describes `rp_repl.pl`'s
> `repl_extension/1` and `repl_extension_info/0` multifile hooks.
> `rp_repl.pl` no longer exists — `rp_commands.pl` is now the only
> supported interactive interface, and it has no equivalent plugin
> mechanism yet. If you're extending RProlog today:
> - Add your driver predicate (e.g. `shor/1`) to `rp_commands.pl`'s
>   export list and give it a clause there, the same way `run/1`,
>   `solve/1`, etc. are defined, instead of registering a
>   `repl_extension/1` clause.
> - Everything below Part 1 — the macro evaluator interface
>   (`qsim_macro_evaluate/2`), post-processor patterns, and the
>   worked Shor's-algorithm example — is unaffected by the REPL
>   removal and still applies as written.
> - Part 1 is left below for historical reference only.

This tutorial explains how to write a self-contained application that
integrates cleanly with the RProlog shell (`rp_repl`) and the macro
evaluator (`qsim_macro`), using Shor's algorithm as the worked example.

---

## The big picture

RProlog has three layers a new application can interact with:

```
┌─────────────────────────────────────────────────────┐
│  rp_repl                                            │
│  Interactive shell.  Reads commands, dispatches     │
│  them.  Knows nothing about specific algorithms.    │
└──────────────────────┬──────────────────────────────┘
                       │  qsim_macro_evaluate/2
┌──────────────────────▼──────────────────────────────┐
│  qsim_macro                                         │
│  Reads a QASM file and executes it classically.     │
│  Produces a MetaData dict containing the circuit    │
│  structure and the output distribution.             │
│  Knows nothing about specific algorithms.           │
└──────────────────────┬──────────────────────────────┘
                       │  MetaData.distribution
┌──────────────────────▼──────────────────────────────┐
│  Your post-processor                                │
│  Receives MetaData, interprets the distribution,   │
│  produces domain-specific results.                  │
│  This is where your algorithm knowledge lives.      │
└─────────────────────────────────────────────────────┘
```

A new application typically provides:
- A **post-processor** that interprets `MetaData` from `qsim_macro_evaluate/2`
- A **top-level driver** that orchestrates the workflow (like `shor/1`)
- A **REPL extension** that makes the driver available from the shell
- A **load file** that ties everything together

You only need the pieces that are relevant to your application.

---

## Part 1 — The REPL extension mechanism

### How it works

`rp_repl` declares two predicates as `multifile`:

```prolog
:- multifile repl_extension/1.
:- multifile repl_extension_info/0.
```

`multifile` means clauses for these predicates can be contributed by any
module.  When `repl_dispatch/1` receives a command it doesn't recognise,
it tries `repl_extension(Cmd)` as a fallback.  If your module is loaded,
your clause is found.  If it isn't loaded, the clause doesn't exist and
the user gets "Unknown command" — clean and honest.

`repl_extension_info/0` is called by `info.` to let loaded extensions
add their own section to the help output.

### What you write

In your application module (e.g. `my_app.pl`), add these lines:

```prolog
%% Tell Prolog these predicates span multiple files
:- multifile rp_repl:repl_extension/1.
:- multifile rp_repl:repl_extension_info/0.

%% Handle your commands
rp_repl:repl_extension(myapp(X)) :-
    catch(
        my_app:run(X),
        E, format("  [myapp] Error: ~w~n", [E])
    ).

%% Handle bare atom shorthand (optional)
rp_repl:repl_extension(myapp) :-
    my_app:run(info).

%% Contribute to the 'info.' output
rp_repl:repl_extension_info :-
    format("  --- My Application (loaded) ---~n"),
    format("  myapp.              Show myapp command list~n"),
    format("  myapp(run(X)).      Run X~n"),
    nl.
```

That's everything the REPL needs.  No changes to `rp_repl.pl`.

### What the user sees

When your module is loaded:
```
|: myapp(run(something)).     ← handled by your extension
|: myapp.                     ← shows your info page
|: info.                      ← core commands + your section
```

When your module is not loaded:
```
|: myapp(run(something)).
  [!] Unknown command: myapp(run(something))  (type 'info.' for commands)
```

---

## Part 2 — The macro evaluator interface

### What `qsim_macro_evaluate/2` gives you

```prolog
qsim_macro_evaluate(+File, -MetaData)
```

Call this with a QASM filename and it returns a `MetaData` dict with
these fields:

| Field | Content |
|---|---|
| `path` | Resolved file path (atom) |
| `registers` | List of `reg(Name, Size, Bits)` terms |
| `instructions` | Executable QASM lines as atoms (comments/decls stripped) |
| `raw_lines` | Every line of the file as atoms |
| `distribution` | Execution result (see below) |

### The `distribution` field

If the circuit contains `ctrl_modmul_*` gates (QPE-style circuits),
the evaluator executes them classically and sets:

```prolog
distribution: ctrl_modmul_dist(NCtrl, M, Mod, Peaks)
```

where:
- `NCtrl` — number of control qubits
- `M` — 2^NCtrl (control register size)
- `Mod` — modulus read from the gate names
- `Peaks` — list of `peak(K, Prob, J)` terms
  - `K` — ctrl register measurement outcome
  - `Prob` — probability of measuring K
  - `J` — peak index (0 = trivial)

If no recognised instruction family is found:
```prolog
distribution: none
```

### Writing a post-processor

Your post-processor receives `MetaData` and interprets the distribution.
Convention: export `interpret/2` (for reading MetaData) and optionally
`simulate/3` (for running without a QASM file).

```prolog
:- module(my_qpe_app, [interpret/2, simulate/3]).
:- use_module(qsim_macro, [display_distribution/1]).
:- use_module(qsim_num_theory).   %% cf_convergents, powmod, gcd

%%  interpret(+MetaData, -Results)
%%  Called after qsim_macro_evaluate/2.
interpret(MetaData, Results) :-
    Dist = MetaData.distribution,
    ( Dist = ctrl_modmul_dist(_NCtrl, M, _Mod, Peaks) ->
        display_distribution(MetaData),
        my_post_processing(Peaks, M, Results)
    ;   format("[my_qpe_app] No QPE distribution found.~n"),
        fail
    ).

%%  simulate(+Param1, +Param2, -Results)
%%  Direct path -- no QASM file needed.
simulate(Param1, Param2, Results) :-
    %% build IOTable, compute distribution, call my_post_processing
    ...
```

### Calling your post-processor

```prolog
%% From a QASM file:
qsim_macro_evaluate("my_circuit.qasm", MetaData),
my_qpe_app:interpret(MetaData, Results).

%% Directly (no QASM):
my_qpe_app:simulate(Param1, Param2, Results).

%% Via the REPL shim:
qsim_macro_run("my_circuit.qasm").   %% only if you register a header string
```

---

## Part 3 — The complete Shor example

Here is the complete pattern Shor's algorithm uses, which you can follow
directly.

### File layout

```
shor/
  load.pl          loads rprolog core + shor modules
  rp_qpe.pl        QASM circuit generator (shor-specific)
  rp_shor_qpe.pl   top-level driver + REPL extension
rprolog/
  qsim_pp_shor.pl  post-processor (interprets distribution -> factors)
  qsim_num_theory.pl  shared maths (cf_convergents, powmod, gcd)
```

### `shor/load.pl` — loading the application

```prolog
%% Load the RProlog core (gives us load_rp_module/1)
:- load_files('../rprolog/load.pl', [if(not_loaded)]).

%% Load shared utilities and post-processor from rprolog/
:- load_rp_module(qsim_num_theory).
:- load_rp_module(qsim_pp_shor).

%% Load shor-specific modules from this directory
:- load_shor_module(rp_qpe).
:- load_shor_module(rp_shor_qpe).   %% also registers REPL extension
```

The key point: loading `rp_shor_qpe` is what activates the REPL extension.
No other step is needed.

### `rp_shor_qpe.pl` — driver and REPL extension

The driver provides `shor/1` as a clean user-facing predicate:

```prolog
shor(factor(N))        :- ...  %% factor N
shor(simulate(B, M))   :- qsim_pp_shor:simulate(B, M, _).
shor(export(B, M, F))  :- rp_qpe_write(B, M, F).
shor(info(B, M))       :- rp_qpe_info(B, M).
shor(info)             :- ... print usage ...
```

The REPL extension at the bottom of the same file:

```prolog
:- multifile rp_repl:repl_extension/1.
:- multifile rp_repl:repl_extension_info/0.

rp_repl:repl_extension(shor(X)) :-
    catch(rp_shor_qpe:shor(X), E, format("  [shor] Error: ~w~n", [E])).

rp_repl:repl_extension(shor) :-
    rp_shor_qpe:shor(info).

rp_repl:repl_extension(shor_test) :-
    rp_shor_qpe:shor_test.

rp_repl:repl_extension_info :-
    format("  --- Shor's Algorithm (loaded) ---~n"),
    format("  shor.                        Shor command list~n"),
    format("  shor(factor(N)).             Factor N~n"),
    format("  shor(simulate(Base, Mod)).   Macro-simulate QPE~n"),
    nl.
```

### `qsim_pp_shor.pl` — post-processor

```prolog
interpret(MetaData, Results) :-
    Dist = MetaData.distribution,
    Dist = ctrl_modmul_dist(_NCtrl, M, Mod, Peaks),
    display_distribution(MetaData),
    extract_factors(Peaks, M, Mod, unknown, Results).

simulate(Base, Mod, Results) :-
    %% build distribution without QASM, then extract_factors
    ...
```

---

## Part 4 — Checklist for a new application

```
[ ] Create your application directory (e.g. myapp/)
[ ] Create myapp/load.pl
      - load ../rprolog/load.pl
      - load_rp_module any shared utilities you need
      - load your own modules

[ ] If your circuit uses ctrl_modmul gates:
      - call qsim_macro_evaluate/2 to get MetaData
      - write a post-processor that reads MetaData.distribution
      - export interpret/2 from your post-processor

[ ] If your circuit uses a different gate family:
      - read MetaData.instructions and process them yourself
      - or contribute a new execution clause to qsim_macro
        by contacting the RProlog maintainer

[ ] Write a top-level driver predicate (e.g. myapp/1)
      - provides a clean interface over the post-processor
      - handles info, export, simulate, factor subcommands

[ ] Register your REPL extension in your driver file:
      :- multifile rp_repl:repl_extension/1.
      :- multifile rp_repl:repl_extension_info/0.
      rp_repl:repl_extension(myapp(X))  :- catch(myapp:run(X), E, ...).
      rp_repl:repl_extension(myapp)     :- myapp:run(info).
      rp_repl:repl_extension_info       :- format("  --- My App ---~n"), ...

[ ] Test from the REPL:
      cd myapp
      swipl --stack_limit=256M
      ?- [load].
      |: myapp(run(something)).
      |: info.
```

---

## Part 5 — What not to do

**Don't modify `rp_repl.pl`.**  The extension mechanism exists precisely
so you never have to.  If you find yourself editing the REPL to add your
command, the extension mechanism is the fix.

**Don't modify `qsim_macro.pl`.**  It executes instructions it recognises
and ignores the rest.  Your post-processor handles the interpretation.
If you need a genuinely new instruction family (not `ctrl_modmul`), raise
it with the RProlog maintainer — adding an execution clause to
`qsim_macro` is a core change, not an extension.

**Don't use `assertz` to inject REPL hooks.**  The `multifile` approach
is cleaner: the clauses are present when your module is loaded and absent
when it isn't.  `assertz` creates clauses that survive module unloading
and accumulate on repeated loads.

**Don't call `nb_setval(qsim_fdspec, FDSpec)` directly.**  Always use
`qsim_pp_grover:register_fdspec(FDSpec)` instead.  It is the single
authoritative entry point: it updates both the dynamic fact checked by
`resolve_fdspec/1` and the global `nb_setval` store.  Calling only
`nb_setval` leaves the dynamic fact stale, and `resolve_fdspec` checks
the dynamic fact first — meaning the freshly-registered spec will be
silently shadowed by whatever was registered before.

**Don't duplicate `qsim_num_theory`.**  `cf_convergents/3`, `powmod/4`,
and `gcd/3` are available to any post-processor via
`:- use_module(qsim_num_theory)`.  The same goes for
`display_distribution/1` from `qsim_macro`.

---

## Quick reference

| Predicate | Module | What it does |
|---|---|---|
| `qsim_macro_evaluate(+File, -Meta)` | `qsim_macro` | Read + execute QASM, return MetaData |
| `display_distribution(+Meta)` | `qsim_macro` | Print the output distribution |
| `cf_convergents(+P, +Q, -Convs)` | `qsim_num_theory` | Continued fraction convergents of P/Q |
| `powmod(+Base, +Exp, +Mod, -R)` | `qsim_num_theory` | Fast modular exponentiation |
| `gcd(+A, +B, -G)` | `qsim_num_theory` | Euclidean GCD |
| `period(+Base, +Mod, -R)` | `qsim_num_theory` | Classical order finding |
| `repl_extension(+Cmd)` | `rp_repl` (multifile) | Handle a REPL command |
| `repl_extension_info` | `rp_repl` (multifile) | Add a section to `info.` |
| `register_fdspec(+FDSpec)` | `qsim_pp_grover` | Register the active FDSpec for Grover oracle |
| `grover_decode(+Idx, -Assignment)` | `qsim_pp_grover` | Decode state index → variable assignment |
| `grover_top(+N)` | `qsim_pp_grover` | Print top N states from last simulation |

### RProlog Shor's Algorithm Example

```prolog
C:\Users\Admin\Desktop\rprolog v1.3 working>swipl
Welcome to SWI-Prolog (threaded, 64 bits, version 10.0.1)
SWI-Prolog comes with ABSOLUTELY NO WARRANTY. This is free software.
Please run ?- license. for legal details.

For online help and background, visit [https://www.swi-prolog.org](https://www.swi-prolog.org)
For built-in help, use ?- help(Topic).
or ?- apropos(Word).

4 ?- [shor/shor_load].

RProlog loaded.  Type  info.  for more information.
Shor's Algorithm: Type  shor(info).
for more information.

true.

5 ?- [load].

RProlog loaded.  Type  info.  for more information.
=============================================
   RProlog Quantum Programming Shell
   Type 'info.' for commands, 'halt.' to exit.
  =============================================

|: shor.
shor(info(+Base, +Mod))          circuit statistics
  shor(export(+Base, +Mod, +File))  write QASM 3.0 file
  shor(simulate(+Base, +Mod))       generate + simulate
  shor(factor(+N))                  factor N
  shor(info)                        this list

  Examples:
    shor(export(7, 15, 'shor_15.qasm'))
    shor(factor(15))
    shor(factor(21))

|: shor(factor(21)).
Factoring N = 21
----------------------------------------
  Trying base = 2: generating QPE circuit...
Written: qasm/shor_2_21.qasm  (22 qubits, 4854 QASM lines)
  Circuit written.
Simulate with: 'shor_2_21.qasm'.
  Classical period = 6
Result: 21 = 7 x 3

|: