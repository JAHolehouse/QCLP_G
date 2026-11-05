% Problem 2: Max-Cut
% 6-node graph from Mazumder & Tayur (2024) Figure 10
% Edges: (0,3),(1,3),(1,4),(2,4),(2,5),(3,4),(3,5),(4,5)
% vi=0 means node i in set A, vi=1 means node i in set B
% Maximise cut edges = minimise negative of cut count
% Optimal cut: {0,1,2,5} vs {3,4} -- 6 of 8 edges cut ((2,5) and (3,4) are not)

problem_spec([
    fd_domain(v0, 0, 1),
    fd_domain(v1, 0, 1),
    fd_domain(v2, 0, 1),
    fd_domain(v3, 0, 1),
    fd_domain(v4, 0, 1),
    fd_domain(v5, 0, 1),

    % Reward each cut edge with -1 (minimising negative = maximising cuts)
    fd_cost(-1, fd_neq(v0, v3)),
    fd_cost(-1, fd_neq(v1, v3)),
    fd_cost(-1, fd_neq(v1, v4)),
    fd_cost(-1, fd_neq(v2, v4)),
    fd_cost(-1, fd_neq(v2, v5)),
    fd_cost(-1, fd_neq(v3, v4)),
    fd_cost(-1, fd_neq(v3, v5)),
    fd_cost(-1, fd_neq(v4, v5))
]).
