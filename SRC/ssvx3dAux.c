
/**
 * @brief Validates the input parameters for a given problem.
 *
 * This function checks the input parameters for a given problem and sets the
 * error code in the 'info' variable accordingly. If there is an error, it
 * prints an error message and returns.
 *
 * @param[in] options Pointer to the options structure containing Fact, RowPerm, ColPerm, and IterRefine values.
 * @param[in] A Pointer to the matrix A structure containing nrow, ncol, Stype, Dtype, and Mtype values.
 * @param[in] ldb The leading dimension of the array B.
 * @param[in] nrhs The number of right-hand sides.
 * @param[in] grid Pointer to the grid structure.
 * @param[out] info Pointer to an integer variable that stores the error code.
 */
void validateInput_ssvx3d(superlu_dist_options_t *options, SuperMatrix *A,int ldb, int nrhs, gridinfo3d_t *grid3d, int *info)
{
    gridinfo_t *grid = &(grid3d->grid2d);
    NRformat_loc *Astore = A->Store;
    int Fact = options->Fact;
    if (Fact < 0 || Fact > FACTORED)
        *info = -1;
    else if (options->RowPerm < 0 || options->RowPerm > MY_PERMR)
        *info = -1;
    else if (options->ColPerm < 0 || options->ColPerm > MY_PERMC)
        *info = -1;
    else if (options->IterRefine < 0 || options->IterRefine > SLU_EXTRA)
        *info = -1;
    else if (options->IterRefine == SLU_EXTRA)
    {
        *info = -1;
        fprintf(stderr,
                "Extra precise iterative refinement yet to support.");
    }
    else if (A->nrow != A->ncol || A->nrow < 0 || A->Stype != SLU_NR_loc || A->Dtype != SLU_D || A->Mtype != SLU_GE)
        *info = -2;
    else if (ldb < Astore->m_loc)
        *info = -5;
    else if (nrhs < 0)
    {
        *info = -6;
    }
    if (*info)
    {
        int i = -(*info);
        pxerr_dist("pdgssvx3d", grid, -(*info));
        return;
    }
} 


void scaleRows(int_t m_loc, int_t fst_row, int_t *rowptr, double *a, double *R) {
    int_t irow = fst_row;
    for (int_t j = 0; j < m_loc; ++j) {
        for (int_t i = rowptr[j]; i < rowptr[j + 1]; ++i) {
            a[i] *= R[irow];
        }
        ++irow;
    }
}

void scaleColumns(int_t m_loc, int_t *rowptr, int_t *colind, double *a, double *C) {
    int_t icol;
    for (int_t j = 0; j < m_loc; ++j) {
        for (int_t i = rowptr[j]; i < rowptr[j + 1]; ++i) {
            icol = colind[i];
            a[i] *= C[icol];
        }
    }
}

void scaleBoth(int_t m_loc, int_t fst_row, int_t *rowptr, 
    int_t *colind, double *a, double *R, double *C) {
    int_t irow = fst_row;
    int_t icol;
    for (int_t j = 0; j < m_loc; ++j) {
        for (int_t i = rowptr[j]; i < rowptr[j + 1]; ++i) {
            icol = colind[i];
            a[i] *= R[irow] * C[icol];
        }
        ++irow;
    }
}

void scalePrecomputed(SuperMatrix *A, dScalePermstruct_t *ScalePermstruct) {
    NRformat_loc *Astore = (NRformat_loc *)A->Store;
    int_t m_loc = Astore->m_loc;
    int_t fst_row = Astore->fst_row;
    double *a = (double *)Astore->nzval;
    int_t *rowptr = Astore->rowptr;
    int_t *colind = Astore->colind;
    double *R = ScalePermstruct->R;
    double *C = ScalePermstruct->C;
    switch (ScalePermstruct->DiagScale) {
    case NOEQUIL:
        break;
    case ROW:
        scaleRows(m_loc, fst_row, rowptr, a, R);
        break;
    case COL:
        scaleColumns(m_loc, rowptr, colind, a, C);
        break;
    case BOTH:
        scaleBoth(m_loc, fst_row, rowptr, colind, a, R, C);
        break;
    default:
        break;
    }
}

