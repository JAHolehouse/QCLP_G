% Test 6: count how many list elements equal a value
problem_spec([
    fd_domain(u1, 0, 2),
    fd_domain(u2, 0, 2),
    fd_domain(u3, 0, 2),
    fd_domain(val, 0, 2),
    fd_domain(N, 0, 3),
    fd_count([u1,u2,u3], val, N),
    fd_cost(3, fd_eq(val, 0))   % penalty related to chosen value
]).
