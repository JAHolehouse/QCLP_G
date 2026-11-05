%% ============================================================
%%  rp_demo.pl  --  RProlog interactive demo and QASM export
%%
%%  This module provides the interactive workflow:
%%
%%    compile_and_show(+Goal, +Module)
%%      Compile, show microcode, show Layer 2 and Layer 3 QASM.
%%
%%    compile_and_export(+Goal, +Module, +File)
%%    compile_and_export(+Goal, +Module, +File, +Bits)
%%      Compile and write a complete QASM 3.0 file.
%%      Default bit-width is 4.
%%
%%    rp_pipeline(+Goal, +Module)
%%      Show the full pipeline stage by stage.
%%
%%  Example session:
%%
%%    ?- [load].
%%    ?- compile_and_show(rp_xor(a,b,out), rp_arith).
%%    ?- compile_and_export(rp_mod_add(a,b,15,out), rp_arith, 'mod_add.qasm').
%%    ?- rp_pipeline(rp_mod_exp(2,exp,15,out), rp_arith).
%% ============================================================

:- module(rp_demo, [
    compile_and_show/2,
    compile_and_export/3,
    compile_and_export/4,
    rp_pipeline/2,
    rp_write_qasm/2,
    rp_write_qasm/3,
    qasm_path/2,        % +Filename, -Path  resolve into qasm/ subdir
    ensure_qasm_dir/0   % create qasm/ if it does not exist
]).

:- use_module(rp_engine).
:- use_module(rp_namer).
:- use_module(rp_gates).
:- use_module(rp_fold).
:- use_module(rp_ite).

%% ============================================================
%%  compile_and_show/2
%%  The quick inspection predicate.
%% ============================================================

compile_and_show(Goal, Module) :-
    format("~n~`=t~60|~n"),
    format("QCLP_G: ~w~n", [Goal]),
    format("~`=t~60|~n"),

    %% Compile
    rp_compile(Goal, Module, RawMC),
    rp_rename(RawMC, MC),

    %% Microcode
    format("~n-- Microcode --~n"),
    rp_show(MC),

    %% Layer 2 QASM (named ops)
    format("~n-- Layer 2 QASM (named operations) --~n"),
    rp_qasm(MC, L2),
    maplist(writeln, L2),

    %% Layer 3 QASM (real gates, default 4-bit)
    format("~n-- Layer 3 QASM (real gates, 4-bit) --~n"),
    rp_ops(MC, Ops),
    rp_expand_ops(Ops, L3),
    ( L3 = [] ->
        format("  (no arithmetic operations to expand)~n")
    ;   maplist(writeln, L3)
    ).

%% ============================================================
%%  compile_and_export/3,4
%%  Compile and write a complete QASM 3.0 file.
%% ============================================================

compile_and_export(Goal, Module, File) :-
    compile_and_export(Goal, Module, File, 4).

compile_and_export(Goal, Module, File, Bits) :-
    rp_compile(Goal, Module, RawMC),
    rp_rename(RawMC, MC),
    rp_write_qasm(MC, File, Bits),
    format("Written: ~w (~w-bit)~n", [File, Bits]).

%% ============================================================
%%  rp_write_qasm/2,3
%%  Write a complete QASM 3.0 file from microcode.
%% ============================================================

rp_write_qasm(MC, File) :-
    rp_write_qasm(MC, File, 4).

rp_write_qasm(MC, File, Bits) :-
    rp_ite:collect_events(MC, Ops),
    build_qasm_document(MC, Ops, Bits, Lines),
    ensure_qasm_dir,
    qasm_path(File, Path),
    setup_call_cleanup(
        open(Path, write, Stream),
        maplist([L]>>(write(Stream,L), nl(Stream)), Lines),
        close(Stream)
    ).

%% ============================================================
%%  rp_pipeline/2
%%  Show the full pipeline stage by stage with explanation.
%% ============================================================

