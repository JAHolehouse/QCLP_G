% maxcut.txt  -- Maximum Cut
%
% From Mazumder & Tayur (2024) "Five Starter Problems", Section 3.2.
%
% Given an undirected graph G=(V,E), partition V into sets A (x=1)
% and B (x=0) to MAXIMISE the number of edges with one endpoint in
% each set (cut edges).
%
% QPCL encoding:
%   x_i in {0,1}: 1 = vertex i in set A, 0 = in set B.
%   An edge (i,j) is CUT iff x_i != x_j  (fd_neq).
%   Reward each cut edge with fd_cost(-1, fd_neq(vi, vj)).
%   Since the QUBO minimiser finds the LOWEST energy, rewarding
%   (negative fd_cost) cut edges maximises the number of cuts.
%
% Python/dimod QUBO equivalent (from the paper):
%   H = sum over edges: 2*x_i*x_j - x_i - x_j    (minimise)
%   CUBO requires no QUBO knowledge: just reward cut edges.
%
% Graph: 5 vertices, 6 edges
%   Edges: (0,1),(0,2),(1,2),(1,3),(2,4),(3,4)
%
%   Adjacency:
%     v0 -- v1, v2
%     v1 -- v0, v2, v3
%     v2 -- v0, v1, v4
%     v3 -- v1, v4
%     v4 -- v2, v3
%
% Known optimal: 5 cut edges out of 6
%   e.g. A={v2,v3}, B={v0,v1,v4}
%   cuts: (0,2),(1,2),(1,3),(2,4),(3,4) = 5 edges, energy=-5.

problem_spec([
    fd_domain(v0, 0, 1),
    fd_domain(v1, 0, 1),
    fd_domain(v2, 0, 1),
    fd_domain(v3, 0, 1),
    fd_domain(v4, 0, 1),

    % Reward each edge that crosses the cut (endpoints in different sets)
    fd_cost(-1, fd_neq(v0, v1)),   % edge (0,1)
    fd_cost(-1, fd_neq(v0, v2)),   % edge (0,2)
    fd_cost(-1, fd_neq(v1, v2)),   % edge (1,2)
    fd_cost(-1, fd_neq(v1, v3)),   % edge (1,3)
    fd_cost(-1, fd_neq(v2, v4)),   % edge (2,4)
    fd_cost(-1, fd_neq(v3, v4))    % edge (3,4)
]).
