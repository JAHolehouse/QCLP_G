% number_partition_weighted.txt  -- Number Partitioning with non-uniform weights
%
% From Mazumder & Tayur (2024) "Five Starter Problems", Section 3.1.
%
% S = {1, 5, 5, 11}  (total c = 22, target = 11 each side)
% Perfect partition: A={11}, B={1,5,5}  or  A={1,5,5}, B={11}
%
% PHASE 3 ENCODING using sparse domains:
%   Instead of binary x_i in {0,1}, use a "contribution" variable p_i
%   whose domain is exactly {0, s_i} -- just two values, the
%   contribution to set A if element i is included (s_i) or excluded (0).
%
%   fd_domain(p1, [0,1])   -- element 1: contributes 0 or 1 to sum_A
%   fd_domain(p2, [0,5])   -- element 2: contributes 0 or 5 to sum_A
%   fd_domain(p3, [0,5])   -- element 3: contributes 0 or 5 to sum_A
%   fd_domain(p4, [0,11])  -- element 4: contributes 0 or 11 to sum_A
%
%   Now p2 can ONLY be 0 or 5 -- values 1,2,3,4 are not in its domain.
%   This was impossible with fd_domain(p2, 0, 5) (contiguous).
%
%   Accumulate sum via fdsumeq chain:
%     s1 = p1 + p2    (s1 in {0,1,5,6})
%     s2 = s1 + p3    (s2 in {0,1,5,6,10,11})
%     s3 = s2 + p4    (s3 in {0,1,5,6,10,11,22} -- but we fix to 11)
%
%   Intermediate sum domains are also sparse:
%     fd_domain(s1, [0,1,5,6])
%     fd_domain(s2, [0,1,5,6,10,11])
%   s3 is fixed to 11 via fd_eq clue, so no bits needed for s3.
%
% This is the Phase 3 demonstration: sparse domains enable the full
% weighted Number Partitioning problem in clean constraint form.

problem_spec([
    fd_domain(p1, [0,1]),
    fd_domain(p2, [0,5]),
    fd_domain(p3, [0,5]),
    fd_domain(p4, [0,11]),

    fd_domain(s1, [0,1,5,6]),
    fd_domain(s2, [0,1,5,6,10,11]),
    fd_domain(s3, [0,11]),

    fdsumeq(p1, p2, s1),
    fdsumeq(s1, p3, s2),
    fdsumeq(s2, p4, s3),

    fd_eq(s3, 11)
]).
