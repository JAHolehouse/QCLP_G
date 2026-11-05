% number_partition.txt  -- Number Partitioning
%
% From Mazumder & Tayur (2024) "Five Starter Problems", Section 3.1.
%
% Given a set S of positive integers, partition S into two subsets
% A and B minimising |sum(A) - sum(B)|.  If d=0 a perfect partition
% exists.
%
% Instance: S = {3, 3, 3, 3}  (total = 12, target each side = 6)
% A perfect balanced partition always exists for equal-weight sets.
%
% QPCL encoding:
%   x_i in {0,1}: 1 = element i goes to set A, 0 = set B.
%   For equal weights, sum(A) = weight * count(A), so a perfect
%   partition requires exactly |S|/2 elements in A.
%   Here: exactly 2 of the 4 elements must be in A.
%
%   Express "count of set-A members = 2" via a running sum chain:
%     s12   = x1 + x2            (s12 in {0,1,2})
%     s123  = s12 + x3           (s123 in {0,1,2,3})
%     s1234 = s123 + x4 = 2      (hard constraint: perfect partition)
%
%   Note: each fdsumeq here has three domain variables (the running
%   sum and the two inputs), so Phase 2 Rosenberg reduction applies
%   automatically.
%
% Python/dimod QUBO equivalent (from the paper):
%   c = sum(S) = 12
%   q_ii = s_i*(s_i - c)   -- diagonal terms
%   q_ij = 2*s_i*s_j        -- off-diagonal terms
%   QCPL requires no QUBO knowledge: just state the sum constraint.
%
% Known answer: any 2-element subset, e.g. {3,3}|{3,3}, energy=0.

problem_spec([
    fd_domain(x1, 0, 1),      % element 1 in set A (1) or B (0)
    fd_domain(x2, 0, 1),      % element 2
    fd_domain(x3, 0, 1),      % element 3
    fd_domain(x4, 0, 1),      % element 4

    fd_domain(s12,   0, 2),   % running sum after x1,x2
    fd_domain(s123,  0, 3),   % running sum after x1,x2,x3
    fd_domain(s1234, 0, 4),   % total count of set-A members

    fdsumeq(x1,   x2, s12),    % s12  = x1 + x2
    fdsumeq(s12,  x3, s123),   % s123 = s12 + x3
    fdsumeq(s123, x4, s1234),  % s1234 = s123 + x4

    fd_eq(s1234, 2)             % exactly 2 elements in set A
]).
