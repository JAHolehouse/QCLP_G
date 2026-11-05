% factor21.clp  -- Find A*B=21
% A in {2..4}, B in {6..10}
% Uses sparse one-hot encoding -- NO auxiliary variables needed
% 3 + 5 + 1 = 9 one-hot bits

problem_spec([
    fd_domain(a, [2, 3, 4]),
    fd_domain(b, [6, 7, 8, 9, 10]),
    fd_domain(prod, [21,21]),
    fd_eq(prod, 21),
    fd_product_eq(a, b, prod)
]).
