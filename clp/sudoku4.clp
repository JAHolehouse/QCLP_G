% sudoku4.txt
:- module(sudoku4, [problem_spec/1]).
problem_spec([
  % domains: cells 1..4
  fd_domain(c11,1,4), fd_domain(c12,1,4), fd_domain(c13,1,4), fd_domain(c14,1,4),
  fd_domain(c21,1,4), fd_domain(c22,1,4), fd_domain(c23,1,4), fd_domain(c24,1,4),
  fd_domain(c31,1,4), fd_domain(c32,1,4), fd_domain(c33,1,4), fd_domain(c34,1,4),
  fd_domain(c41,1,4), fd_domain(c42,1,4), fd_domain(c43,1,4), fd_domain(c44,1,4),

  % given clues (example): row1: 1 _ _ 4 ; row4: _ _ 3 _
  fd_eq(c11,1), fd_eq(c14,4), fd_eq(c43,3),

  % rows
  fdalldifferent([c11,c12,c13,c14]),
  fdalldifferent([c21,c22,c23,c24]),
  fdalldifferent([c31,c32,c33,c34]),
  fdalldifferent([c41,c42,c43,c44]),

  % columns
  fdalldifferent([c11,c21,c31,c41]),
  fdalldifferent([c12,c22,c32,c42]),
  fdalldifferent([c13,c23,c33,c43]),
  fdalldifferent([c14,c24,c34,c44]),

  % 2x2 blocks
  fdalldifferent([c11,c12,c21,c22]),
  fdalldifferent([c13,c14,c23,c24]),
  fdalldifferent([c31,c32,c41,c42]),
  fdalldifferent([c33,c34,c43,c44])
]).
