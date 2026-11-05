OPENQASM 3.0;
include "stdgates.inc";
// Test fixture for rp_test category 1 (qclp_gates/rp_test.pl).
// The original file was missing from the distributed package; this is a
// reconstruction from the test's own description and expected result.
// Bell state: expect |0> and |3> at 50% each.
qubit[2] q;
h q[0];
cx q[0], q[1];
