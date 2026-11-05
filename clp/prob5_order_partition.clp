% Problem 5: Order Partitioning
% Stocks: A=300,B=100,C=100,D=200,E=200,F=100  Total=1000
% xi=1 means stock i goes into group A
% Hard: value balance: 300xA+100xB+100xC+200xD+200xE+100xF = 500
% Soft: risk factor 1 balance (the paper has 3 risk factors; only factor 1 is modelled here)
% Best solution: {A,B,C} vs {D,E,F} -- value and risk factor 1 both balanced, penalty 0

problem_spec([
    fd_domain(xA, 0, 1),
    fd_domain(xB, 0, 1),
    fd_domain(xC, 0, 1),
    fd_domain(xD, 0, 1),
    fd_domain(xE, 0, 1),
    fd_domain(xF, 0, 1),

    % Scaled stock values for sum chain
    fd_domain(sA, [0, 300]),  fd_domain(wA, [300,300]), fd_eq(wA,300), fd_product_eq(xA, wA, sA),
    fd_domain(sB, [0, 100]),  fd_domain(wB, [100,100]), fd_eq(wB,100), fd_product_eq(xB, wB, sB),
    fd_domain(sC, [0, 100]),  fd_domain(wC, [100,100]), fd_eq(wC,100), fd_product_eq(xC, wC, sC),
    fd_domain(sD, [0, 200]),  fd_domain(wD, [200,200]), fd_eq(wD,200), fd_product_eq(xD, wD, sD),
    fd_domain(sE, [0, 200]),  fd_domain(wE, [200,200]), fd_eq(wE,200), fd_product_eq(xE, wE, sE),
    fd_domain(sF, [0, 100]),  fd_domain(wF, [100,100]), fd_eq(wF,100), fd_product_eq(xF, wF, sF),

    % Value sum chain: sA+sB=t1, t1+sC=t2, ..., t5+sF=total
    fd_domain(t1, 0, 1000), fdsumeq(sA, sB, t1),
    fd_domain(t2, 0, 1000), fdsumeq(t1, sC, t2),
    fd_domain(t3, 0, 1000), fdsumeq(t2, sD, t3),
    fd_domain(t4, 0, 1000), fdsumeq(t3, sE, t4),
    fd_domain(t5, 0, 1000), fdsumeq(t4, sF, t5),
    fd_eq(t5, 500),

    % Risk factor soft constraints (scaled by 10 for integer arithmetic)
    % Factor 1: 3xA+1xB+1xC+2xD+2xE+1xF balanced (sum = 5 for perfect)
    fd_domain(r1A,[0,3]), fd_domain(w1A,[3,3]), fd_eq(w1A,3), fd_product_eq(xA,w1A,r1A),
    fd_domain(r1B,[0,1]), fd_domain(w1B,[1,1]), fd_eq(w1B,1), fd_product_eq(xB,w1B,r1B),
    fd_domain(r1C,[0,1]), fd_domain(w1C,[1,1]), fd_eq(w1C,1), fd_product_eq(xC,w1C,r1C),
    fd_domain(r1D,[0,2]), fd_domain(w1D,[2,2]), fd_eq(w1D,2), fd_product_eq(xD,w1D,r1D),
    fd_domain(r1E,[0,2]), fd_domain(w1E,[2,2]), fd_eq(w1E,2), fd_product_eq(xE,w1E,r1E),
    fd_domain(r1F,[0,1]), fd_domain(w1F,[1,1]), fd_eq(w1F,1), fd_product_eq(xF,w1F,r1F),
    fd_domain(rt1a, 0,5), fdsumeq(r1A,r1B,rt1a),
    fd_domain(rt1b, 0,5), fdsumeq(rt1a,r1C,rt1b),
    fd_domain(rt1c, 0,5), fdsumeq(rt1b,r1D,rt1c),
    fd_domain(rt1d, 0,5), fdsumeq(rt1c,r1E,rt1d),
    fd_domain(rt1e, 0,5), fdsumeq(rt1d,r1F,rt1e),
    fd_cost(10, fd_eq(rt1e, 5))    % soft: penalty 10 if risk factor 1 is NOT balanced (violated)
]).
