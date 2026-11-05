% sudoku9.txt
:- module(sudoku9, [problem_spec/1]).
problem_spec([
        % 1. Domains (Declare 1 through 9 for all 81 variables)
        fd_domain(v11, 1, 9), fd_domain(v12, 1, 9), fd_domain(v13, 1, 9), fd_domain(v14, 1, 9), fd_domain(v15, 1, 9), fd_domain(v16, 1, 9), fd_domain(v17, 1, 9), fd_domain(v18, 1, 9), fd_domain(v19, 1, 9),
        fd_domain(v21, 1, 9), fd_domain(v22, 1, 9), fd_domain(v23, 1, 9), fd_domain(v24, 1, 9), fd_domain(v25, 1, 9), fd_domain(v26, 1, 9), fd_domain(v27, 1, 9), fd_domain(v28, 1, 9), fd_domain(v29, 1, 9),
        fd_domain(v31, 1, 9), fd_domain(v32, 1, 9), fd_domain(v33, 1, 9), fd_domain(v34, 1, 9), fd_domain(v35, 1, 9), fd_domain(v36, 1, 9), fd_domain(v37, 1, 9), fd_domain(v38, 1, 9), fd_domain(v39, 1, 9),
        fd_domain(v41, 1, 9), fd_domain(v42, 1, 9), fd_domain(v43, 1, 9), fd_domain(v44, 1, 9), fd_domain(v45, 1, 9), fd_domain(v46, 1, 9), fd_domain(v47, 1, 9), fd_domain(v48, 1, 9), fd_domain(v49, 1, 9),
        fd_domain(v51, 1, 9), fd_domain(v52, 1, 9), fd_domain(v53, 1, 9), fd_domain(v54, 1, 9), fd_domain(v55, 1, 9), fd_domain(v56, 1, 9), fd_domain(v57, 1, 9), fd_domain(v58, 1, 9), fd_domain(v59, 1, 9),
        fd_domain(v61, 1, 9), fd_domain(v62, 1, 9), fd_domain(v63, 1, 9), fd_domain(v64, 1, 9), fd_domain(v65, 1, 9), fd_domain(v66, 1, 9), fd_domain(v67, 1, 9), fd_domain(v68, 1, 9), fd_domain(v69, 1, 9),
        fd_domain(v71, 1, 9), fd_domain(v72, 1, 9), fd_domain(v73, 1, 9), fd_domain(v74, 1, 9), fd_domain(v75, 1, 9), fd_domain(v76, 1, 9), fd_domain(v77, 1, 9), fd_domain(v78, 1, 9), fd_domain(v79, 1, 9),
        fd_domain(v81, 1, 9), fd_domain(v82, 1, 9), fd_domain(v83, 1, 9), fd_domain(v84, 1, 9), fd_domain(v85, 1, 9), fd_domain(v86, 1, 9), fd_domain(v87, 1, 9), fd_domain(v88, 1, 9), fd_domain(v89, 1, 9),
        fd_domain(v91, 1, 9), fd_domain(v92, 1, 9), fd_domain(v93, 1, 9), fd_domain(v94, 1, 9), fd_domain(v95, 1, 9), fd_domain(v96, 1, 9), fd_domain(v97, 1, 9), fd_domain(v98, 1, 9), fd_domain(v99, 1, 9),

        % 2. Clues (The starting puzzle board)
        fd_eq(v11, 5), fd_eq(v12, 3), fd_eq(v15, 7),
        fd_eq(v21, 6), fd_eq(v24, 1), fd_eq(v25, 9), fd_eq(v26, 5),
        fd_eq(v32, 9), fd_eq(v33, 8), fd_eq(v38, 6),
        fd_eq(v41, 8), fd_eq(v45, 6), fd_eq(v49, 3),
        fd_eq(v51, 4), fd_eq(v54, 8), fd_eq(v56, 3), fd_eq(v59, 1),
        fd_eq(v61, 7), fd_eq(v65, 2), fd_eq(v69, 6),
        fd_eq(v72, 6), fd_eq(v77, 2), fd_eq(v78, 8),
        fd_eq(v84, 4), fd_eq(v85, 1), fd_eq(v86, 9), fd_eq(v89, 5),
        fd_eq(v95, 8), fd_eq(v98, 7), fd_eq(v99, 9),

        % 3. Constraints: All 9 Rows
        fdalldifferent([v11, v12, v13, v14, v15, v16, v17, v18, v19]),
        fdalldifferent([v21, v22, v23, v24, v25, v26, v27, v28, v29]),
        fdalldifferent([v31, v32, v33, v34, v35, v36, v37, v38, v39]),
        fdalldifferent([v41, v42, v43, v44, v45, v46, v47, v48, v49]),
        fdalldifferent([v51, v52, v53, v54, v55, v56, v57, v58, v59]),
        fdalldifferent([v61, v62, v63, v64, v65, v66, v67, v68, v69]),
        fdalldifferent([v71, v72, v73, v74, v75, v76, v77, v78, v79]),
        fdalldifferent([v81, v82, v83, v84, v85, v86, v87, v88, v89]),
        fdalldifferent([v91, v92, v93, v94, v95, v96, v97, v98, v99]),

        % 4. Constraints: All 9 Columns
        fdalldifferent([v11, v21, v31, v41, v51, v61, v71, v81, v91]),
        fdalldifferent([v12, v22, v32, v42, v52, v62, v72, v82, v92]),
        fdalldifferent([v13, v23, v33, v43, v53, v63, v73, v83, v93]),
        fdalldifferent([v14, v24, v34, v44, v54, v64, v74, v84, v94]),
        fdalldifferent([v15, v25, v35, v45, v55, v65, v75, v85, v95]),
        fdalldifferent([v16, v26, v36, v46, v56, v66, v76, v86, v96]),
        fdalldifferent([v17, v27, v37, v47, v57, v67, v77, v87, v97]),
        fdalldifferent([v18, v28, v38, v48, v58, v68, v78, v88, v98]),
        fdalldifferent([v19, v29, v39, v49, v59, v69, v79, v89, v99]),

        % 5. Constraints: All 9 Sub-grids (3x3 blocks)
        fdalldifferent([v11, v12, v13, v21, v22, v23, v31, v32, v33]),
        fdalldifferent([v14, v15, v16, v24, v25, v26, v34, v35, v36]),
        fdalldifferent([v17, v18, v19, v27, v28, v29, v37, v38, v39]),
        fdalldifferent([v41, v42, v43, v51, v52, v53, v61, v62, v63]),
        fdalldifferent([v44, v45, v46, v54, v55, v56, v64, v65, v66]),
        fdalldifferent([v47, v48, v49, v57, v58, v59, v67, v68, v69]),
        fdalldifferent([v71, v72, v73, v81, v82, v83, v91, v92, v93]),
        fdalldifferent([v74, v75, v76, v84, v85, v86, v94, v95, v96]),
        fdalldifferent([v77, v78, v79, v87, v88, v89, v97, v98, v99])
    ]).
