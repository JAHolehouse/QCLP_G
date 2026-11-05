% Test 7: combined example to exercise optimization and reified costs
problem_spec([
    % domains (mixed forms)
    fd_domain(x, [0-2,5]),
    fd_domain(y, 0, 5),
    fd_domain(z, [1-3,7]),
    fd_domain(d, 0, 10),
    fd_domain(m, 0, 10),
    fd_domain(cnt, 0, 3),

    % constraints
    fd_weighted_sum([2*x, 3*y], 8),
    fd_abs_diff(x, y, d),
    fd_min([x,y,z], m),
    fd_count([x,y,z], 0, cnt),

    % soft objectives (mix of penalties and rewards)
    fd_cost(5, fd_abs_diff(x,y,d)),   % penalty tied to abs diff
    fd_cost(-2, fd_weighted_sum([2*x,3*y], 8)), % reward if weighted sum equals 8
    fd_cost(3, fd_le(m, 1))           % penalty if minimum > 1 (reify fd_le)
]).
