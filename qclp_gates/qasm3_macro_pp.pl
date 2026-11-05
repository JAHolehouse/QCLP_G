%% ============================================================
%%  qasm3_macro_pp.pl  --  QASM 3.0 gate-macro / for-loop
%%                          preprocessor for sv_sim
%%
%%  sv_sim's QASM3 reader is a FLAT gate-list interpreter: it
%%  understands primitive gates (h, x, cx, ccx, rz(theta), ...),
%%  multi-register declarations, and named-wire references, but
%%  has NO notion of:
%%      gate NAME(p1,...,pn) { ... }     (user-defined gate macros)
%%      for int i in [Lo:Hi] { ... }     (loops)
%%      inv @ NAME(...)                  (inverse of a macro call)
%%
%%  This module is a pure source-to-source preprocessor: given the
%%  text of a QASM3 program, it
%%
%%    1. unrolls every `for int VAR in [LO:HI] { BODY }` block into
%%       HI-LO+1 textual copies of BODY, substituting VAR -> literal
%%       integer in each copy,
%%
%%    2. recursively inlines every call to a user-defined
%%       `gate NAME(p1,...,pn) { BODY }`, substituting the formal
%%       parameters for the actual arguments (whole-identifier
%%       textual substitution -- this covers both single-qubit and
%%       whole-register actual arguments, since `p[k]` becomes
%%       `actual[k]` automatically),
%%
%%    3. handles `inv @ NAME(args);` by inlining the body in REVERSE
%%       statement order with each primitive gate replaced by its
%%       inverse (self-inverse gates unchanged; rz/rx/ry/p negate
%%       their angle; s<->sdg, t<->tdg; nested macro calls get their
%%       own `inv @` toggled, so `inv @ (inv @ FOO(...))` cancels to
%%       a plain call),
%%
%%    4. alpha-renames any `qubit[N] name;` declarations that occur
%%       INSIDE a gate body, with a fresh gensym suffix PER CALL SITE,
%%       so that a gate using local ancilla qubits can be called (or
%%       unrolled by a for-loop) more than once without colliding
%%       declarations -- sv_sim's qasm3_build_regmap/2 collects
%%       qubit[N] declarations from anywhere in the file, in order,
%%       so no separate hoisting pass is needed,
%%
%%    5. drops the (now-unused) `gate NAME(...) { ... }` definitions
%%       from the output.
%%
%%  The result is a flat QASM3 program containing only primitive
%%  gates, register declarations, and measurements -- exactly what
%%  sv_sim's qasm3_parse_gates_multi/4 expects.
%%
%%  LIMITATIONS
%%    - `for` loops must have literal integer bounds [Lo:Hi] (no
%%      expressions). The loop variable, if it appears in the body as
%%      a bare identifier, is replaced with its integer value as a
%%      decimal literal; it is NOT supported inside array-index
%%      expressions like q[i] (none of RProlog's generated circuits
%%      use the loop variable that way -- it only controls iteration
%%      count).
%%    - Gate definitions must use the simple
%%        gate NAME(p1, p2, ...) { stmt; stmt; ... }
%%      header form (all-register/qubit formal parameters, no
%%      separate classical-parameter parens like `gate rzz(theta) a,b`
%%      -- for THAT form, see expand_paren_gate_call/2, which handles
%%      `NAME(actual_classical_args) wire, wire;`-style calls produced
%%      by e.g. qubo_qaoa_qasm3 for `gate rzz(theta) a, b { ... }`).
%%    - Recursion depth for nested macro expansion is capped (see
%%      max_expand_depth/1) to catch accidental infinite recursion.
%%
%%  USAGE
%%    ?- [qasm3_macro_pp].
%%    ?- qasm3_expand_file('queens(4).qasm', 'queens4_flat.qasm').
%%    ?- qasm3_expand_string(Src, Flat).
%%
%%  Then simulate the flattened file as usual:
%%    ?- qsim_run('queens4_flat.qasm').
%%
%%  Or, to go straight from a QASM file to a simulation result
%%  without ever writing a flattened file to disk, use
%%  qasm3_expand_and_run/1,2 -- this reads File, expands it in
%%  memory, and calls straight into sv_sim via
%%  sv_run:qsim_run_string/2:
%%    ?- qasm3_expand_and_run('queens(4).qasm').
%%    ?- qasm3_expand_and_run('queens(4).qasm', [shots(100)]).
%%
%%  Note: sv_run:qsim_run/1,2 itself now ALWAYS macro-expands (via
%%  this module) before simulating, and also never writes an
%%  intermediate flattened file -- so ordinary qsim_run/1,2 calls
%%  already get the same no-intermediate-file behaviour.
%%  qasm3_expand_and_run/1,2 is provided as an explicit, self-
%%  documenting entry point into that same pipeline, and for
%%  callers that only have this module loaded (not the full
%%  RProlog stack).
%% ============================================================
:- module(qasm3_macro_pp, [
    qasm3_expand_file/2,        % +InFile, -OutFile
    qasm3_expand_string/2,      % +SrcString, -FlatString
    qsim_run_expanded/1,        % +File  -- expand to a temp file, then qsim_run/1
    qsim_run_expanded/2,        % +File, +Opts
    qasm3_expand_and_run/1,     % +File  -- expand in memory, simulate directly, no temp file
    qasm3_expand_and_run/2      % +File, +Opts
]).

:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(readutil)).

max_expand_depth(200).

%% ============================================================
%%  Top-level entry points
%% ============================================================

%% qasm3_expand_file(+InFile, -OutFile)
%%   Reads InFile, expands all macros/for-loops, writes the result
%%   to OutFile (OutFile is overwritten if it exists).
qasm3_expand_file(InFile, OutFile) :-
    read_file_to_string(InFile, Src, []),
    qasm3_expand_string(Src, Flat),
    setup_call_cleanup(
        open(OutFile, write, S),
        write(S, Flat),
        close(S)
    ).

%% qasm3_expand_string(+SrcString, -FlatString)
qasm3_expand_string(Src, Flat) :-
    normalize_text(Src, Norm),
    tokenize(Norm, Items0),
    collect_gatedefs(Items0, GateDefs, Items1),
    nb_setval(qasm3_pp_gensym, 0),
    expand_items(Items1, GateDefs, 0, ExpandedItems),
    items_to_text(ExpandedItems, Flat).

%% qsim_run_expanded(+File)
%% qsim_run_expanded(+File, +Opts)
%%   Convenience: expand File to a temp file alongside it (suffix
%%   "_flat.qasm") and run it through sv_run:qsim_run/1,2.
qsim_run_expanded(File) :- qsim_run_expanded(File, []).
qsim_run_expanded(File, Opts) :-
    flat_filename(File, FlatFile),
    qasm3_expand_file(File, FlatFile),
    format("[qasm3_macro_pp] expanded ~w -> ~w~n", [File, FlatFile]),
    ( current_predicate(sv_run:qsim_run/2)
    -> sv_run:qsim_run(FlatFile, Opts)
    ;  current_predicate(qsim_run/2)
    -> qsim_run(FlatFile, Opts)
    ;  format("[qasm3_macro_pp] WARNING: sv_run:qsim_run/2 not loaded; wrote ~w but did not simulate it.~n", [FlatFile])
    ).

flat_filename(File, FlatFile) :-
    ( sub_atom(File, Before, _, 0, '.qasm')
    -> sub_atom(File, 0, Before, _, Stem)
    ;  Stem = File
    ),
    atom_concat(Stem, '_flat.qasm', FlatFile).

%% qasm3_expand_and_run(+File)
%% qasm3_expand_and_run(+File, +Opts)
%%   Reads File, macro-expands it IN MEMORY, and simulates the
%%   result directly via sv_run:qsim_run_string/2 -- no flattened
%%   ".qasm" file is written to disk at any point. This is the
%%   "direct" counterpart to qsim_run_expanded/1,2, which writes a
%%   "_flat.qasm" file as a (sometimes useful, e.g. for inspection)
%%   side effect.
qasm3_expand_and_run(File) :- qasm3_expand_and_run(File, []).
qasm3_expand_and_run(File, Opts) :-
    ( exists_file(File) -> ResolvedFile = File
    ; atomic_list_concat(['qasm/', File], QasmPath),
      exists_file(QasmPath) -> ResolvedFile = QasmPath
    ;
        format("ERROR: file not found: ~w (also tried qasm/~w)~n", [File, File]),
        fail
    ),
    format("[qasm3_macro_pp] expanding ~w in memory (no intermediate file)~n", [ResolvedFile]),
    read_file_to_string(ResolvedFile, RawSrc, []),
    ( current_predicate(sv_run:qsim_run_string/2)
    -> sv_run:qsim_run_string(RawSrc, Opts)
    ;  format("[qasm3_macro_pp] ERROR: sv_run:qsim_run_string/2 not loaded -- cannot simulate.~n"),
       fail
    ).

%% ============================================================
%%  Step 0: text normalization
%%    - strip CRLF -> LF
%%    - strip line comments ("// ...") -- but keep them as separate
%%      `comment(Text)` items so output is still readable; comments
%%      never contain `;`, `{`, or `}` so they can't confuse the
%%      tokenizer once isolated
%% ============================================================
normalize_text(Src, Lines) :-
    split_string(Src, "\n", "\r", Lines0),
    exclude(==(""), Lines0, Lines1),
    %% Keep blank lines out, but they're harmless either way; this
    %% just avoids spurious empty `stmt("")` items downstream.
    Lines = Lines1.

