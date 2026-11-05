%% ============================================================
%%  rp_costs -- gate cost reference table
%%  rp_cost_table/0  prints the table
%%  rp_cost/4        queries a single entry
%% ============================================================

:- module(rp_costs, [rp_cost_table/0, rp_cost/4]).

%% rp_cost(Operation, Gate_implementation, Ancilla, T_gates)
rp_cost(xor,     'CNOT chain',            '0',    '0'    ).
rp_cost(and,     'Toffoli',               '1',    '7'    ).
rp_cost(or,      'Toffoli+CNOTs',         '1',    '7'    ).
rp_cost(not,     'Pauli-X',               '0',    '0'    ).
rp_cost(mux,     'Fredkin (ctrl-swap)',   '0',    '7'    ).
rp_cost(shr,     'SWAP network',          '0',    '0'    ).
rp_cost(shl,     'SWAP network',          '0',    '0'    ).
rp_cost(bit,     'SHR + AND',             '1',    '7'    ).
rp_cost(add,     'Ripple-carry adder',    'n',    '7n'   ).
rp_cost(sub,     'Ripple-carry subtract', 'n',    '7n'   ).
rp_cost(mul,     'Schoolbook multiplier', 'n',    '7n^2' ).
rp_cost(mod,     'Comparator+subtract',  'n',    '14n'  ).
rp_cost(divmod,  'Restoring divider',    '2n',   '14n^2').
rp_cost(mod_add, 'Modular adder',        'n',    '14n'  ).
rp_cost(mod_sub, 'Modular subtractor',   'n',    '14n'  ).
rp_cost(mod_mul, 'Montgomery mul',       '2n',   '14n^2').
rp_cost(mod_exp, 'mod_exp (K-bit exp)',  '4n',   '14Kn^2').
rp_cost(gcd,     'Classical only',       '-',    '-'    ).
rp_cost(compare, 'Carry-lookahead cmp',  'n',    '7n'   ).

rp_cost_table :-
    format("~n~`=t~65|~n"),
    format("~w~t~18|~w~t~42|~w~t~52|~w~n",
           ['Operation','Gate implementation','Ancilla','T-gates']),
    format("~`-t~65|~n"),
    forall(rp_cost(Op,Gate,Anc,T),
           format("~w~t~18|~w~t~42|~w~t~52|~w~n",[Op,Gate,Anc,T])),
    format("~`=t~65|~n"),
    format("n=bit-width  K=exponent bit-width  T-gates dominate fault-tolerant cost~n").
