% vertex_cover_triangle.txt
%
% Minimum Vertex Cover on a triangle graph.
% vi = 1: vertex i IN cover. vi = 0: NOT in cover.
%
% Hard: every edge covered (sum of endpoints != 0).
% Cost: reward -1 for each vertex kept OUT of cover
%       (fd_cost(W,C) with W<0 gives reward W when C holds,
%        so fd_cost(-1, fd_eq(v,0)) rewards keeping v out).
% Minimiser maximises exclusions -> minimum cover.
%
% Known answer: size 2 (any 2 of the 3 vertices).

problem_spec([
    fd_domain(v1, 0, 1),
    fd_domain(v2, 0, 1),
    fd_domain(v3, 0, 1),

    fdsumneq(v1, v2, 0),   % edge (1,2) must be covered
    fdsumneq(v2, v3, 0),   % edge (2,3) must be covered
    fdsumneq(v1, v3, 0),   % edge (1,3) must be covered

    fd_cost(-1, fd_eq(v1, 0)),  % reward for excluding v1
    fd_cost(-1, fd_eq(v2, 0)),  % reward for excluding v2
    fd_cost(-1, fd_eq(v3, 0))   % reward for excluding v3
]).
