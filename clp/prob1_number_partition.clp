% Problem 1: Number Partitioning  S={1,5,5,11}
% a_i = contribution of element i to set A (either 0 or si)
% Hard: a1+a2+a3+a4 = 11 (perfect partition)
% Solution: a1=1,a2=5,a3=5,a4=0 or a1=0,a2=0,a3=0,a4=11

problem_spec([
    fd_domain(a1, [0, 1]),    % element 1: goes to A (1) or B (0)
    fd_domain(a2, [0, 5]),    % element 5: goes to A (5) or B (0)
    fd_domain(a3, [0, 5]),    % element 5: goes to A (5) or B (0)
    fd_domain(a4, [0, 11]),   % element 11: goes to A (11) or B (0)

    % Sum chain: a1+a2=t12, t12+a3=t123, t123+a4=total
    fd_domain(t12,  [0,1,5,6]),
    fd_domain(t123, [0,1,5,6,10,11]),
    fd_domain(total,[0,1,5,6,10,11,22]),
    fdsumeq(a1, a2, t12),
    fdsumeq(t12, a3, t123),
    fdsumeq(t123, a4, total),

    % Perfect partition
    fd_eq(total, 11)
]).
