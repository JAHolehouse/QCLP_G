%% 4 Queens

problem_spec([
    fd_domain(q0, 0, 3), fd_domain(q1, 0, 3), fd_domain(q2, 0, 3), fd_domain(q3, 0, 3),
    fdalldifferent([q0, q1, q2, q3]),
    fdsumneq(q0, 1, q1), fdsumneq(q1, 1, q0),
    fdsumneq(q1, 1, q2), fdsumneq(q2, 1, q1),
    fdsumneq(q2, 1, q3), fdsumneq(q3, 1, q2),
    fdsumneq(q0, 2, q2), fdsumneq(q2, 2, q0),
    fdsumneq(q1, 2, q3), fdsumneq(q3, 2, q1),
    fdsumneq(q0, 3, q3), fdsumneq(q3, 3, q0)
   ]).