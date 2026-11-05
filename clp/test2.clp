% Test 2: union/range syntax (no expansion)
problem_spec([
    fd_domain(a, [1-3,5-7,10]),
    fd_domain(b, 0, 5),
    fd_le(a, 7),
    fd_cost(2, fd_lt(b, 2))
]).
