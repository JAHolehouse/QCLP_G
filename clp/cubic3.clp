% cubic3.txt -- Phase 2 smoke test
%
% A minimal "three independent one-hot blocks" constraint:
%   fdsumeq(x, c, s)   i.e.   x + c #= s
%
% x in {0,1}, c in {0,1}, s in {0,1,2}
%
% This is the simplest possible case that triggers the cubic
% (Rosenberg-reduced) path in sumeq_viol/4: all three operands of
% fdsumeq/3 are genuine fd_domain variables, so NVars == 3.
%
% Valid (x+c=s) assignments: (0,0,0) (0,1,1) (1,0,1) (1,1,2)
% All four give violation indicator 0 -> hard-constraint contribution 0.
% Any other combination (e.g. x=1,c=1,s=0) gives violation 1 ->
% hard-constraint contribution = P_hard (default 8).
%
% Additionally, a small fd_cost prefers c=1 (reward -1), so among the
% four valid solutions the optimizer should prefer one with c=1, e.g.
% (x=0,c=1,s=1) or (x=1,c=1,s=2), each with total energy -1.

problem_spec([
    fd_domain(x, 0, 1),
    fd_domain(c, 0, 1),
    fd_domain(s, 0, 2),

    fdsumeq(x, c, s),

    fd_cost(-1, fd_eq(c, 1))
]).