rp_pipeline(Goal, Module) :-
    format("~n~`=t~60|~n"),
    format("QCLP_G Pipeline: ~w~n", [Goal]),
    format("~`=t~60|~n"),

    rp_compile(Goal, Module, RawMC),
    rp_rename(RawMC, MC),
    rp_ops(MC, Ops),

    format("~n[Stage 1] Source~n"),
    format("  ~w~n", [Goal]),

    format("~n[Stage 2] Microcode~n"),
    format("  Events in - (the reversible execution trace):~n"),
    rp_show(MC),

    format("~n[Stage 3] Structured ops (AST)~n"),
    format("  Arithmetic operations extracted for circuit synthesis:~n"),
    ( Ops = [] ->
        format("  (none -- pure structural computation)~n")
    ;   maplist([Op]>>(format("  ~w~n",[Op])), Ops)
    ),

    format("~n[Stage 4] Layer 2 QASM (named operations)~n"),
    format("  Readable, register-level description:~n"),
    rp_qasm(MC, L2),
    maplist([L]>>(format("  ~w~n",[L])), L2),

    format("~n[Stage 5] Layer 3 QASM (4-bit physical gates)~n"),
    format("  Real cx/ccx/x gate sequences:~n"),
    rp_expand_ops(Ops, L3),
    ( L3 = [] ->
        format("  (no arithmetic to expand)~n")
    ;   maplist([L]>>(format("  ~w~n",[L])), L3)
    ),

    format("~n[Stage 6] Export~n"),
    format("  rp_write_qasm(MC, 'output.qasm').~n"),
    format("  rp_write_qasm(MC, 'output.qasm', 8).   %% 8-bit~n"),
    format("~n").

%% ============================================================
%%  QASM document builder
%%  Produces a complete self-contained QASM 3.0 file.
%% ============================================================

build_qasm_document(_MC, Ops, Bits, Lines) :-
    %% Collect variable names from all events (ops and ite_mux)
    findall(W, (
        member(Ev, Ops),
        ( Ev = op(_,A,B,V)          -> Ws=[A,B,V]
        ; Ev = ite_mux(C,O,T,El)    -> Ws=[C,O,T,El]
        ; Ws=[] ),
        member(W, Ws),
        atom(W), \+ number(W)
    ), AllW0),
    list_to_set(AllW0, VarNames),

    %% Register declarations: one N-bit register per variable
    %% Plus carry ancilla and result
    length(VarNames, NVars),
    ExtraRegs = 2,   %% carry + result
    NRegs is NVars + ExtraRegs,
    TotalQ is NRegs * Bits,

    %% Build wire map: var -> base qubit index
    build_wire_map_doc(VarNames, Bits, WireMap),

    %% Header
    format(atom(QReg), "qubit[~w] q;", [TotalQ]),
    Header = [
        "OPENQASM 3.0;",
        "include \"stdgates.inc\";",
        "//",
        "// Generated by QCLP_G",
        "//",
        "", QReg, ""
    ],

    %% Register comments
    reg_comments(VarNames, WireMap, Bits, RegComments),

    %% Forward gates
    CarryBase is NVars * Bits,
    forward_gate_lines(Ops, WireMap, Bits, CarryBase, FwdLines),

    %% Output copy
    output_copy_lines(Ops, WireMap, Bits, NVars, CopyLines),

    %% Uncompute (reverse)
    reverse(Ops, RevOps),
    forward_gate_lines(RevOps, WireMap, Bits, CarryBase, UncLines),

    append([Header,
            RegComments,
            ["// === compute ==="],
            FwdLines,
            ["", "// === copy output ==="],
            CopyLines,
            ["", "// === uncompute (Bennett) ==="],
            UncLines,
            ["// end"]], Lines).

build_wire_map_doc(Vars, Bits, WireMap) :-
    build_wm_fwd(Vars, 0, Bits, WireMap).

last_output_var(op(_,_,_,V),       V).
last_output_var(ite_mux(_,Out,_,_), Out).

