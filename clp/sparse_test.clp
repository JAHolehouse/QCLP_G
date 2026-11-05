% sparse_test.txt  -- Phase 3 sparse domain demonstration
%
% A tiny example purely to verify that fd_domain(X, [v1,v2,...]) 
% sparse domains work correctly at the constraint language level.
%
% Problem: X in {0,5,10}, Y in {0,5,10}. 
% Hard: X + Y = 10 (only valid pairs: (0,10),(10,0),(5,5))
% Cost: prefer X=5 (reward -1)
% Answer: X=5, Y=5, energy=-1

problem_spec([
    fd_domain(x, [0,5,10]),
    fd_domain(y, [0,5,10]),
    fd_domain(s, [0,5,10,15,20]),

    fdsumeq(x, y, s),
    fd_eq(s, 10),

    fd_cost(-1, fd_eq(x, 5))
]).
