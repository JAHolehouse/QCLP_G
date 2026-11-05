% Problem 4: Cancer Genomics
% 4 genes, find cancer pathway maximising coverage/exclusivity tradeoff
% Coverage (D diagonal): gene0=3, gene1=5, gene2=4, gene3=2
% Exclusivity (A off-diagonal): g0-g1=2, g0-g2=1, g1-g2=3, g1-g3=1
% QUBO: minimise sum(Aij*xi*xj) - alpha*sum(Dii*xi), alpha=1.5
% Solution should include high-coverage, low-exclusivity genes

problem_spec([
    fd_domain(g0, 0, 1),
    fd_domain(g1, 0, 1),
    fd_domain(g2, 0, 1),
    fd_domain(g3, 0, 1),

    % Coverage rewards (alpha=1.5, so reward = -alpha*Dii)
    fd_cost(-5, fd_eq(g0, 1)),   % -1.5 * 3 = -4.5 ~ -5 (rounded)
    fd_cost(-8, fd_eq(g1, 1)),   % -1.5 * 5 = -7.5 ~ -8
    fd_cost(-6, fd_eq(g2, 1)),   % -1.5 * 4 = -6
    fd_cost(-3, fd_eq(g3, 1)),   % -1.5 * 2 = -3

    % Exclusivity penalties (Aij -- penalise when both genes selected)
    fd_domain(p01, 0, 1),  fd_product_eq(g0, g1, p01),  fd_cost(2, fd_eq(p01, 0)),
    fd_domain(p02, 0, 1),  fd_product_eq(g0, g2, p02),  fd_cost(1, fd_eq(p02, 0)),
    fd_domain(p12, 0, 1),  fd_product_eq(g1, g2, p12),  fd_cost(3, fd_eq(p12, 0)),
    fd_domain(p13, 0, 1),  fd_product_eq(g1, g3, p13),  fd_cost(1, fd_eq(p13, 0))
]).