build_wm_fwd([], _, _, []).
build_wm_fwd([V|Vs], Idx, Bits, [V-Idx|Rest]) :-
    Next is Idx + Bits,
    build_wm_fwd(Vs, Next, Bits, Rest).

reg_comments([], _, _, []).
reg_comments([V|Vs], WM, Bits, [L|Rest]) :-
    member(V-Base, WM),
    Top is Base + Bits - 1,
    format(atom(L), "// ~w  -> q[~w..~w]", [V, Base, Top]),
    reg_comments(Vs, WM, Bits, Rest).

%% Gate lines from op/4 terms using wire map
forward_gate_lines([], _, _, _, []).
forward_gate_lines([op(Op,A,B,V)|Rest], WM, Bits, Carry, Lines) :-
    !,
    op_to_gates(Op, A, B, V, WM, Bits, Carry, OpLines),
    forward_gate_lines(Rest, WM, Bits, Carry, RestLines),
    append(OpLines, RestLines, Lines).
forward_gate_lines([ite_mux(Ctrl,Out,Then,Else)|Rest], WM, Bits, Carry, Lines) :-
    !,
    rp_ite:ite_to_lines(ite_mux(Ctrl,Out,Then,Else), WM, Bits, IteLines),
    forward_gate_lines(Rest, WM, Bits, Carry, RestLines),
    append(IteLines, RestLines, Lines).
forward_gate_lines([_|Rest], WM, Bits, Carry, Lines) :-
    forward_gate_lines(Rest, WM, Bits, Carry, Lines).

op_to_gates(rev_xor, A, B, V, WM, Bits, _, Lines) :-
    wire_qs(A, WM, Bits, AQs), wire_qs(B, WM, Bits, BQs),
    wire_qs(V, WM, Bits, VQs),
    xor_gate_lines(AQs, BQs, VQs, Lines).
op_to_gates(rev_and, A, B, V, WM, Bits, _, Lines) :-
    wire_qs(A, WM, Bits, AQs), wire_qs(B, WM, Bits, BQs),
    wire_qs(V, WM, Bits, VQs),
    and_gate_lines(AQs, BQs, VQs, Lines).
op_to_gates(rev_add, A, B, V, WM, Bits, Carry, Lines) :-
    wire_qs(A, WM, Bits, AQs), wire_qs(B, WM, Bits, BQs),
    wire_qs(V, WM, Bits, VQs),
    carry_qs(Carry, Bits, CQs),
    adder_gate_lines(AQs, BQs, VQs, CQs, Lines).
op_to_gates(rev_sub, A, B, V, WM, Bits, _Carry, Lines) :-
    wire_qs(A, WM, Bits, AQs), wire_qs(B, WM, Bits, BQs),
    wire_qs(V, WM, Bits, VQs),
    AQs == [],
    Bits =:= 1,
    !,
    %% Constant - register (e.g. rp_not: out = 1 - a).
    %% For Bits=1 this is exactly bitwise NOT: V = ~B.
    %% For Bits>1, "1 - b" is not bitwise NOT, and the
    %% register-register case has no implementation either --
    %% both fall through to the unsupported-case clause below.
    copy_flat_lines(BQs, VQs, CopyL),
    maplist([Vq,L]>>format(atom(L),"x q[~w];",[Vq]), VQs, FlipL),
    append(CopyL, FlipL, Lines).
op_to_gates(rev_sub, _, _, V, _, Bits, _, [L]) :-
    !,
    format(atom(L),
        "// *** rev_sub (~w) not yet supported for Bits=~w ***",
        [V, Bits]).
op_to_gates(rev_mod, A, N, V, WM, Bits, Carry, Lines) :-
    wire_qs(A, WM, Bits, AQs),
    wire_qs(V, WM, Bits, VQs),
    carry_qs(Carry, Bits, CQs),
    ( integer(N) -> NVal=N ; NVal=15 ),
    mod_gate_lines(AQs, NVal, VQs, CQs, Bits, Lines).