void scaleFromScratch(
    SuperMatrix *A, dScalePermstruct_t *ScalePermstruct,  
    gridinfo_t *grid, int_t *rowequ, int_t *colequ, int_t*iinfo)  
{
    NRformat_loc *Astore = (NRformat_loc *)A->Store;
    int_t m_loc = Astore->m_loc;
    int_t fst_row = Astore->fst_row;
    double *a = (double *)Astore->nzval;
    int_t *rowptr = Astore->rowptr;
    int_t *colind = Astore->colind;
    double *R = ScalePermstruct->R;
    double *C = ScalePermstruct->C;
    double rowcnd, colcnd, amax;
    // int_t iinfo;
    char equed[1];
    int iam = grid->iam;

    pdgsequ(A, R, C, &rowcnd, &colcnd, &amax, iinfo, grid);

    if (*iinfo > 0) {
#if (PRNTlevel >= 1)
        fprintf(stderr, "The " IFMT "-th %s of A is exactly zero\n", *iinfo <= m_loc ? *iinfo : *iinfo - m_loc, *iinfo <= m_loc ? "row" : "column");
#endif
    } else if (*iinfo < 0) {
        return;
    }

    pdlaqgs(A, R, C, rowcnd, colcnd, amax, equed);

    if      (strncmp(equed, "R", 1) == 0) { ScalePermstruct->DiagScale = ROW; *rowequ = 1; *colequ = 0; }
    else if (strncmp(equed, "C", 1) == 0) { ScalePermstruct->DiagScale = COL; *rowequ = 0; *colequ = 1; }
    else if (strncmp(equed, "B", 1) == 0) { ScalePermstruct->DiagScale = BOTH; *rowequ = 1; *colequ = 1; }
    else                                  { ScalePermstruct->DiagScale = NOEQUIL; *rowequ = 0; *colequ = 0; }

#if (PRNTlevel >= 1)
    if (iam == 0) {
        printf(".. equilibrated? *equed = %c\n", *equed);
        fflush(stdout);
    }
#endif
}

void scaleMatrixDiagonally(fact_t Fact, dScalePermstruct_t *ScalePermstruct, 
                           SuperMatrix *A, SuperLUStat_t *stat, gridinfo_t *grid,
                            int_t *rowequ, int_t *colequ, int_t*iinfo)   
{
    int iam = grid->iam;

#if (DEBUGlevel >= 1)
    CHECK_MALLOC(iam, "Enter equil");
#endif

    double t_start = SuperLU_timer_();

    if (Fact == SamePattern_SameRowPerm) {
        scalePrecomputed(A, ScalePermstruct);
    } else {
        scaleFromScratch(A, ScalePermstruct, grid, rowequ, colequ, iinfo);
    }

    stat->utime[EQUIL] = SuperLU_timer_() - t_start;

#if (DEBUGlevel >= 1)
    CHECK_MALLOC(iam, "Exit equil");
#endif
}


