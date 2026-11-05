% Test 1: enumerated list with range elements
:- module(test1, [problem_spec/1]).
problem_spec([
    fd_domain(v, [1-3,5-7,10]),
    fd_domain(w, [0,5,10]),
    fd_eq(v, 2),
    fd_cost(3, fd_eq(w, 5))
]).
