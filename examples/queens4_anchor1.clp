%% queens4_anchor1.clp
%% 4-queens with the row-0 queen anchored at column 1 (q0 = 1) --
%% a position that IS part of a real 4-queens solution (unlike
%% column 0, the corner, which has none -- see queens4_anchored.clp).
%% As before, q0 is not a declared search variable; its fixed value
%% is folded directly into the constraints that referenced it, so
%% only q1, q2, q3 are qubits (6 domain qubits total instead of 8).
%%
%% Derivation from queens(4), substituting q0=1:
%%   fd_all_different([q0,q1,q2,q3])
%%     -> fd_all_different([q1,q2,q3])
%%        + q1,q2,q3 all #\= 1        (distinct from fixed q0)
%%   fd_sum_neq(q1,1,q0)  i.e. q1+1 #\= 1   -> fd_neq(q1,0)
%%   fd_sum_neq(q0,1,q1)  i.e. 1+1 #\= q1   -> fd_neq(q1,2)
%%   fd_sum_neq(q2,2,q0)  i.e. q2+2 #\= 1   -- always true, dropped
%%   fd_sum_neq(q0,2,q2)  i.e. 1+2 #\= q2   -> fd_neq(q2,3)
%%   fd_sum_neq(q3,3,q0)  i.e. q3+3 #\= 1   -- always true, dropped
%%   fd_sum_neq(q0,3,q3)  i.e. 1+3 #\= q3   -- always true (q3<=3), dropped

problem_spec([
    fd_domain(q1,0,3),
    fd_domain(q2,0,3),
    fd_domain(q3,0,3),

    fd_all_different([q1,q2,q3]),

    %% distinct from the fixed q0 = 1
    fd_neq(q1,1),
    fd_neq(q2,1),
    fd_neq(q3,1),

    %% not on a diagonal from the fixed q0 = 1
    fd_neq(q1,0),
    fd_neq(q1,2),
    fd_neq(q2,3),

    %% diagonal constraints among the three free queens (unchanged)
    fd_sum_neq(q2,1,q1),
    fd_sum_neq(q1,1,q2),
    fd_sum_neq(q3,2,q1),
    fd_sum_neq(q1,2,q3),
    fd_sum_neq(q3,1,q2),
    fd_sum_neq(q2,1,q3)
]).
