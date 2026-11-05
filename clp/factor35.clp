% factor35.clp  -- Find A*B=35
% A in {2..5}, B in {7..17}
% Uses sparse one-hot encoding -- NO auxiliary variables needed
% 4 + 11 + 1 = 16 one-hot bits

problem_spec([
    fd_domain(a, [2, 3, 4, 5]),
    fd_domain(b, [7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17]),
    fd_domain(prod, [35,35]),
    fd_eq(prod, 35),
    fd_product_eq(a, b, prod)
]).
