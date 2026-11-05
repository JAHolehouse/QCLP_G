% Test 4: absolute difference and soft penalty
problem_spec([
    fd_domain(p, [0-3,5]),
    fd_domain(q, [0-3,5]),
    fd_domain(d, 0, 10),
    fd_abs_diff(p, q, d),
    fd_cost(4, fd_abs_diff(p, q, d))   % penalty when abs diff constraint holds/violates per semantics
]).
