OPENQASM 3.0;
include "stdgates.inc";
// Test fixture for rp_test category 1 (qclp_gates/rp_test.pl).
// The original file was missing from the distributed package; this is a
// reconstruction from the test's own description and expected result.
// Named-register XOR oracle, 2-bit registers, a = 1, b = 2.
// out = a XOR b, copied to copy, then out uncomputed (Bennett).
// Layout a[0..1] b[2..3] out[4..5] copy[6..7]: a=1, b=2, out=0, copy=3
// is 11 00 10 01 = |201> at 100%.
qubit[2] a;
qubit[2] b;
qubit[2] out;
qubit[2] copy;
x a[0];
x b[1];
cx a[0], out[0];
cx a[1], out[1];
cx b[0], out[0];
cx b[1], out[1];
cx out[0], copy[0];
cx out[1], copy[1];
cx a[0], out[0];
cx a[1], out[1];
cx b[0], out[0];
cx b[1], out[1];
