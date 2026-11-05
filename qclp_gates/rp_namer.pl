%% ============================================================
%%  rp_namer -- rename anonymous SWI vars to t1, t2, ...
%%
%%  CHANGE LOG (Gemini review):
%%    - Fix 5: use atom_codes + integer digit check
%%             instead of atom_chars + char_type
%% ============================================================

:- module(rp_namer, [rp_rename/2]).

rp_rename(MC, MC2) :-
    empty_assoc(A0),
    rename_events(MC, MC2, A0, _, 1, _).

rename_events([], [], A, A, N, N).
rename_events([E|Es], [E2|E2s], A0, AF, N0, NF) :-
    rename_event(E, E2, A0, A1, N0, N1),
    rename_events(Es, E2s, A1, AF, N1, NF).

rename_event(ch(L),       ch(L),        A,A,N,N).
rename_event(exit(G),     exit(G),      A,A,N,N).
rename_event(fail_ev(G),  fail_ev(G),   A,A,N,N).
rename_event(guard(G),    guard(G2),    A0,A1,N0,N1) :-
    rename_term(G,G2,A0,A1,N0,N1).
rename_event(unify(X,Y),  unify(X2,Y2), A0,A2,N0,N2) :-
    rename_term(X,X2,A0,A1,N0,N1),
    rename_term(Y,Y2,A1,A2,N1,N2).
rename_event(unf(G,L),    unf(G2,L),   A0,A1,N0,N1) :-
    rename_term(G,G2,A0,A1,N0,N1).
rename_event(next(V,E),   next(V2,E2), A0,A2,N0,N2) :-
    rename_var(V,V2,A0,A1,N0,N1),
    rename_term(E,E2,A1,A2,N1,N2).
rename_event(ite(C,Th,El), ite(C2,Th2,El2), A0,A3,N0,N3) :-
    rename_events(C,C2,A0,A1,N0,N1),
    rename_events(Th,Th2,A1,A2,N1,N2),
    rename_events(El,El2,A2,A3,N2,N3).
%% flag_test(Anc, Kind): rename Anc consistently with its next() event
rename_event(flag_test(Anc, Kind), flag_test(Anc2, Kind), A0,A1,N0,N1) :-
    rename_var(Anc, Anc2, A0, A1, N0, N1).

rename_var(V, V2, A0, A1, N0, N1) :-
    ( var(V) ->
        ( get_assoc(V,A0,V2) -> A1=A0, N1=N0
        ; format(atom(V2),"t~w",[N0]),
          put_assoc(V,A0,V2,A1), N1 is N0+1 )
    ; atom(V), internal_var(V) ->
        ( get_assoc(V,A0,V2) -> A1=A0, N1=N0
        ; format(atom(V2),"t~w",[N0]),
          put_assoc(V,A0,V2,A1), N1 is N0+1 )
    ; V2=V, A1=A0, N1=N0 ).

rename_term(T,T2,A0,A1,N0,N1) :-
    ( var(T)    -> rename_var(T,T2,A0,A1,N0,N1)
    ; number(T) -> T2=T, A1=A0, N1=N0
    ; atom(T)   -> rename_var(T,T2,A0,A1,N0,N1)
    ; T =.. [F|Args],
      rename_term_list(Args,Args2,A0,A1,N0,N1),
      T2 =.. [F|Args2] ).

rename_term_list([],[],A,A,N,N).
rename_term_list([H|T],[H2|T2],A0,A2,N0,N2) :-
    rename_term(H,H2,A0,A1,N0,N1),
    rename_term_list(T,T2,A1,A2,N1,N2).

%% Fix 5: use atom_codes + integer comparison
%%   '_' = code 95, '0'-'9' = codes 48-57
internal_var(V) :-
    atom_codes(V, [95|Rest]),   % 95 = '_'
    Rest \= [],
    maplist(is_digit_code, Rest).

is_digit_code(C) :- C >= 48, C =< 57.
