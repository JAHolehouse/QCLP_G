% Tiny test: x,y in {0,1}, x != y.
% Two valid solutions: (x=0,y=1) and (x=1,y=0).
problem_spec([
    fd_domain(x,0,1),
    fd_domain(y,0,1),
    fd_neq(x,y)
]).