void perform_LargeDiag_MC64(
    superlu_dist_options_t* options, 
    fact_t Fact, 
    dScalePermstruct_t *ScalePermstruct,
    dLUstruct_t *LUstruct,
    int m, int n, 
    gridinfo_t* grid, 
    int_t* perm_r,
    SuperMatrix* A, 
    SuperMatrix* GA,
    SuperLUStat_t* stat, 
    int job, 
    int Equil, 
    int rowequ, 
    int colequ) 
{
    /* Note: R1 and C1 are now local variables */
    double* R1 = NULL;
    double* C1 = NULL;

    /* Extract necessary data from the input arguments */
    // dScalePermstruct_t* ScalePermstruct = A->ScalePermstruct;
    // dLUstruct_t* LUstruct = A->LUstruct;
    perm_r = ScalePermstruct->perm_r;
    int_t* perm_c = ScalePermstruct->perm_c;
    int_t* etree = LUstruct->etree;
    double* R = ScalePermstruct->R;
    double* C = ScalePermstruct->C;
    int iam = grid->iam;

    /* Get NR format Data*/
    #warning need to chanck the following code
    NRformat_loc *Astore = (NRformat_loc *)A->Store;
    int_t nnz_loc = Astore->nnz_loc;
    int_t m_loc = Astore->m_loc;
    int_t fst_row = Astore->fst_row;
    double *a = (double *)Astore->nzval;
    int_t *rowptr = Astore->rowptr;
    int_t *colind = Astore->colind;


    /* Get NC format data from SuperMatrix GA */
    NCformat* GAstore = (NCformat *)GA->Store;
    int_t* colptr = GAstore->colptr;
    int_t* rowind = GAstore->rowind;
    int nnz = GAstore->nnz;
    double* a_GA = (double *)GAstore->nzval;
    /* Rest of the code goes here... */

    /* Get a new perm_r[] */
    if (job == 5)
    {
        /* Allocate storage for scaling factors. */
        if (!(R1 = doubleMalloc_dist(m)))
            ABORT("SUPERLU_MALLOC fails for R1[]");
        if (!(C1 = doubleMalloc_dist(n)))
            ABORT("SUPERLU_MALLOC fails for C1[]");
    }

    int iinfo;
    if (iam == 0)
    {
        /* Process 0 finds a row permutation */
        iinfo = dldperm_dist(job, m, nnz, colptr, rowind, a_GA,
                             perm_r, R1, C1);
        MPI_Bcast(&iinfo, 1, mpi_int_t, 0, grid->comm);
        if (iinfo == 0)
        {
            MPI_Bcast(perm_r, m, mpi_int_t, 0, grid->comm);
            if (job == 5 && Equil)
            {
                MPI_Bcast(R1, m, MPI_DOUBLE, 0, grid->comm);
                MPI_Bcast(C1, n, MPI_DOUBLE, 0, grid->comm);
            }
        }
    }
    else
    {
        MPI_Bcast(&iinfo, 1, mpi_int_t, 0, grid->comm);
        if (iinfo == 0)
        {
            MPI_Bcast(perm_r, m, mpi_int_t, 0, grid->comm);
            if (job == 5 && Equil)
            {
                MPI_Bcast(R1, m, MPI_DOUBLE, 0, grid->comm);
                MPI_Bcast(C1, n, MPI_DOUBLE, 0, grid->comm);
            }
        }
    }

    if (iinfo && job == 5)
    { /* Error return */
        SUPERLU_FREE(R1);
        SUPERLU_FREE(C1);
    }
#if (PRNTlevel >= 2)
    double dmin = damch_dist("Overflow");
    double dsum = 0.0;
    double dprod = 1.0;
#endif
    if (iinfo == 0)
    {
        if (job == 5)
        {
            if (Equil)
            {
                for (int i = 0; i < n; ++i)
                {
                    R1[i] = exp(R1[i]);
                    C1[i] = exp(C1[i]);
                }

                /* Scale the distributed matrix further.
                   A <-- diag(R1)*A*diag(C1)            */
                int irow = fst_row;
                for (int j = 0; j < m_loc; ++j)
                {
                    for (int i = rowptr[j]; i < rowptr[j + 1]; ++i)
                    {
                        int icol = colind[i];
                        a[i] *= R1[irow] * C1[icol];
#if (PRNTlevel >= 2)
                        if (perm_r[irow] == icol)
                        {
                            /* New diagonal */
                            if (job == 2 || job == 3)
                                dmin = SUPERLU_MIN(dmin, fabs(a[i]));
                            else if (job == 4)
                                dsum += fabs(a[i]);
                            else if (job == 5)
                                dprod *= fabs(a[i]);
                        }
#endif
                    }
                    ++irow;
                }

                /* Multiply together the scaling factors --
                   R/C from simple scheme, R1/C1 from MC64. */
                if (rowequ)
                    for (int i = 0; i < m; ++i)
                        R[i] *= R1[i];
                else
                    for (int i = 0; i < m; ++i)
                        R[i] = R1[i];
                if (colequ)
                    for (int i = 0; i < n; ++i)
                        C[i] *= C1[i];
                else
                    for (int i = 0; i < n; ++i)
                        C[i] = C1[i];

                ScalePermstruct->DiagScale = BOTH;
                rowequ = colequ = 1;

            } /* end if Equil */

            /* Now permute global A to prepare for symbfact() */
            for (int j = 0; j < n; ++j)
            {
                for (int i = colptr[j]; i < colptr[j + 1]; ++i)
                {
                    int irow = rowind[i];
                    rowind[i] = perm_r[irow];
                }
            }
            SUPERLU_FREE(R1);
            SUPERLU_FREE(C1);
        }
        else
        { /* job = 2,3,4 */
            for (int j = 0; j < n; ++j)
            {
                for (int i = colptr[j]; i < colptr[j + 1]; ++i)
                {
                    int irow = rowind[i];
                    rowind[i] = perm_r[irow];
                } /* end for i ... */
            }	  /* end for j ... */
        }		  /* end else job ... */
    }
}

