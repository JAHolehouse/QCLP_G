% Problem 3: Minimum Vertex Cover
% 5-node graph: edges (0,2),(2,4),(1,4),(3,4)
% xi=1 means vertex i is in the cover
% Solution: {0,4} or {2,4} (size 2)
%
% Coverage encoding: for each edge (i,j), introduce binary variable cij
% where cij=1 means edge IS covered (xi+xj >= 1)
% Hard: cij must equal 1 (use fd_eq as hard constraint)
% But since cij depends on xi,xj we link via: cij = 1 - (1-xi)*(1-xj)
% i.e. NOT(xi=0 AND xj=0)
%
% Simpler: use fd_neq(uncovered, 1) where uncovered = (1-xi)*(1-xj)
% Let ni = 1-xi (complement). ni in {0,1}, ni+xi=1.
% uncovered_ij = ni*nj: must be 0. Hard constraint: fd_eq(uij, 0).
% Cost: penalise each vertex present.

problem_spec([
    fd_domain(x0, 0, 1),  fd_domain(n0, 0, 1),  fdsumeq(x0, n0, one0),  fd_domain(one0,[1,1]),  fd_eq(one0,1),
    fd_domain(x1, 0, 1),  fd_domain(n1, 0, 1),  fdsumeq(x1, n1, one1),  fd_domain(one1,[1,1]),  fd_eq(one1,1),
    fd_domain(x2, 0, 1),  fd_domain(n2, 0, 1),  fdsumeq(x2, n2, one2),  fd_domain(one2,[1,1]),  fd_eq(one2,1),
    fd_domain(x3, 0, 1),  fd_domain(n3, 0, 1),  fdsumeq(x3, n3, one3),  fd_domain(one3,[1,1]),  fd_eq(one3,1),
    fd_domain(x4, 0, 1),  fd_domain(n4, 0, 1),  fdsumeq(x4, n4, one4),  fd_domain(one4,[1,1]),  fd_eq(one4,1),

    % Coverage: uij = ni*nj = 1 iff both endpoints absent (uncovered)
    % Hard constraint: uij = 0 (edge must be covered)
    fd_domain(u02, 0, 1),  fd_product_eq(n0, n2, u02),  fd_eq(u02, 0),
    fd_domain(u24, 0, 1),  fd_product_eq(n2, n4, u24),  fd_eq(u24, 0),
    fd_domain(u14, 0, 1),  fd_product_eq(n1, n4, u14),  fd_eq(u14, 0),
    fd_domain(u34, 0, 1),  fd_product_eq(n3, n4, u34),  fd_eq(u34, 0),

    % Minimise cover size
    fd_cost(-1, fd_eq(x0, 0)),
    fd_cost(-1, fd_eq(x1, 0)),
    fd_cost(-1, fd_eq(x2, 0)),
    fd_cost(-1, fd_eq(x3, 0)),
    fd_cost(-1, fd_eq(x4, 0))
]).
