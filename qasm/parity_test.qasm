OPENQASM 3.0;
include "stdgates.inc";
// Test fixture for rp_test category 1 (qclp_gates/rp_test.pl).
// The original file was missing from the distributed package; this is a
// reconstruction from the test's own description and expected result.
// Parity of 4 data bits q[0..3] into q[4]. Input 0010 (q[1] = 1),
// odd parity, so q[4] = 1: expect |10010> = |18> at 100%.
qubit[5] q;
x q[1];
cx q[0], q[4];
cx q[1], q[4];
cx q[2], q[4];
cx q[3], q[4];
