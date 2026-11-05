% carry_chain.txt -- Phase 2 test: a 2-bit binary adder
%
% Computes A + B = Sum (mod 4) with an explicit carry-out, using TWO
% fdsumeq/3 constraints chained through a shared carry variable -- the
% classic "send_more_money"-style pattern the Phase 1 README calls out
% as needing cubic (Rosenberg-reduced) terms:
%
%   column 0 (low bit):   a0 + b0 #= s0 + 2*c1     -- s0 in 0..1, c1 in 0..1
%                          encoded as: fdsumeq(a0, b0, t0), t0 #= s0 + 2*c1
%                          but to keep every constraint genuinely 3-way
%                          cubic we instead phrase it directly as:
%                            fdsumeq(a0, b0, t0)     where t0 in 0..2
%                                                     (t0 = a0+b0, all three
%                                                      independent domain
%                                                      vars -> cubic)
%
%   column 1 (high bit + carry-in):
%                            fdsumeq(a1, b1, t1)     where t1 in 0..2
%
% This file just exercises two independent NVars==3 fdsumeq constraints
% plus an fdsumeq linking t0's carry-out to t1 via a constant -- i.e.
% multiple cubic constraints in one compile, sharing variables, to make
% sure aux-variable reuse (the global PairAssoc) works across goals.
%
% a0,b0,a1,b1 in {0,1}; t0,t1 in {0,1,2} (t = sum of the two input bits).
%
% Cost: prefer a1=1 (reward -1) and b0=1 (reward -1), so the optimizer
% should pick a solution with both a1=1 and b0=1 among the many valid
% (t0=a0+b0, t1=a1+b1) assignments.

problem_spec([
    fd_domain(a0, 0, 1), fd_domain(b0, 0, 1), fd_domain(t0, 0, 2),
    fd_domain(a1, 0, 1), fd_domain(b1, 0, 1), fd_domain(t1, 0, 2),

    fdsumeq(a0, b0, t0),
    fdsumeq(a1, b1, t1),

    fd_cost(-1, fd_eq(a1, 1)),
    fd_cost(-1, fd_eq(b0, 1))
]).
