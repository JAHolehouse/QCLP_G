%% ============================================================
%%  rp_ui.pl  --  RProlog user interface
%%
%%  Commands:
%%
%%    rp(show(Goal))
%%      Compile Goal, show microcode and QASM.
%%
%%    rp(run(Goal, Inputs))
%%      Compile and run interpreter. Inputs = [Var-Value,...].
%%      Print output variable bindings.
%%
%%    rp(run(Goal, Inputs, Theta))
%%      As above, but also binds Theta to the output store
%%      so you can inspect it with rp(decode(Theta, Var, Val)).
%%
%%    rp(decode(Theta, Var, Val))
%%      Extract a single named variable's value from a Theta
%%      returned by rp(run(Goal, Inputs, Theta)).
%%      Val is unified with the integer value.
%%
%%    rp(last)
%%      Re-display the variable bindings from the most recent
%%      rp(run(...)) call.  Useful when output scrolled past.
%%
%%    rp(export(Goal, File))
%%      Compile and write a complete QASM 3.0 file.
%%      Bit width set by rp_set_bits/1 (default 4).
%%
%%    rp(help)
%%      Print this list.
%%
%%  Module defaults to user. To use library predicates:
%%    rp(show(rp_xor(a,b,out)))        -- rp_arith predicate
%%    rp(show(arith_step(...)))             -- rp_arith predicate
%%
%%  Change bit width:
%%    rp_set_bits(8).
%%    rp(export(rp_mod_add(a,b,15,out), 'add8.qasm')).
%% ============================================================

:- module(rp_ui, [rp/1]).

:- use_module(rp_engine, [rp_compile/3, rp_run/3, rp_show/1, rp_qasm/2,
                         rp_set_bits/1, rp_get_bits/1,
                         rp_theta_get/3]).   %% deref-aware variable lookup
:- use_module(rp_namer).
:- use_module(rp_gates).
:- use_module(rp_fold).
:- use_module(rp_demo).

%% ============================================================

rp(help) :- !,
    format("~n  rp(show(Goal))                  microcode + QASM~n"),
    format("  rp(run(Goal, Inputs))            run interpreter, print bindings~n"),
    format("  rp(run(Goal, Inputs, Theta))     as above, bind Theta for decoding~n"),
    format("  rp(decode(Theta, Var, Val))      extract Var from a Theta~n"),
    format("  rp(last)                         re-display last run's bindings~n"),
    format("  rp(export(Goal, File))           write QASM file~n"),
    format("  rp(help)                         this list~n"),
    format("~n  rp_set_bits(N).                 set register width (default 4)~n"),
    format("~n  Inputs = [VarName-Value, ...]~n~n").

rp(show(Goal)) :- !,
    resolve_module(Goal, Mod, BareGoal),
    compile_mc(BareGoal, Mod, MC),
    nl,
    format("-- Microcode --~n"),
    rp_show(MC),
    format("~n-- QASM --~n"),
    rp_qasm(MC, L2),
    maplist(writeln, L2).

rp(run(Goal, Inputs)) :- !,
    rp(run(Goal, Inputs, _)).

%%  3-arg variant: also binds Theta so the caller can decode individual
%%  variables with rp(decode(Theta, Var, Val)) or rp(last).
rp(run(Goal, Inputs, Theta)) :- !,
    resolve_module(Goal, Mod, BareGoal),
    compile_mc(BareGoal, Mod, MC),
    rp_run(MC, Inputs, Theta),
    nb_setval(rp_last_theta, Theta),
    nl,
    format("-- Results --~n"),
    print_theta(Theta).

rp(export(Goal, File)) :- !,
    resolve_module(Goal, Mod, BareGoal),
    rp_get_bits(Bits),
    compile_mc(BareGoal, Mod, MC),
    rp_write_qasm(MC, File, Bits),
    qasm_path(File, Path),
    format("Written: ~w  (~w-bit)~n", [Path, Bits]).

%%  rp(decode(+Theta, +Var, -Val))
%%  Extract the value of a named variable from a Theta binding list.
%%  Theta comes from rp(run(Goal, Inputs, Theta)).
%%  Uses rp_theta_get/3 (deref-aware) -- correctly handles chained
%%  bindings produced by rp_run's interp steps, and is deterministic
%%  (always returns the final resolved value even if Var appears multiple
%%  times in the list due to shadowing).
%%
%%    ?- rp(run(half_adder(a,b,sum,carry), [a-1,b-1], T)),
%%       rp(decode(T, sum, S)).
%%    S = 0
rp(decode(Theta, Var, Val)) :- !,
    ( atom(Var) ->
        ( rp_theta_get(Var, Theta, Val) ->
            true
        ;   format("[rp] Variable '~w' not found in Theta.~n", [Var]),
            fail
        )
    ;   format("[rp] decode/3: Var must be an atom, got: ~w~n", [Var]),
        fail
    ).

%%  rp(last) -- re-display bindings from the most recent rp(run(...))
rp(last) :- !,
    ( catch(nb_getval(rp_last_theta, Theta), _, fail) ->
        nl,
        format("-- Last Results --~n"),
        print_theta(Theta)
    ;   format("[rp] No previous run found. Use rp(run(Goal, Inputs)).~n")
    ).

rp(Cmd) :-
    format("Unknown command: ~w~nType rp(help). for usage.~n", [Cmd]).

%% ============================================================
%%  Helpers
%% ============================================================

compile_mc(Goal, Mod, MC) :-
    rp_compile(Goal, Mod, RawMC),
    rp_rename(RawMC, MC).

%% If the goal has a Module:Goal form, use it.
%% Otherwise search user first, then known rp_* modules.
resolve_module(Mod:Goal, Mod, Goal) :- !.
resolve_module(Goal, Mod, Goal) :-
    functor(Goal, Name, Arity),
    functor(Head, Name, Arity),
    ( predicate_property(user:Head, imported_from(OrigMod)),
      member(OrigMod, [rp_arith]) ->
        Mod = OrigMod
    ; predicate_property(user:Head, defined) ->
        Mod = user
    ; find_rp_module(Name, Arity, Mod) ->
        true
    ;
        Mod = user
    ).

find_rp_module(Name, Arity, Mod) :-
    member(Mod, [rp_arith]),
    functor(Head, Name, Arity),
    predicate_property(Mod:Head, defined), !.

print_theta([]).
print_theta([V-Val|Rest]) :-
    ( atom(V) ->
        format("  ~w = ~w~n", [V, Val])
    ;
        true                    %% skip internal SWI variables
    ),
    print_theta(Rest).

