OPENQASM 3.0;
include "stdgates.inc";
// Test fixture for rp_test category 1 (qclp_gates/rp_test.pl).
// The original file was missing from the distributed package; this is a
// reconstruction from the test's own description and expected result.
// q[2] = q[0] XOR q[1] with q[0] = 1, q[1] = 0: expect |101> = |5> at 100%.
qubit[3] q;
x q[0];
cx q[0], q[2];
cx q[1], q[2];