void perform_row_permutation(
    superlu_dist_options_t *options,
    fact_t Fact,
    int m, int n,
    gridinfo_t *grid,
    int *perm_r,
    SuperMatrix *A,
    SuperMatrix *GA, 
    SuperLUStat_t *stat,
    int job,
    int Equil,
    int rowequ,
    int colequ)
{
    /* Get NC format data from SuperMatrix GA */
    NCformat* GAstore = (NCformat *)GA->Store;
    int_t* colptr = GAstore->colptr;
    int_t* rowind = GAstore->rowind;
    int nnz = GAstore->nnz;
    double* a_GA = (double *)GAstore->nzval;

    int iam = grid->iam;
    /* ------------------------------------------------------------
			   Find the row permutation for A.
    ------------------------------------------------------------ */
    double t;

    if (options->RowPerm != NO)
    {
        t = SuperLU_timer_();

        if (Fact != SamePattern_SameRowPerm)
        {
            if (options->RowPerm == MY_PERMR)
            {
                permute_rows_with_user_perm(colptr, rowind, perm_r, n);
            }
            else if (options->RowPerm == LargeDiag_MC64)
            {
                // following incorrect
                // perform_LargeDiag_MC64(options, Fact, m, n, grid, perm_r, A, stat, job, Equil, rowequ, colequ);
                // following correct
    //             superlu_dist_options_t* options, 
    // fact_t Fact, 
    // dScalePermstruct_t *ScalePermstruct,
    // dLUstruct_t *LUstruct,
    // int m, int n, 
    // gridinfo_t* grid, 
    // int_t* perm_r,
    // SuperMatrix* A, 
    // SuperMatrix* GA,
    // SuperLUStat_t* stat, 
    // int job, 
    // int Equil, 
    // int rowequ, 
    // int colequ) 
                perform_LargeDiag_MC64(options, Fact, NULL, NULL, m, n, grid, perm_r, A, GA, stat, job, Equil, rowequ, colequ);
            }
            else // LargeDiag_HWPM
            {
#ifdef HAVE_COMBBLAS
                d_c2cpp_GetHWPM(A, grid, ScalePermstruct);
#else
                if (iam == 0)
                {
                    printf("CombBLAS is not available\n");
                    fflush(stdout);
                }
#endif
            }

            t = SuperLU_timer_() - t;
            stat->utime[ROWPERM] = t;
#if (PRNTlevel >= 1)
            if (!iam)
            {
                printf(".. LDPERM job " IFMT "\t time: %.2f\n", job, t);
                fflush(stdout);
            }
#endif
        }
    }
    else // options->RowPerm == NOROWPERM / NATURAL
    {
        for (int i = 0; i < m; ++i)
            perm_r[i] = i;
    }
}


