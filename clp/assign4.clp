% assign4.txt
% assign 4 workers to 4 tasks (one worker per task) using fdalldifferent. 
% You can add fd_cost to prefer certain assignments.

problem_spec([
  fd_domain(w1,1,4), fd_domain(w2,1,4), fd_domain(w3,1,4), fd_domain(w4,1,4),

  % each worker assigned a distinct task (tasks numbered 1..4)
  fdalldifferent([w1,w2,w3,w4]),

  % soft preferences: prefer worker1 on task 2 (reward -5), avoid worker3 on task 4 (penalty 8)
  fd_cost(-5, fd_eq(w1,2)),
  fd_cost(8, fd_neq(w3,4))
]).
