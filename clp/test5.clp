% Test 5: min and max of a list
problem_spec([
    fd_domain(a, 0, 5),
    fd_domain(b, 0, 5),
    fd_domain(c, 0, 5),
    fd_domain(m, 0, 5),
    fd_domain(M, 0, 5),
    fd_min([a,b,c], m),
    fd_max([a,b,c], M),
    fd_cost(2, fd_eq(m, 0)),   % prefer solutions with minimum 0
    fd_cost(-1, fd_eq(M, 5))   % reward solutions with maximum 5
]).