void permute_rows_with_user_perm(int* colptr, int* rowind, int_t* perm_r, int n) {
    // int i, irow;
    // Permute the global matrix GA for symbfact()
    for (int i = 0; i < colptr[n]; ++i)
    {
        int irow = rowind[i];
        rowind[i] = perm_r[irow];
    }
}


#ifdef REFACTOR_SYMBOLIC 
/**
 * @brief Determines the column permutation vector based on the chosen method.
 *
 * @param[in] options      Pointer to the options structure.
 * @param[in] A            Pointer to the input matrix.
 * @param[in] grid         Pointer to the process grid.
 * @param[in] parSymbFact  Flag indicating whether parallel symbolic factorization is used.
 * @param[out] perm_c      Column permutation vector.
 * @return Error code (0 if successful).
 */
int DetermineColumnPermutation(const superlu_dist_options_t *options,
                               const SuperMatrix *A,
                               const gridinfo_t *grid,
                               const int parSymbFact,
                               int_t *perm_c);

/**
 * @brief Computes the elimination tree based on the chosen column permutation method.
 *
 * @param[in] options  Pointer to the options structure.
 * @param[in] A        Pointer to the input matrix.
 * @param[in] perm_c   Column permutation vector.
 * @param[out] etree   Elimination tree.
 * @return Error code (0 if successful).
 */
int ComputeEliminationTree(const superlu_dist_options_t *options,
                           const SuperMatrix *A,
                           const int_t *perm_c,
                           int_t *etree);

/**
 * @brief Performs a symbolic factorization on the permuted matrix and sets up the nonzero data structures for L & U.
 *
 * @param[in] options        Pointer to the options structure.
 * @param[in] A              Pointer to the input matrix.
 * @param[in] perm_c         Column permutation vector.
 * @param[in] etree          Elimination tree.
 * @param[out] Glu_persist   Pointer to the global LU data structures.
 * @param[out] Glu_freeable  Pointer to the LU data structures that can be deallocated.
 * @return Error code (0 if successful).
 */
int PerformSymbolicFactorization(const superlu_dist_options_t *options,
                                 const SuperMatrix *A,
                                 const int_t *perm_c,
                                 const int_t *etree,
                                 Glu_persist_t *Glu_persist,
                                 Glu_freeable_t *Glu_freeable);

/**
 * @brief Distributes the permuted matrix into L and U storage.
 *
 * @param[in] options           Pointer to the options structure.
 * @param[in] n                 Order of the input matrix.
 * @param[in] A                 Pointer to the input matrix.
 * @param[in] ScalePermstruct   Pointer to the scaling and permutation structures.
 * @param[in] Glu_freeable      Pointer to the LU data structures that can be deallocated.
 * @param[out] LUstruct         Pointer to the LU data structures.
 * @param[in] grid              Pointer to the process grid.
 * @return Memory usage in bytes (0 if successful).
 */
int DistributePermutedMatrix(const superlu_dist_options_t *options,
                             const int_t n,
                             const SuperMatrix *A,
                             const dScalePermstruct_t *ScalePermstruct,
                             const Glu_freeable_t *Glu_freeable,
                             LUstruct_t *LUstruct,
                             const gridinfo_t *grid);

/**
 * @brief Deallocates the storage used in symbolic factorization.
 *
 * @param[in] Glu_freeable  Pointer to the LU data structures that can be deallocated.
 * @return Error code (0 if successful).
 */
int DeallocateSymbolicFactorizationStorage(const Glu_freeable_t *Glu_freeable);
#endif // REFACTOR_SYMBOLIC


#ifdef REFACTOR_DistributePermutedMatrix


#endif // REFACTOR_DistributePermutedMatrix