%% ============================================================
%%  Step 1: tokenize
%%
%%  Items:
%%    comment(Text)                  -- a line whose trimmed form
%%                                       starts with "//"
%%    decl(Text)                     -- a line ending in ";" that is
%%                                       NOT a gate/for header and
%%                                       contains no unmatched braces
%%                                       (covers OPENQASM/include/
%%                                       qubit/bit decls, primitive
%%                                       gates, macro calls, measure)
%%    gatedef(Name, Params, Body)    -- `gate NAME(p1,...) { BODY }`
%%    forblock(Var, Lo, Hi, Body)    -- `for int VAR in [Lo:Hi] { BODY }`
%%
%%  Body is itself a list of items (recursively).
%%
%%  Tokenization works line-by-line (every statement/header in
%%  RProlog's generated QASM is on its own line), tracking a brace
%%  stack so `{`-headers consume lines until their matching `}`.
%% ============================================================
tokenize(Lines, Items) :-
    tokenize_(Lines, Items, []).

%% tokenize_(+Lines, -Items, -RestLines)
%%   Consumes Lines until a line that is exactly "}" (a block
%%   terminator for an enclosing gate/for header) is found, or the
%%   input is exhausted. RestLines = [] at top level; at a nested
%%   level RestLines is unused by the caller (the "}" is consumed
%%   here).
tokenize_([], [], []).
tokenize_([Line|Rest], Items, RestOut) :-
    string_trim(Line, T),
    ( T == "}" ->
        Items = [], RestOut = Rest
    ; sub_string(T, 0, 2, _, "//") ->
        Items = [comment(T)|Items1],
        tokenize_(Rest, Items1, RestOut)
    ; gate_header(T, Name, ClassicalParams, RegParams) ->
        tokenize_(Rest, BodyItems, Rest1),
        Items = [gatedef(Name,ClassicalParams,RegParams,BodyItems)|Items1],
        tokenize_(Rest1, Items1, RestOut)
    ; for_header(T, Var, Lo, Hi) ->
        tokenize_(Rest, BodyItems, Rest1),
        Items = [forblock(Var,Lo,Hi,BodyItems)|Items1],
        tokenize_(Rest1, Items1, RestOut)
    ;   Items = [decl(T)|Items1],
        tokenize_(Rest, Items1, RestOut)
    ).

%% gate_header(+Line, -Name, -ClassicalParams, -RegParams)
%%   Three header forms:
%%     "gate NAME p1, p2, ... {"             -- register-only params,
%%        unparenthesized (the only form valid OpenQASM3 allows for
%%        a gate with no classical parameters -- see QCLP_G CHANGELOG.md, fix report 2,
%%        note 3: qubit-parameter lists must NOT be parenthesized
%%        when there's no classical parameter list. This is what
%%        rp_grover.pl actually emits.)
%%        -> ClassicalParams=[], RegParams=[p1,p2,...]
%%     "gate NAME(p1, p2, ...) {"            -- register-only params,
%%        parenthesized (tolerated for backward compatibility with
%%        any hand-written or older-generated QASM using this form,
%%        even though it isn't strictly valid OpenQASM3)
%%        -> ClassicalParams=[], RegParams=[p1,p2,...]
%%     "gate NAME(t1, t2, ...) a, b, ... {"  -- classical params in
%%        the parens, register params after, space-separated
%%        -> ClassicalParams=[t1,t2,...], RegParams=[a,b,...]
%%   (the qubo_qaoa_qasm3 `gate rzz(theta) a, b { ... }` form is the
%%   third case)
gate_header(Line, Name, ClassicalParams, RegParams) :-
    string_concat("gate ", Rest0, Line),
    ( sub_string(Rest0, B, 1, _, "(") ->
        gate_header_parenthesized(Rest0, B, Name, ClassicalParams, RegParams)
    ;
        gate_header_bare(Rest0, Name, ClassicalParams, RegParams)
    ).

%% Form 1/2 (existing logic, unchanged): a "(" appears somewhere on
%% the line after "gate ".
gate_header_parenthesized(Rest0, B, Name, ClassicalParams, RegParams) :-
    sub_string(Rest0, 0, B, _, NameS),
    string_trim(NameS, NameTrim),
    NameTrim \== "",
    \+ sub_string(NameTrim, _, _, _, " "),   %% reject "int i" etc.
    After is B+1,
    sub_string(Rest0, After, _, 0, AfterParen),
    sub_string(AfterParen, C, 1, _, ")"),
    sub_string(AfterParen, 0, C, _, ParamsS),
    AfterC is C+1,
    sub_string(AfterParen, AfterC, _, 0, Tail),
    string_trim(Tail, TailTrim),
    split_string(ParamsS, ",", " \t", ParamParts0),
    exclude(==(""), ParamParts0, ParamParts),
    ( TailTrim == "{" ->
        %% Form 1: register-only params
        ClassicalParams = [],
        ParamParts2 = ParamParts
    ;   %% Form 2: ParamParts are classical params; TailTrim is
        %% "a, b, ... {" -- register params plus the opening brace
        string_concat(RegPartsS, "{", TailTrim),
        string_trim(RegPartsS, RegPartsTrim),
        split_string(RegPartsTrim, ",", " \t", RegParts0),
        exclude(==(""), RegParts0, RegParts),

        RegParts \== [],
        ClassicalParams = ParamParts,
        ParamParts2 = RegParts
    ),
    maplist(atom_string, RegParams, ParamParts2),
    atom_string(Name, NameTrim).

%% Form 3 (new): no "(" anywhere on the line after "gate " -- the
%% valid unparenthesized OpenQASM3 form for a gate with no classical
%% parameters: "gate NAME p1, p2, ... {"
gate_header_bare(Rest0, Name, [], RegParams) :-
    sub_string(Rest0, B, 1, _, " "),
    sub_string(Rest0, 0, B, _, NameS),
    string_trim(NameS, NameTrim),
    NameTrim \== "",
    After is B+1,
    sub_string(Rest0, After, _, 0, Tail),
    string_trim(Tail, TailTrim),
    string_concat(RegPartsS, "{", TailTrim),
    string_trim(RegPartsS, RegPartsTrim),
    split_string(RegPartsTrim, ",", " \t", RegParts0),
    exclude(==(""), RegParts0, RegParts),
    RegParts \== [],
    maplist(atom_string, RegParams, RegParts),
    atom_string(Name, NameTrim).

%% for_header(+Line, -Var, -Lo, -Hi)
%%   "for int VAR in [Lo:Hi] {"  ->  Var (atom), Lo, Hi (integers)
for_header(Line, Var, Lo, Hi) :-
    string_concat("for int ", Rest0, Line),
    sub_string(Rest0, B, 1, _, " "),
    sub_string(Rest0, 0, B, _, VarS),
    VarS \== "",
    AfterVar is B+1,
    sub_string(Rest0, AfterVar, _, 0, Rest1),
    string_trim(Rest1, Rest1T),
    string_concat("in [", Rest2, Rest1T),
    sub_string(Rest2, Bc, 1, _, ":"),
    sub_string(Rest2, 0, Bc, _, LoS),
    AfterColon is Bc+1,
    sub_string(Rest2, AfterColon, _, 0, Rest3),
    sub_string(Rest3, Br, 1, _, "]"),
    sub_string(Rest3, 0, Br, _, HiS),
    AfterBrack is Br+1,
    sub_string(Rest3, AfterBrack, _, 0, Tail),
    string_trim(Tail, TailTrim),
    TailTrim == "{",
    number_string(Lo, LoS),
    number_string(Hi, HiS),
    atom_string(Var, VarS).

%% ============================================================
%%  Step 2: collect & remove top-level gate definitions
%%    (only top-level defs are callable; nested gatedef items
%%    inside another gatedef's body don't occur in RProlog output
%%    and aren't supported)
%% ============================================================
collect_gatedefs(Items, GateDefs, Rest) :-
    partition([I]>>(I = gatedef(_,_,_,_)), Items, Defs, Rest),
    maplist([gatedef(N,CP,RP,B), N-(CP,RP,B)]>>true, Defs, GateDefs).

%% ============================================================
%%  Step 3: expand for-loops and macro calls
%%
%%  expand_items(+Items, +GateDefs, +Depth, -OutItems)
%%    Top-level driver: maps expand_item/4 over the list and
%%    flattens (each item may expand to zero or more output items).
%% ============================================================
expand_items(Items, GateDefs, Depth, OutItems) :-
    max_expand_depth(Max),
    ( Depth > Max ->
        throw(error(qasm3_macro_pp_depth_exceeded(Max), expand_items/4))
    ;   maplist(expand_item_d(GateDefs,Depth), Items, OutLists),
        flatten1(OutLists, OutItems)
    ).

expand_item_d(GateDefs, Depth, Item, Out) :- expand_item(Item, GateDefs, Depth, Out).

flatten1([], []).
flatten1([L|Ls], Out) :- append(L, Rest, Out), flatten1(Ls, Rest).

:- discontiguous(expand_item/4).

%% ---- comments pass through unchanged ----
expand_item(comment(C), _, _, [comment(C)]) :- !.

%% ---- for-loops: unroll, substituting the loop var as a literal ----
expand_item(forblock(Var,Lo,Hi,Body), GateDefs, Depth, Out) :- !,
    numlist(Lo, Hi, Vals),
    Depth1 is Depth+1,
    maplist(unroll_iter(Var,Body,GateDefs,Depth1), Vals, OutLists),
    flatten1(OutLists, Out).

unroll_iter(Var, Body, GateDefs, Depth, Val, Out) :-
    maplist(subst_item_var(Var,Val), Body, Body1),
    expand_items(Body1, GateDefs, Depth, Out).

%% subst_item_var(+Var, +Val, +Item, -Item1)
%%   Whole-identifier textual substitution of Var -> Val (as a
%%   decimal literal) inside a decl(Text); recurses into nested
%%   for/gatedef bodies (gatedefs shouldn't be nested in practice,
%%   but handled for robustness).
subst_item_var(_Var, _Val, comment(C), comment(C)) :- !.
subst_item_var(Var, Val, decl(T), decl(T1)) :- !,
    atom_string(Var, VarA),
    number_string(Val, ValS),
    subst_ident(T, VarA, ValS, T1).
subst_item_var(Var, Val, forblock(V,Lo,Hi,Body), forblock(V,Lo,Hi,Body1)) :- !,
    maplist(subst_item_var(Var,Val), Body, Body1).
subst_item_var(Var, Val, gatedef(N,CP,RP,Body), gatedef(N,CP,RP,Body1)) :- !,
    maplist(subst_item_var(Var,Val), Body, Body1).

%% ---- plain declarations: pass through, UNLESS they're a macro call ----
expand_item(decl(T), GateDefs, Depth, Out) :- !,
    ( macro_call2(T, Inv, Name, ClassicalArgs, RegArgs),
      member(Name-(ClassicalParams,RegParams,Body), GateDefs),
      ClassicalParams \== [] ->
        instantiate_call2(Name, ClassicalParams, RegParams, Body, ClassicalArgs, RegArgs, Inv, GateDefs, Depth, Out)
    ; macro_call(T, Inv, Name, Args), member(Name-([],RegParams,Body), GateDefs) ->
        instantiate_call(Name, RegParams, Body, Args, Inv, GateDefs, Depth, Out)
    ;   Out = [decl(T)]
    ).

%% gatedef items shouldn't survive into the post-collect_gatedefs
%% item list at top level, but if a (nested) one is ever
%% encountered, drop it -- it has already been collected.
expand_item(gatedef(_,_,_,_), _, _, []).

%% macro_call2(+Text, -Inv, -Name, -ClassicalArgs, -RegArgs)
%%   Recognizes the "classical params in parens, registers after"
%%   call form produced for `gate rzz(theta) a, b { ... }`-style
%%   definitions:
%%     "NAME(c1, c2, ...) w1, w2, ...;"        -> Inv=false
%%     "inv @ NAME(c1, c2, ...) w1, w2, ...;"  -> Inv=true
%%   ClassicalArgs are returned as strings (e.g. "4.000000"),
%%   substituted textually for the gate's classical formal
%%   parameters. RegArgs are atoms -- for qubo_qaoa_qasm3's actual
%%   output these are individually-indexed wires like 'q[0]', one per
%%   formal register parameter, substituted as a WHOLE TOKEN wherever
%%   the formal parameter name appears as a complete identifier in the
%%   body (the body refers to its register params as bare wires, e.g.
%%   "cx a, b;", never re-indexes them).
macro_call2(Text, Inv, Name, ClassicalArgs, RegArgs) :-
    ( string_concat("inv @ ", Rest, Text) -> Inv = true ; Inv = false, Rest = Text ),
    string_concat(Body, ";", Rest),
    sub_string(Body, B, 1, _, "("),
    sub_string(Body, 0, B, _, NameS),
    string_trim(NameS, NameTrim),
    NameTrim \== "",
    \+ sub_string(NameTrim, _, _, _, " "),
    After is B+1,
    sub_string(Body, After, _, 0, AfterParen),
    sub_string(AfterParen, C, 1, _, ")"),
    sub_string(AfterParen, 0, C, _, ClassicalArgsS),
    AfterC is C+1,
    sub_string(AfterParen, AfterC, _, 0, RegArgsS0),
    string_trim(RegArgsS0, RegArgsS),
    RegArgsS \== "",
    \+ sub_string(RegArgsS, 0, 1, _, "{"),   %% reject gate-header lines
    split_string(ClassicalArgsS, ",", " \t", ClassicalArgs0),
    exclude(==(""), ClassicalArgs0, ClassicalArgs),
    split_string(RegArgsS, ",", " \t", RegArgs0),
    exclude(==(""), RegArgs0, RegArgsS_),
    maplist(atom_string, RegArgs, RegArgsS_),
    atom_string(Name, NameTrim).

%% ============================================================
%%  Macro-call recognition (form 1: register-only)
%%
%%  macro_call(+Text, -Inv, -Name, -Args)
%%    Text is a decl(Text) with its trailing ";" still attached.
%%    Recognizes BOTH:
%%      "NAME a1, a2, ...;"           -- unparenthesized (the only
%%                                       form valid OpenQASM3 allows
%%                                       for a call with no classical
%%                                       arguments -- what
%%                                       rp_grover.pl actually emits)
%%      "NAME(a1, a2, ...);"          -- parenthesized (tolerated for
%%                                       backward compatibility)
%%    with an optional "inv @ " prefix on either form:
%%      "inv @ NAME a1, a2, ...;"  / "inv @ NAME(a1, a2, ...);"
%%    Args are returned as a list of atoms. Each argument may be a
%%    bare identifier (a whole register, e.g. "v_x") OR an indexed
%%    wire (e.g. "v_x[0]") -- both are valid actual arguments for a
%%    register-only gate call and both substitute correctly as a
%%    whole-identifier replacement in instantiate_call/8 (exactly
%%    the same substitution instantiate_call2/10 already relies on
%%    for its own RegArgs).
%% ============================================================
macro_call(Text, Inv, Name, Args) :-
    ( string_concat("inv @ ", Rest, Text) -> Inv = true ; Inv = false, Rest = Text ),
    string_concat(Body, ";", Rest),
    ( sub_string(Body, B, 1, _, "(") ->
        macro_call_parenthesized(Body, B, Name, Args)
    ;
        macro_call_bare(Body, Name, Args)
    ).

%% Existing logic (unchanged): "NAME(a1, a2, ...)" form.
macro_call_parenthesized(Body, B, Name, Args) :-
    sub_string(Body, 0, B, _, NameS),
    string_trim(NameS, NameTrim),
    NameTrim \== "",
    \+ sub_string(NameTrim, _, _, _, " "),
    \+ sub_string(NameTrim, _, _, _, "["),  %% reject e.g. "ccx x[0], y[1], z[0]" being misread
    After is B+1,
    sub_string(Body, After, _, 0, AfterParen),
    string_concat(ArgsS0, ")", AfterParen),
    split_string(ArgsS0, ",", " \t", ArgParts0),
    exclude(==(""), ArgParts0, ArgParts),
    maplist(atom_string, Args, ArgParts),
    atom_string(Name, NameTrim).

%% New: "NAME a1, a2, ...;" form -- no parens anywhere. Args may be
%% bare registers ("v_x") or indexed wires ("v_x[0]"); either way,
%% everything after the first space up to the (already-stripped)
%% trailing ";" is the comma-separated argument list.
macro_call_bare(Body, Name, Args) :-
    sub_string(Body, B, 1, _, " "),
    sub_string(Body, 0, B, _, NameS),
    string_trim(NameS, NameTrim),
    NameTrim \== "",
    \+ sub_string(NameTrim, _, _, _, "["),  %% reject e.g. "ccx x[0], y[1], z[0]" being misread
    After is B+1,
    sub_string(Body, After, _, 0, ArgsS0),
    string_trim(ArgsS0, ArgsS),
    ArgsS \== "",
    split_string(ArgsS, ",", " \t", ArgParts0),
    exclude(==(""), ArgParts0, ArgParts),
    maplist(atom_string, Args, ArgParts),
    atom_string(Name, NameTrim).

%% ============================================================
%%  instantiate_call(+Name, +Params, +Body, +Args, +Inv, +GateDefs,
%%                    +Depth, -OutItems)
%%
%%   1. Checks arity.
%%   2. Renames any locally-declared `qubit[N] x;` registers inside
%%      Body to fresh gensym'd names (so repeated/looped calls to the
%%      same gate don't collide), updating all references to those
%%      names within Body.
%%   3. Substitutes formal Params -> actual Args (whole-identifier
%%      textual substitution) throughout the (renamed) Body.
%%   4. If Inv=true, reverses the body's statement order and inverts
%%      every primitive gate / toggles `inv @` on nested macro calls
%%      (see invert_body/2).
%%   5. Recursively expands the resulting body (depth+1) so nested
%%      macro calls and any further for-loops are handled.
%% ============================================================
instantiate_call(Name, Params, Body, Args, Inv, GateDefs, Depth, Out) :-
    length(Params, NP), length(Args, NA),
    ( NP =\= NA ->
        throw(error(qasm3_macro_pp_arity_mismatch(Name,NP,NA), instantiate_call/8))
    ;   true
    ),
    rename_local_decls(Body, Body1),
    pairs_subst(Params, Args, Body1, Body2),
    ( Inv == true -> invert_body(Body2, GateDefs, Body3) ; Body3 = Body2 ),
    Depth1 is Depth+1,
    expand_items(Body3, GateDefs, Depth1, Out).

%% instantiate_call2(+Name, +ClassicalParams, +RegParams, +Body,
%%                    +ClassicalArgs, +RegArgs, +Inv, +GateDefs,
%%                    +Depth, -Out)
%%   As instantiate_call/8, but for the "gate NAME(t1,...) a,b,... {}"
%%   form: substitutes ClassicalParams[i] -> ClassicalArgs[i] (textual,
%%   e.g. "theta" -> "4.000000") and RegParams[i] -> RegArgs[i]
%%   (whole-identifier, e.g. "a" -> "q[0]") simultaneously.
instantiate_call2(Name, ClassicalParams, RegParams, Body, ClassicalArgs, RegArgs, Inv, GateDefs, Depth, Out) :-
    length(ClassicalParams, NCP), length(ClassicalArgs, NCA),
    length(RegParams, NRP), length(RegArgs, NRA),
    ( (NCP =\= NCA ; NRP =\= NRA) ->
        throw(error(qasm3_macro_pp_arity_mismatch(Name,NCP+NRP,NCA+NRA), instantiate_call2/10))
    ;   true
    ),
    rename_local_decls(Body, Body1),
    maplist(atom_string, RegParams, RegParamSs),
    maplist(atom_string, RegArgs, RegArgsSs),
    pairs_keys_values(RegPairs, RegParamSs, RegArgsSs),
    pairs_keys_values(ClPairs, ClassicalParams, ClassicalArgs),
    append(ClPairs, RegPairs, AllPairs),
    maplist(subst_idents_item(AllPairs), Body1, Body2),
    ( Inv == true -> invert_body(Body2, GateDefs, Body3) ; Body3 = Body2 ),
    Depth1 is Depth+1,
    expand_items(Body3, GateDefs, Depth1, Out).

%% pairs_subst(+Params, +Args, +Body, -Body1)
%%   Substitutes each Param[i] -> Arg[i] (whole-identifier, atoms)
%%   throughout Body (a list of items), in order. Parameters are
%%   substituted simultaneously per item via subst_idents_item/3 to
%%   avoid one substitution's output being re-substituted by a later
%%   parameter (e.g. params [a,b] with args [b,a] must swap, not
%%   collide).
pairs_subst(Params, Args, Body, Body1) :-
    maplist(atom_string, Params, ParamSs),
    maplist(atom_string, Args, ArgSs),
    pairs_keys_values(Pairs, ParamSs, ArgSs),
    maplist(subst_idents_item(Pairs), Body, Body1).

subst_idents_item(_Pairs, comment(C), comment(C)) :- !.
subst_idents_item(Pairs, decl(T), decl(T1)) :- !,
    subst_idents(T, Pairs, T1).
subst_idents_item(Pairs, forblock(V,Lo,Hi,B), forblock(V,Lo,Hi,B1)) :- !,
    maplist(subst_idents_item(Pairs), B, B1).
subst_idents_item(Pairs, gatedef(N,CP,RP,B), gatedef(N,CP,RP,B1)) :- !,
    maplist(subst_idents_item(Pairs), B, B1).

%% subst_idents(+Text, +Pairs, -Text1)
%%   Simultaneous whole-identifier substitution of multiple
%%   old-name -> new-name pairs in one left-to-right scan, so that
%%   e.g. swapping [a-b, b-a] works correctly (no double substitution).
subst_idents(Text, Pairs, Out) :-
    string_chars(Text, Chars),
    subst_idents_chars(Chars, Pairs, OutChars),
    string_chars(Out, OutChars).

subst_idents_chars([], _, []).
subst_idents_chars(Chars, Pairs, Out) :-
    ( take_identifier(Chars, Ident, Rest), member(Old-New, Pairs), Old == Ident ->
        string_chars(New, NewChars),
        subst_idents_chars(Rest, Pairs, Out1),
        append(NewChars, Out1, Out)
    ; Chars = [C|_Cs], is_ident_char(C) ->
        %% an identifier that doesn't match any pair: copy it whole
        %% (so e.g. param "x" doesn't also match inside "fd_anc1x")
        take_identifier(Chars, Ident, Rest),
        string_chars(Ident, IdentChars),
        subst_idents_chars(Rest, Pairs, Out1),
        append(IdentChars, Out1, Out)
    ;   Chars = [C|Cs],
        subst_idents_chars(Cs, Pairs, Out1),
        Out = [C|Out1]
    ).

%% take_identifier(+Chars, -Ident, -Rest)
%%   Chars must start with an identifier character; Ident is the
%%   maximal leading run of identifier characters (as a string), Rest
%%   is what follows.
take_identifier([C|Cs], Ident, Rest) :-
    is_ident_char(C),
    take_ident_(Cs, More, Rest),
    string_chars(Ident, [C|More]).

take_ident_([C|Cs], [C|More], Rest) :- is_ident_char(C), !, take_ident_(Cs, More, Rest).
take_ident_(Rest, [], Rest).

is_ident_char(C) :- char_type(C, csym).   %% [A-Za-z0-9_]

%% subst_ident(+Text, +Old, +New, -Text1)
%%   Single-pair convenience wrapper over subst_idents/3.
subst_ident(Text, Old, New, Out) :- subst_idents(Text, [Old-New], Out).

%% ============================================================
%%  Local-declaration renaming (gensym per call site)
%% ============================================================
rename_local_decls(Body, Body1) :-
    findall(Name, ( member(decl(T), Body), local_qubit_decl(T, Name, _) ), Names0),
    list_to_set(Names0, Names),
    maplist(gensym_pair, Names, Pairs),
    maplist(subst_idents_item(Pairs), Body, Body1).

gensym_pair(Name, Old-New) :-
    nb_getval(qasm3_pp_gensym, N),
    N1 is N+1,
    nb_setval(qasm3_pp_gensym, N1),
    atom_string(Name, Old),
    format(atom(NewA), "~w__pp~w", [Name,N]),
    atom_string(NewA, New).

%% local_qubit_decl(+Text, -Name, -Size)
%%   "qubit[N] name;"  ->  Name (string), Size (integer)
local_qubit_decl(T, Name, Size) :-
    string_concat("qubit[", R, T),
    sub_string(R, B, 1, _, "]"),
    sub_string(R, 0, B, _, SizeS),
    number_string(Size, SizeS),
    After is B+1,
    sub_string(R, After, _, 0, Rest),
    string_trim(Rest, RestT),
    string_concat(NameT, ";", RestT),
    string_trim(NameT, Name),
    Name \== "".

%% ============================================================
%%  Inversion (for `inv @ NAME(...)`)
%%
%%  invert_body(+Items, +GateDefs, -ItemsRev)
%%    Reverses statement order and inverts each primitive gate /
%%    toggles `inv @` on macro calls (checking GateDefs membership so
%%    a plain primitive call is never mistaken for a macro call just
%%    because it's syntactically shaped like one). Declarations
%%    (qubit[...], bit[...], comments) are left in place relative to
%%    the surrounding reversal -- in practice gate bodies that are
%%    targets of `inv @` in RProlog's output contain only primitive
%%    gates and nested macro calls (see e.g. xor_2bit), so this is
%%    sufficient.
%% ============================================================
invert_body(Items, GateDefs, ItemsRev) :-
    maplist(invert_item(GateDefs), Items, Items1),
    reverse(Items1, ItemsRev).

invert_item(_, comment(C), comment(C)) :- !.
invert_item(GateDefs, decl(T), decl(T1)) :- !,
    %% Only treat this as a macro-call inversion if Name is actually
    %% a known user-defined gate (member of GateDefs) -- macro_call/4
    %% is purely syntactic and, since it also accepts the
    %% unparenthesized form, would otherwise match plain primitive
    %% calls like "cx v_y[1], v_fd_anc1[1];" too, wrongly emitting
    %% "inv @ cx(...)" (which sv_sim's reader can't parse and
    %% silently skips) instead of leaving self-inverse primitives
    %% like cx unchanged via invert_primitive/2 below.
    ( macro_call(T, false, Name, Args), member(Name-(_,_,_), GateDefs) ->
        format_call(true, Name, Args, T1)
    ; macro_call(T, true, Name, Args), member(Name-(_,_,_), GateDefs) ->
        format_call(false, Name, Args, T1)
    ;   invert_primitive(T, T1)
    ).
invert_item(GateDefs, forblock(V,Lo,Hi,B), forblock(V,Lo,Hi,B1)) :- !,
    %% Inverting a for-loop: reverse iteration order and invert body.
    maplist(invert_item(GateDefs), B, B0),
    reverse(B0, B1).

format_call(Inv, Name, Args, Text) :-
    atomic_list_concat(Args, ', ', ArgsA),
    ( Inv == true
    -> format(atom(A), "inv @ ~w(~w);", [Name, ArgsA])
    ;  format(atom(A), "~w(~w);", [Name, ArgsA])
    ),
    atom_string(A, Text).

%% invert_primitive(+Text, -Text1)
%%   Inverts a single primitive-gate statement (text includes the
%%   trailing ";"). Self-inverse gates (x,h,z,cx,ccx,cz,swap,...) are
%%   unchanged. s<->sdg, t<->tdg. rz/rx/ry/p negate their angle.
%%   Declarations (qubit[...], bit[...]) are left unchanged (their
%%   "inverse" is themselves -- they shouldn't normally appear inside
%%   an inv-target body, but rename_local_decls/2 runs before
%%   inversion so any that do appear are already uniquely named).
invert_primitive(T, T1) :-
    ( angle_gate(T, GateName, Angle, Wire) ->
        NegAngle is -Angle,
        format(atom(A), "~w(~6f) ~w;", [GateName, NegAngle, Wire]),
        atom_string(A, T1)
    ; swap_prefix(T, "s ", "sdg ", T1) -> true
    ; swap_prefix(T, "sdg ", "s ", T1) -> true
    ; swap_prefix(T, "t ", "tdg ", T1) -> true
    ; swap_prefix(T, "tdg ", "t ", T1) -> true
    ;   T1 = T   %% self-inverse (x,h,z,cx,ccx,cz,swap,ccz,...) or decl/measure
    ).

%% angle_gate(+Text, -GateName, -Angle, -Wire)
%%   "rz(0.5) q[3];" -> GateName=rz, Angle=0.5, Wire="q[3]"
angle_gate(T, GateNameA, Angle, Wire) :-
    member(GateName, ["rz","rx","ry","p"]),
    string_concat(GateName, R0, T),
    string_concat("(", R1, R0),
    sub_string(R1, B, 1, _, ")"),
    sub_string(R1, 0, B, _, AngleS),
    number_string(Angle, AngleS),
    After is B+1,
    sub_string(R1, After, _, 0, R2),
    string_trim(R2, R2T),
    string_concat(" ", WireSemi, R2T),
    string_concat(Wire, ";", WireSemi),
    atom_string(GateNameA, GateName).

%% swap_prefix(+Text, +From, +To, -Text1)
swap_prefix(T, From, To, T1) :-
    string_concat(From, Rest, T),
    string_concat(To, Rest, T1).

%% ============================================================
%%  Output: items -> text
%% ============================================================
items_to_text(Items, Text) :-
    maplist(item_lines, Items, LineLists),
    flatten1(LineLists, Lines),
    atomic_list_concat(Lines, '\n', TextA),
    atom_string(TextA, Text).

item_lines(comment(C), [C]).
item_lines(decl(T), [T]).
item_lines(forblock(_,_,_,_), []) :-
    format("[qasm3_macro_pp] WARNING: unexpanded for-loop in output (depth limit?) -- dropped~n", []).
item_lines(gatedef(_,_,_,_), []).  %% should not occur post-expansion

%% ============================================================
%%  Small string utility
%% ============================================================
string_trim(S, T) :-
    split_string(S, "", " \t", [T0]),
    T = T0.