op_to_gates(rev_mul, A, B, V, WM, Bits, _, Lines) :-
    wire_qs(A, WM, Bits, AQs), wire_qs(B, WM, Bits, BQs),
    wire_qs(V, WM, Bits, VQs),
    mul_gate_lines(AQs, BQs, VQs, Lines).
op_to_gates(rev_shr, A, N, V, WM, Bits, _, Lines) :-
    wire_qs(A, WM, Bits, AQs),
    wire_qs(V, WM, Bits, VQs),
    ( integer(N) -> NVal=N ; NVal=1 ),
    shr_gate_lines(AQs, NVal, VQs, Lines).
op_to_gates(_, _, _, _, _, _, _, []).

wire_qs(Name, WM, Bits, Qs) :-
    ( atom(Name), \+ number(Name), member(Name-Base, WM) ->
        Bits1 is Bits-1, numlist(0, Bits1, Offs),
        maplist([Off,Q]>>(Q is Base+Off), Offs, Qs)
    ;   Qs = []
    ).

carry_qs(CarryBase, Bits, Qs) :-
    Bits1 is Bits-1, numlist(0, Bits1, Offs),
    maplist([Off,Q]>>(Q is CarryBase+Off), Offs, Qs).

output_copy_lines(Ops, WM, Bits, NVars, Lines) :-
    ( Ops \= [], last(Ops, LastEv),
      last_output_var(LastEv, LastVar),
      member(LastVar-SrcBase, WM) ->
        ResultBase is NVars * Bits,
        Bits1 is Bits-1, numlist(0, Bits1, Offs),
        maplist([Off,L]>>(
            S is SrcBase+Off, D is ResultBase+Off,
            format(atom(L),"cx q[~w], q[~w];",[S,D])
        ), Offs, Lines)
    ;   Lines = []
    ).

%% Gate line generators (flat q[i] indices)
xor_gate_lines([], [], [], []).
xor_gate_lines([A|As],[B|Bs],[V|Vs],[L1,L2|R]) :-
    format(atom(L1),"cx q[~w], q[~w];",[A,V]),
    format(atom(L2),"cx q[~w], q[~w];",[B,V]),
    xor_gate_lines(As,Bs,Vs,R).
xor_gate_lines([],[],_,[]).
xor_gate_lines([],_,[],[]).

and_gate_lines([],[],[],[]).
and_gate_lines([A|As],[B|Bs],[V|Vs],[L|R]) :-
    format(atom(L),"ccx q[~w], q[~w], q[~w];",[A,B,V]),
    and_gate_lines(As,Bs,Vs,R).

adder_gate_lines(AQs,BQs,VQs,CQs,Lines) :-
    maj_lines_q(AQs,BQs,CQs,MajL),
    last(VQs,Vmsb), last(CQs,Cmsb),
    format(atom(MsbL),"cx q[~w], q[~w];",[Cmsb,Vmsb]),
    reverse(AQs,RA), reverse(BQs,RB),
    reverse(CQs,RC), reverse(VQs,RV),
    uma_lines_q(RA,RB,RC,RV,UmaL),
    append([MajL,[MsbL],UmaL],Lines).

%%  copy_flat_lines(+SrcQs, +DstQs, -Lines)
copy_flat_lines([], [], []).
copy_flat_lines([S|Ss], [D|Ds], [L|R]) :-
    format(atom(L), "cx q[~w], q[~w];", [S,D]),
    copy_flat_lines(Ss, Ds, R).

maj_lines_q([],[],[],[]).
maj_lines_q([A|As],[B|Bs],[C|Cs],[L1,L2,L3|R]) :-
    format(atom(L1),"cx q[~w], q[~w];",[A,C]),
    format(atom(L2),"cx q[~w], q[~w];",[A,B]),
    format(atom(L3),"ccx q[~w], q[~w], q[~w];",[B,C,A]),
    maj_lines_q(As,Bs,Cs,R).

