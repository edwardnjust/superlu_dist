#!/bin/bash
#
#modules:
module load PrgEnv-nvidia 
module load cudatoolkit
module load cray-libsci
module load cmake

#MPI settings:
export MPICH_GPU_SUPPORT_ENABLED=0
export CRAY_ACCEL_TARGET=nvidia80
echo MPICH_GPU_SUPPORT_ENABLED=$MPICH_GPU_SUPPORT_ENABLED
export LD_LIBRARY_PATH=${CRAY_LD_LIBRARY_PATH}:$LD_LIBRARY_PATH
#SUPERLU settings:








# export SUPERLU_LBS=ND  # this is causing crash
export MAX_BUFFER_SIZE=50000000
export SUPERLU_NUM_GPU_STREAMS=1
export SUPERLU_BIND_MPI_GPU=1
export SUPERLU_ACC_OFFLOAD=0 # this can be 0 to do CPU tests on GPU nodes
# export GPU3DVERSION=1
export NEW3DSOLVE=1    # Note: SUPERLU_ACC_OFFLOAD=1 and GPU3DVERSION=1 still do CPU factorization after https://github.com/xiaoyeli/superlu_dist/commit/035106d8949bc3abf86866aea1331b2948faa1db#diff-44fa50297abaedcfaed64f93712850a8fce55e8e57065d96d0ba28d8680da11eR223
export SUPERLU_ACC_SOLVE=1
export NEW3DSOLVETREECOMM=1

##NVSHMEM settings:
NVSHMEM_HOME=/global/cfs/cdirs/m2957/liuyangz/my_software/nvshmem_perlmutter/nvshmem_src_2.8.0-3/build/
export NVSHMEM_USE_GDRCOPY=1
export NVSHMEM_MPI_SUPPORT=1
export MPI_HOME=${MPICH_DIR}
export NVSHMEM_LIBFABRIC_SUPPORT=1
export LIBFABRIC_HOME=/opt/cray/libfabric/1.15.2.0
export LD_LIBRARY_PATH=$NVSHMEM_HOME/lib:$LD_LIBRARY_PATH
export NVSHMEM_DISABLE_CUDA_VMM=1
export FI_CXI_OPTIMIZED_MRS=false
export NVSHMEM_BOOTSTRAP_TWO_STAGE=1
export NVSHMEM_BOOTSTRAP=MPI

#export NVSHMEM_DEBUG=TRACE
#export NVSHMEM_DEBUG_SUBSYS=ALL
#export NVSHMEM_DEBUG_FILE=nvdebug_success

if [[ $NERSC_HOST == edison ]]; then
  CORES_PER_NODE=24
  THREADS_PER_NODE=48
elif [[ $NERSC_HOST == cori ]]; then
  CORES_PER_NODE=32
  THREADS_PER_NODE=64
  # This does not take hyperthreading into account
elif [[ $NERSC_HOST == perlmutter ]]; then
  CORES_PER_NODE=64
  THREADS_PER_NODE=128
  GPUS_PER_NODE=4
else
  # Host unknown; exiting
  exit $EXIT_HOST
fi
nprows=(2)
npcols=(1)
npz=(2)
NTH=1
# NODE_VAL_TOT=1

for ((i = 0; i < ${#npcols[@]}; i++)); do
NROW=${nprows[i]}
NCOL=${npcols[i]}
NPZ=${npz[i]}

CORE_VAL2D=`expr $NCOL \* $NROW`
NODE_VAL2D=`expr $CORE_VAL2D / $GPUS_PER_NODE`
MOD_VAL=`expr $CORE_VAL2D % $GPUS_PER_NODE`
if [[ $MOD_VAL -ne 0 ]]
then
  NODE_VAL2D=`expr $NODE_VAL2D + 1`
fi

CORE_VAL=`expr $NCOL \* $NROW \* $NPZ`
NODE_VAL=`expr $CORE_VAL / $GPUS_PER_NODE`
MOD_VAL=`expr $CORE_VAL % $GPUS_PER_NODE`
if [[ $MOD_VAL -ne 0 ]]
then
  NODE_VAL=`expr $NODE_VAL + 1`
fi

# NODE_VAL=2
# NCORE_VAL_TOT=`expr $NODE_VAL_TOT \* $CORES_PER_NODE / $NTH`
batch=0 # whether to do batched test
NCORE_VAL_TOT=`expr $NROW \* $NCOL \* $NPZ `
NCORE_VAL_TOT2D=`expr $NROW \* $NCOL `

OMP_NUM_THREADS=$NTH
TH_PER_RANK=`expr $NTH \* 2`

export OMP_NUM_THREADS=$NTH
export OMP_PLACES=threads
export OMP_PROC_BIND=spread
export SLURM_CPU_BIND="cores"
export MPICH_MAX_THREAD_SAFETY=multiple

# srun -n 1 ./EXAMPLE/pddrive -r 1 -c 1 ../EXAMPLE/g20.rua

# export NSUP=256
# export NREL=256
# for MAT in big.rua
# for MAT in g20.rua
for MAT in s1_mat_0_253872.bin
# for MAT in s2D9pt2048.rua
# for MAT in s2D9pt1536.rua
# for MAT in s1_mat_0_126936.bin s1_mat_0_253872.bin s1_mat_0_507744.bin
# for MAT in matrix_ACTIVSg70k_AC_00.mtx matrix_ACTIVSg10k_AC_00.mtx
# for MAT in temp_13k.mtx temp_25k.mtx temp_75k.mtx
# for MAT in temp_13k.mtx
do
mkdir -p $MAT
# srun -n $NCORE_VAL_TOT2D -N $NODE_VAL2D -c $TH_PER_RANK --cpu_bind=cores ./EXAMPLE/pddrive -c $NCOL -r $NROW -b $batch $CFS/m2957/liuyangz/my_research/matrix/$MAT | tee ./$MAT/SLU.o_mpi_${NROW}x${NCOL}_${NTH}_1rhs_2d

echo "srun -n $NCORE_VAL_TOT  -c $TH_PER_RANK --cpu_bind=cores ./EXAMPLE/pddrive3d -c $NCOL -r $NROW -d $NPZ -b $batch $CFS/m2957/liuyangz/my_research/matrix/$MAT | tee ./$MAT/SLU.o_mpi_${NROW}x${NCOL}x${NPZ}_${NTH}_1rhs_3d"
srun -n $NCORE_VAL_TOT  -c $TH_PER_RANK --cpu_bind=cores ./EXAMPLE/pddrive3d -c $NCOL -r $NROW -d $NPZ -b $batch $CFS/m2957/liuyangz/my_research/matrix/$MAT | tee ./$MAT/SLU.o_mpi_${NROW}x${NCOL}x${NPZ}_${NTH}_1rhs_3d


done
done

