

!> @file
! Copyright (c) 2003, The Regents of the University of California, through
! Lawrence Berkeley National Laboratory (subject to receipt of any required 
! approvals from U.S. Dept. of Energy) 
! 
! All rights reserved. 
! 
! The source code is distributed under BSD license, see the file License.txt
! at the top-level directory.
! 
!> @file
!! \brief The driver program to solve a linear system with default options.
!!
!! <pre>
!! -- Distributed SuperLU routine (version 7.0) --
!! Lawrence Berkeley National Lab, Univ. of California Berkeley.
!! January 2, 2021
!! </pre>
!
      program f_pddrive3d
! 
! Purpose
! =======
!
! The driver program F_PDDRIVE3D.
!
! This example illustrates how to use F_PDGSSVX3D with the full
! (default) options to solve a linear system.
! 
! Seven basic steps are required:
!   1. Create C structures used in SuperLU_DIST
!   2. Initialize the MPI environment and the SuperLU process grid
!   3. Set up the input matrix and the right-hand side
!   4. Set the options argument
!   5. Call f_pdgssvx3d
!   6. Release the process grid and terminate the MPI environment
!   7. Release all structures
!
! The program may be run by typing
!    mpiexec -np 8 f_pddrive3d 
!
      use superlu_mod
!      implicit none
      include 'mpif.h'
      integer maxn, maxnz, maxnrhs
      parameter ( maxn = 10000, maxnz = 100000, maxnrhs = 10 )
      integer rowind(maxnz), colptr(maxn)
      real*8  values(maxnz), b(maxn), berr(maxnrhs), xtrue(maxn)
      integer n, m, nnz, nprow, npcol, npdep, init
      integer*4 iam, info, i, ierr, ldb, nrhs
      character*80 fname

      integer(superlu_ptr) :: grid         ! 3D process grid
      integer(superlu_ptr) :: options
      integer(superlu_ptr) :: ScalePermstruct
      integer(superlu_ptr) :: LUstruct
      integer(superlu_ptr) :: SOLVEstruct
      integer(superlu_ptr) :: A            ! A is on all 3D processes
      integer(superlu_ptr) :: stat

! Initialize MPI environment 
      call mpi_init(ierr)

! Check malloc
!      call f_check_malloc(iam)

! Create Fortran handles for the C structures used in SuperLU_DIST
      call f_create_gridinfo3d_handle(grid)
      call f_create_options_handle(options)
      call f_create_ScalePerm_handle(ScalePermstruct)
      call f_create_LUstruct_handle(LUstruct)
      call f_create_SOLVEstruct_handle(SOLVEstruct)
      call f_create_SuperMatrix_handle(A)
      call f_create_SuperLUStat_handle(stat)

! Initialize the SuperLU_DIST process grid
      nprow = 2
      npcol = 2
      npdep = 2
      call f_superlu_gridinit3d(MPI_COMM_WORLD, nprow, npcol, npdep, grid)

! Bail out if I do not belong in the grid. 
      call get_GridInfo(grid, iam=iam, npdep=npdep)
      if ( iam >= (nprow * npcol * npdep) ) then 
         go to 100
      endif
      if ( iam == 0 ) then 
         write(*,*) ' Process grid: ', nprow, ' X', npcol, ' X', npdep
      endif

! Read and distribute the matrix to the process gird
      nrhs = 1
      fname = '../EXAMPLE/g20.rua'//char(0)  !! make the string null-ended
      call  f_dcreate_matrix_x_b_3d(fname, A, m, n, nnz, &
      	                            nrhs, b, ldb, xtrue, ldx, grid)

      if ( iam == 0 ) then 
         write(*,*) ' Matrix A was set up: m ', m, ' nnz ', nnz
      endif

! Set the default input options
      call f_set_default_options(options)

! Change one or more options
!      call set_superlu_options(options,Fact=FACTORED)
!      call set_superlu_options(options,ParSymbFact=YES)

! Initialize ScalePermstruct and LUstruct
      call get_SuperMatrix(A, nrow=m, ncol=n)
      call f_ScalePermstructInit(m, n, ScalePermstruct)
      call f_LUstructInit(m, n, LUstruct)

! Initialize the statistics variables
      call f_PStatInit(stat)

! Call the linear equation solver
      call f_pdgssvx3d(options, A, ScalePermstruct, b, ldb, nrhs, &
                     grid, LUstruct, SOLVEstruct, berr, stat, info)

      if (info == 0) then
         if ( iam == 0 ) then
            write (*,*) 'Backward error: ', (berr(i), i = 1, nrhs)
         endif
      else
         write(*,*) 'INFO from f_pdgssvx = ', info
      endif

! Deallocate the storage allocated by SuperLU_DIST
      call f_PStatFree(stat)
      call f_Destroy_CompRowLoc_Mat_dist(A)
      call f_ScalePermstructFree(ScalePermstruct)
      call f_Destroy_LU_SOLVE_struct_3d(options, n, grid, LUstruct, SOLVEstruct)
!      call f_LUstructFree(LUstruct)
!      call get_superlu_options(options, SolveInitialized=init)
!      if (init == YES) then
!         call f_dSolveFinalize(options, SOLVEstruct)
!      endif

! Release the SuperLU process grid
100   call f_superlu_gridexit(grid)

! Deallocate the C structures pointed to by the Fortran handles
      call f_destroy_gridinfo_handle(grid)
      call f_destroy_options_handle(options)
      call f_destroy_ScalePerm_handle(ScalePermstruct)
      call f_destroy_LUstruct_handle(LUstruct)
      call f_destroy_SOLVEstruct_handle(SOLVEstruct)
      call f_destroy_SuperMatrix_handle(A)
      call f_destroy_SuperLUStat_handle(stat)

! Check malloc
!      call f_check_malloc(iam)


! Terminate the MPI execution environment
      call mpi_finalize(ierr)

      stop
      end
