% graphcolor4.txt
% Graph: nodes v0..v3 with edges: (0-1), (1-2), (2-0) (triangle) and (2-3) extra node
problem_spec([
  fd_domain(v0,1,3), fd_domain(v1,1,3), fd_domain(v2,1,3), fd_domain(v3,1,3),

  % triangle edges
  fd_neq(v0, v1),
  fd_neq(v1, v2),
  fd_neq(v2, v0),

  % extra edge
  fd_neq(v2, v3)
]).
