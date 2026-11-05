% bestcost.pl
% This file holds only the problem specification data.

problem_spec([
    fd_domain(StartA, 0, 3), fd_domain(EndA, 0, 3),
    fd_domain(StartB, 0, 3), fd_domain(EndB, 0, 3),
    fdsumeq(StartA, 2, EndA),
    fdsumeq(StartB, 1, EndB),
    fd_neq(StartA, StartB),
    fd_cost(10, fd_neq(EndB, 2))
]).