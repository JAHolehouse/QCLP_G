% Test 3: weighted sum hard constraint and soft reified version
problem_spec([
    fd_domain(x, 0, 5),
    fd_domain(y, 0, 5),
    fd_weighted_sum([2*x, 3*y], 8),        % 2*X + 3*Y #= 8
    fd_cost(5, fd_weighted_sum([2*x, 3*y], 9))  % soft: indicator for equality to 9
]).