uma_lines_q([],[],[],[],[]).
uma_lines_q([A|As],[B|Bs],[C|Cs],[Z|Zs],[L1,L2,L3,L4|R]) :-
    format(atom(L1),"ccx q[~w], q[~w], q[~w];",[B,C,A]),
    format(atom(L2),"cx q[~w], q[~w];",[A,C]),
    format(atom(L3),"cx q[~w], q[~w];",[C,B]),
    format(atom(L4),"cx q[~w], q[~w];",[B,Z]),
    uma_lines_q(As,Bs,Cs,Zs,R).

mod_gate_lines(AQs,N,VQs,_CQs,Bits,Lines) :-
    copy_q_lines(AQs,VQs,CopyL),
    int_bits_q(N,Bits,NBits),
    cmp_q_lines(VQs,NBits,CmpL),
    csub_q_lines(VQs,NBits,SubL),
    cmp_q_lines(VQs,NBits,UCmpL),
    append([CopyL,CmpL,SubL,UCmpL],Lines).

copy_q_lines([],[],[]).
copy_q_lines([S|Ss],[D|Ds],[L|R]) :-
    format(atom(L),"cx q[~w], q[~w];",[S,D]),
    copy_q_lines(Ss,Ds,R).

cmp_q_lines([],[],[]).
cmp_q_lines([Z|Zs],[B|Bs],Lines) :-
    ( B=:=1 ->
        format(atom(L),"cx q[~w], q[0];",[Z]),
        cmp_q_lines(Zs,Bs,R), Lines=[L|R]
    ;   cmp_q_lines(Zs,Bs,Lines)
    ).

csub_q_lines([],[],[]).
csub_q_lines([Z|Zs],[B|Bs],Lines) :-
    ( B=:=1 ->
        format(atom(L),"ccx q[0], q[~w], q[~w];",[Z,Z]),
        csub_q_lines(Zs,Bs,R), Lines=[L|R]
    ;   csub_q_lines(Zs,Bs,Lines)
    ).

int_bits_q(N,Bits,Bs) :-
    B1 is Bits-1, numlist(0,B1,Ps),
    maplist([P,B]>>(B is (N>>P)/\1),Ps,Bs).

mul_gate_lines(AQs,BQs,VQs,Lines) :-
    findall(L,(
        nth0(I,BQs,YI), nth0(J,AQs,XJ),
        K is I+J, nth0(K,VQs,ZK),
        format(atom(L),"ccx q[~w], q[~w], q[~w];",[YI,XJ,ZK])
    ),Lines).

shr_gate_lines(AQs,1,VQs,Lines) :-
    length(AQs,Len),
    findall([L1,L2,L3],(
        nth0(I,VQs,Dst),
        SI is I+1, SI<Len,
        nth0(SI,AQs,Src),
        format(atom(L1),"cx q[~w], q[~w];",[Src,Dst]),
        format(atom(L2),"cx q[~w], q[~w];",[Dst,Src]),
        format(atom(L3),"cx q[~w], q[~w];",[Src,Dst])
    ),Triples),
    flatten(Triples,Lines).
shr_gate_lines(_,_,_,[]).


%% ============================================================
%%  QASM output directory helpers
%%
%%  All QASM files are written to a qasm/ subdirectory of the
%%  current working directory.  This keeps the source folder
%%  clean and makes it easy to find generated circuits.
%%
%%  qasm_path(+File, -Path)
%%    If File already contains a directory component, use it
%%    as-is.  Otherwise prepend 'qasm/'.
%%
%%  ensure_qasm_dir/0
%%    Create the qasm/ subdirectory if it does not exist.
%%    Called automatically by all QASM write predicates.
%% ============================================================

ensure_qasm_dir :-
    ( exists_directory('qasm') -> true
    ;   make_directory('qasm'),
        format("  [created qasm/ output directory]~n")
    ).

qasm_path(File, Path) :-
    ( file_directory_name(File, Dir), Dir \= '.' ->
        %% User gave an explicit path -- respect it
        Path = File
    ;   %% Plain filename -- put in qasm/
        atomic_list_concat(['qasm/', File], Path)
    ).
