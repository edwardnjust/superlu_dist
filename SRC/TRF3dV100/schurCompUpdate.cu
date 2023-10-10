#if 1//def HAVE_CUDA
#include <thrust/for_each.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/system/cuda/execution_policy.h>
#include <thrust/logical.h>
#include <thrust/extrema.h>
#include <thrust/transform_reduce.h>
#include <thrust/functional.h>
#include "superlu_ddefs.h"
#include "lupanels_GPU.cuh"
#include "lupanels.hpp"

cudaError_t checkCudaLocal(cudaError_t result)
{
    // #if defined(DEBUG) || defined(_DEBUG)
    // printf("Checking cuda\n");
    if (result != cudaSuccess)
    {
        fprintf(stderr, "CUDA Runtime Error: %s\n", cudaGetErrorString(result));
        assert(result == cudaSuccess);
    }
    // #endif
    return result;
}

template <class T>
struct UnaryOffsetPtrAssign
{
	T *base_mem, **ptrs;
	size_t* offsets;
	
    UnaryOffsetPtrAssign(T *base_mem, size_t* offsets, T **ptrs)
	{
		this->base_mem = base_mem;
		this->offsets = offsets;
		this->ptrs = ptrs;
	}
	
    inline __host__ __device__ void operator()(const size_t &index) const
    {
        ptrs[index] = base_mem + offsets[index];
    }
};

template<class T>
void generateOffsetPointersT(T *base_mem, long int *offsets, T **ptrs, size_t num_arrays)
{
    UnaryOffsetPtrAssign<T> offset_ptr_functor(base_mem, offsets, ptrs);

    thrust::for_each(
        thrust::system::cuda::par, thrust::counting_iterator<long int>(0),
        thrust::counting_iterator<long int>(num_arrays), offset_ptr_functor
    );
}

void generateOffsetPointers(double *base_mem, long int *offsets, double **ptrs, size_t num_arrays)
{
	generateOffsetPointersT<double>(base_mem, offsets, ptrs, num_arrays);
}

void generateOffsetPointers(int *base_mem, long int *offsets, int **ptrs, size_t num_arrays)
{
	generateOffsetPointersT<int>(base_mem, offsets, ptrs, num_arrays);
}

__global__ void indirectCopy(double *dest, double *src, int_t *idx, int n)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n)
        dest[idx[i]] = src[i];
}

/**
 * @file schurCompUpdate.cu
 * @brief This function copies the packed buffers to GPU and performs the sparse
   initialization on GPU call indirectCopy, this is the kernel
 * @param gpuValBasePtr is the base pointer of the GPU matrix
 * @param valBufferPacked is the packed buffer of the matrix
 * @param valIdx is the index of the packed buffer
 */
void copyToGPU(double *gpuValBasePtr, std::vector<double> &valBufferPacked,
               std::vector<int_t> &valIdx)
{
    int nnzCount = valBufferPacked.size();
    // calculate the size of the packed buffers
    int_t gpuLvalSizePacked = nnzCount * sizeof(double);
    int_t gpuLidxSizePacked = nnzCount * sizeof(int_t);
    // allocate the memory for the packed buffers on GPU
    double *dlvalPacked;
    int_t *dlidxPacked;
    gpuErrchk(cudaMalloc(&dlvalPacked, gpuLvalSizePacked));
    gpuErrchk(cudaMalloc(&dlidxPacked, gpuLidxSizePacked));
    // copy the packed buffers from CPU to GPU
    gpuErrchk(cudaMemcpy(dlvalPacked, valBufferPacked.data(), gpuLvalSizePacked, cudaMemcpyHostToDevice));
    gpuErrchk(cudaMemcpy(dlidxPacked, valIdx.data(), gpuLidxSizePacked, cudaMemcpyHostToDevice));
    // perform the sparse initialization on GPU call indirectCopy
    const int ThreadblockSize = 256;
    int nThreadBlocks = (nnzCount + ThreadblockSize - 1) / ThreadblockSize;
    indirectCopy<<<nThreadBlocks, ThreadblockSize>>>(
        gpuValBasePtr, dlvalPacked, dlidxPacked, nnzCount);
    // wait for it to finish and free dlvalPacked and dlidxPacked
    gpuErrchk(cudaDeviceSynchronize());
    gpuErrchk(cudaFree(dlvalPacked));
    gpuErrchk(cudaFree(dlidxPacked));
}

// copy the panel to GPU
void copyToGPU_Sparse(double *gpuValBasePtr, double *valBuffer, int_t gpuLvalSize)
{
    // sparse Initialization for GPU, this is the experimental code
    // find non-zero elements in the panel, their location and values  and copy to GPU
    int numDoubles = gpuLvalSize / sizeof(double);
    std::vector<double> valBufferPacked;
    std::vector<int_t> valIdx;
    for (int_t i = 0; i < numDoubles; i++)
    {
        if (valBuffer[i] != 0)
        {
            valBufferPacked.push_back(valBuffer[i]);
            valIdx.push_back(i);
        }
    }
    printf("%d non-zero elements in the panel, wrt original=%d\n", valBufferPacked.size(), numDoubles);
    // get the size of the packed buffers and allocate memory on GPU
    copyToGPU(gpuValBasePtr, valBufferPacked, valIdx);
}

//#define NDEBUG
__device__
    int_t
    lpanelGPU_t::find(int_t k)
{
    int threadId = threadIdx.x;
    __shared__ int idx;
    __shared__ int found;
    if (!threadId)
    {
        idx = -1;
        found = 0;
    }

    int nThreads = blockDim.x;
    int blocksPerThreads = CEILING(nblocks(), nThreads);
    __syncthreads();
    for (int blk = blocksPerThreads * threadIdx.x;
         blk < blocksPerThreads * (threadIdx.x + 1);
         blk++)
    {
        // if(found) break;

        if (blk < nblocks())
        {
            if (k == gid(blk))
            {
                idx = blk;
                found = 1;
            }
        }
    }
    __syncthreads();
    return idx;
}

__device__
    int_t
    upanelGPU_t::find(int_t k)
{
    int threadId = threadIdx.x;
    __shared__ int idx;
    __shared__ int found;
    if (!threadId)
    {
        idx = -1;
        found = 0;
    }
    __syncthreads();

    int nThreads = blockDim.x;
    int blocksPerThreads = CEILING(nblocks(), nThreads);

    for (int blk = blocksPerThreads * threadIdx.x;
         blk < blocksPerThreads * (threadIdx.x + 1);
         blk++)
    {
        // if(found) break;

        if (blk < nblocks())
        {
            if (k == gid(blk))
            {
                idx = blk;
                found = 1;
            }
        }
    }
    __syncthreads();
    return idx;
}

__device__ int computeIndirectMapGPU(int *rcS2D, int_t srcLen, int_t *srcVec,
                                     int_t dstLen, int_t *dstVec,
                                     int *dstIdx)
{
    int threadId = threadIdx.x;
    if (dstVec == NULL) /*uncompressed dimension*/
    {
        if (threadId < srcLen)
            rcS2D[threadId] = srcVec[threadId];
        __syncthreads();
        return 0;
    }

    if (threadId < dstLen)
        dstIdx[dstVec[threadId]] = threadId;
    __syncthreads();

    if (threadId < srcLen)
        rcS2D[threadId] = dstIdx[srcVec[threadId]];
    __syncthreads();

    return 0;
}

__device__ void scatterGPU_dev(
    int iSt, int jSt,
    double *gemmBuff, int LDgemmBuff,
    lpanelGPU_t& lpanel, upanelGPU_t& upanel,
    LUstructGPU_t *dA
)
{
    // calculate gi,gj
    int ii = iSt + blockIdx.x;
    int jj = jSt + blockIdx.y;
    int threadId = threadIdx.x;

    int gi = lpanel.gid(ii);
    int gj = upanel.gid(jj);
#ifndef NDEBUG
    // if (!threadId)
    //     printf("Scattering to (%d, %d) \n", gi, gj);
#endif
    double *Dst;
    int_t lddst;
    int_t dstRowLen, dstColLen;
    int_t *dstRowList;
    int_t *dstColList;
    int li, lj;
    if (gj > gi) // its in upanel
    {
        li = dA->g2lRow(gi);
        lj = dA->uPanelVec[li].find(gj);
        Dst = dA->uPanelVec[li].blkPtr(lj);
        lddst = dA->supersize(gi);
        dstRowLen = dA->supersize(gi);
        dstRowList = NULL;
        dstColLen = dA->uPanelVec[li].nbcol(lj);
        dstColList = dA->uPanelVec[li].colList(lj);
    }
    else
    {
        lj = dA->g2lCol(gj);
        li = dA->lPanelVec[lj].find(gi);
        Dst = dA->lPanelVec[lj].blkPtr(li);
        lddst = dA->lPanelVec[lj].LDA();
        dstRowLen = dA->lPanelVec[lj].nbrow(li);
        dstRowList = dA->lPanelVec[lj].rowList(li);
        // if(!threadId )
        // printf("Scattering to (%d, %d) by %d li=%d\n",gi, gj,threadId,li);
        dstColLen = dA->supersize(gj);
        dstColList = NULL;
    }

    // compute source row to dest row mapping
    int maxSuperSize = dA->maxSuperSize;
    extern __shared__ int baseSharedPtr[];
    int *rowS2D = baseSharedPtr;
    int *colS2D = &rowS2D[maxSuperSize];
    int *dstIdx = &colS2D[maxSuperSize];

    int nrows = lpanel.nbrow(ii);
    int ncols = upanel.nbcol(jj);
    // lpanel.rowList(ii), upanel.colList(jj)

    computeIndirectMapGPU(rowS2D, nrows, lpanel.rowList(ii),
                          dstRowLen, dstRowList, dstIdx);

    // compute source col to dest col mapping
    computeIndirectMapGPU(colS2D, ncols, upanel.colList(jj),
                          dstColLen, dstColList, dstIdx);

    int nThreads = blockDim.x;
    int colsPerThreadBlock = nThreads / nrows;

    int rowOff = lpanel.stRow(ii) - lpanel.stRow(iSt);
    int colOff = upanel.stCol(jj) - upanel.stCol(jSt);
    double *Src = &gemmBuff[rowOff + colOff * LDgemmBuff];
    int ldsrc = LDgemmBuff;
    // TODO: this seems inefficient
    if (threadId < nrows * colsPerThreadBlock)
    {
        /* 1D threads are logically arranged in 2D shape. */
        int i = threadId % nrows;
        int j = threadId / nrows;

#pragma unroll 4
        while (j < ncols)
        {

#define ATOMIC_SCATTER
// Atomic Scatter is need if I want to perform multiple Schur Complement
//  update concurrently
#ifdef ATOMIC_SCATTER
            atomicAdd(&Dst[rowS2D[i] + lddst * colS2D[j]], -Src[i + ldsrc * j]);
#else
            Dst[rowS2D[i] + lddst * colS2D[j]] -= Src[i + ldsrc * j];
#endif
            j += colsPerThreadBlock;
        }
    }

    __syncthreads();
}

__global__ void scatterGPU(
    int iSt, int jSt,
    double *gemmBuff, int LDgemmBuff,
    lpanelGPU_t lpanel, upanelGPU_t upanel,
    LUstructGPU_t *dA)
{
    scatterGPU_dev(iSt, jSt, gemmBuff, LDgemmBuff, lpanel, upanel, dA);
}

__global__ void scatterGPU_batch(
    int* iSt_batch, int *iEnd_batch, int *jSt_batch, int *jEnd_batch, 
    double **gemmBuff_ptrs, int *LDgemmBuff_batch, lpanelGPU_t *lpanels, 
    upanelGPU_t *upanels, LUstructGPU_t *dA
)
{
    int batch_index = blockIdx.z;
    int iSt = iSt_batch[batch_index], iEnd = iEnd_batch[batch_index];
    int jSt = jSt_batch[batch_index], jEnd = jEnd_batch[batch_index];
    
    int ii = iSt + blockIdx.x;
    int jj = jSt + blockIdx.y;
    if(ii >= iEnd || jj >= jEnd)
        return;
    
    double* gemmBuff = gemmBuff_ptrs[batch_index];
    if(gemmBuff == NULL)
        return;

    int LDgemmBuff = LDgemmBuff_batch[batch_index];
    lpanelGPU_t& lpanel = lpanels[batch_index];
    upanelGPU_t& upanel = upanels[batch_index];
    scatterGPU_dev(iSt, jSt, gemmBuff, LDgemmBuff, lpanel, upanel, dA);
}

void scatterGPU_driver(
    int iSt, int iEnd, int jSt, int jEnd, double *gemmBuff, int LDgemmBuff,
    int maxSuperSize, int ldt, lpanelGPU_t lpanel, upanelGPU_t upanel, 
    LUstructGPU_t *dA, cudaStream_t cuStream
)
{
    dim3 dimBlock(ldt); // 1d thread
    dim3 dimGrid(iEnd - iSt, jEnd - jSt);
    size_t sharedMemorySize = 3 * maxSuperSize * sizeof(int_t);

    scatterGPU<<<dimGrid, dimBlock, sharedMemorySize, cuStream>>>(
        iSt, jSt, gemmBuff, LDgemmBuff, lpanel, upanel, dA
    );

    gpuErrchk(cudaGetLastError());
}

void scatterGPU_batchDriver(
    int* iSt_batch, int *iEnd_batch, int *jSt_batch, int *jEnd_batch, 
    int max_ilen, int max_jlen, double **gemmBuff_ptrs, int *LDgemmBuff_batch, 
    int maxSuperSize, int ldt, lpanelGPU_t *lpanels, upanelGPU_t *upanels, 
    LUstructGPU_t *dA, int batchCount, cudaStream_t cuStream
)
{
    const int op_increment = 65535;
    
    for(int op_start = 0; op_start < batchCount; op_start += op_increment)
	{
		int batch_size = std::min(op_increment, batchCount - op_start);
    
        dim3 dimBlock(ldt); // 1d thread
        dim3 dimGrid(max_ilen, max_jlen, batch_size);
        size_t sharedMemorySize = 3 * maxSuperSize * sizeof(int_t);

        scatterGPU_batch<<<dimGrid, dimBlock, sharedMemorySize, cuStream>>>(
            iSt_batch + op_start, iEnd_batch + op_start, jSt_batch + op_start, 
            jEnd_batch + op_start, gemmBuff_ptrs + op_start, LDgemmBuff_batch + op_start, 
            lpanels + op_start, upanels + op_start, dA 
        );
    }
}

int_t LUstruct_v100::dSchurComplementUpdateGPU(
    int streamId,
    int_t k, // the k-th panel or supernode
    lpanel_t &lpanel, upanel_t &upanel)
{

    if (lpanel.isEmpty() || upanel.isEmpty())
        return 0;

    int_t st_lb = 0;
    if (myrow == krow(k))
        st_lb = 1;

    int_t nlb = lpanel.nblocks();
    int_t nub = upanel.nblocks();

    int iSt = st_lb;
    int iEnd = iSt;

    int nrows = lpanel.stRow(nlb) - lpanel.stRow(st_lb);
    int ncols = upanel.nzcols();

    int maxGemmRows = nrows;
    int maxGemmCols = ncols;
    // entire gemm doesn't fit in gemm buffer
    if (nrows * ncols > A_gpu.gemmBufferSize)
    {
        int maxGemmOpSize = (int)sqrt(A_gpu.gemmBufferSize);
        int numberofRowChunks = (nrows + maxGemmOpSize - 1) / maxGemmOpSize;
        maxGemmRows = nrows / numberofRowChunks;
        maxGemmCols = A_gpu.gemmBufferSize / maxGemmRows;
        /* printf("buffer exceeded! k = %d, st_lb = %d, nlb = %d, nrowsXncols %d, maxGemRows %d, maxGemmCols %d\n",
	   k, st_lb, nlb, nrows*ncols, maxGemmRows, maxGemmCols);*/
    }

    while (iEnd < nlb)
    {
        iSt = iEnd;
        iEnd = lpanel.getEndBlock(iSt, maxGemmRows);
        
        assert(iEnd > iSt);
        int jSt = 0;
        int jEnd = 0;
        while (jEnd < nub)
        {
            jSt = jEnd;
            jEnd = upanel.getEndBlock(jSt, maxGemmCols);
            assert(jEnd > jSt);
            cublasHandle_t handle = A_gpu.cuHandles[streamId];
            cudaStream_t cuStream = A_gpu.cuStreams[streamId];
            cublasSetStream(handle, cuStream);
            int gemm_m = lpanel.stRow(iEnd) - lpanel.stRow(iSt);
            int gemm_n = upanel.stCol(jEnd) - upanel.stCol(jSt);
            int gemm_k = supersize(k);
#if 0           
            printf("k = %d, iSt = %d, iEnd = %d, jst = %d, jend = %d\n", k, iSt, iEnd, jSt, jEnd);
            printf("m=%d, n=%d, k=%d\n", gemm_m, gemm_n, gemm_k);
	    fflush(stdout);
#endif	    

            double alpha = 1.0;
            double beta = 0.0;
            cublasDgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N,
                        gemm_m, gemm_n, gemm_k, &alpha,
                        lpanel.blkPtrGPU(iSt), lpanel.LDA(),
                        upanel.blkPtrGPU(jSt), upanel.LDA(), &beta,
                        A_gpu.gpuGemmBuffs[streamId], gemm_m);
            
            scatterGPU_driver(
                iSt, iEnd, jSt, jEnd, A_gpu.gpuGemmBuffs[streamId], gemm_m,
                A_gpu.maxSuperSize, ldt, lpanel.gpuPanel, upanel.gpuPanel, 
                dA_gpu, cuStream
            );
        }
    }
    gpuErrchk(cudaStreamSynchronize(A_gpu.cuStreams[streamId]));
    return 0;
} /* end dSchurComplementUpdateGPU */

int_t LUstruct_v100::lookAheadUpdateGPU(
    int streamId,
    int_t k, int_t laIdx, lpanel_t &lpanel, upanel_t &upanel)
{
    if (lpanel.isEmpty() || upanel.isEmpty())
        return 0;

    int_t st_lb = 0;
    if (myrow == krow(k))
        st_lb = 1;

    int_t nlb = lpanel.nblocks();
    int_t nub = upanel.nblocks();

    int_t laILoc = lpanel.find(laIdx);
    int_t laJLoc = upanel.find(laIdx);

    int iSt = st_lb;
    int jSt = 0;

    /* call look ahead update on Lpanel*/
    if (laJLoc != GLOBAL_BLOCK_NOT_FOUND)
        dSchurCompUpdatePartGPU(
            iSt, nlb, laJLoc, laJLoc + 1,
            k, lpanel, upanel,
            A_gpu.lookAheadLHandle[streamId], A_gpu.lookAheadLStream[streamId],
            A_gpu.lookAheadLGemmBuffer[streamId]);

    /* call look ahead update on Upanel*/
    if (laILoc != GLOBAL_BLOCK_NOT_FOUND)
    {
        dSchurCompUpdatePartGPU(
            laILoc, laILoc + 1, jSt, laJLoc,
            k, lpanel, upanel,
            A_gpu.lookAheadUHandle[streamId], A_gpu.lookAheadUStream[streamId],
            A_gpu.lookAheadUGemmBuffer[streamId]);
        dSchurCompUpdatePartGPU(
            laILoc, laILoc + 1, laJLoc + 1, nub,
            k, lpanel, upanel,
            A_gpu.lookAheadUHandle[streamId], A_gpu.lookAheadUStream[streamId],
            A_gpu.lookAheadUGemmBuffer[streamId]);
    }

    // checkCudaLocal(cudaStreamSynchronize(A_gpu.lookAheadLStream[streamId]));
    // checkCudaLocal(cudaStreamSynchronize(A_gpu.lookAheadUStream[streamId]));

    return 0;
}

int_t LUstruct_v100::SyncLookAheadUpdate(int streamId)
{
    gpuErrchk(cudaStreamSynchronize(A_gpu.lookAheadLStream[streamId]));
    gpuErrchk(cudaStreamSynchronize(A_gpu.lookAheadUStream[streamId]));

    return 0;
}

int_t LUstruct_v100::dSchurCompUpdateExcludeOneGPU(
    int streamId,
    int_t k, int_t ex, // suypernodes to be excluded
    lpanel_t &lpanel, upanel_t &upanel)
{
    if (lpanel.isEmpty() || upanel.isEmpty())
        return 0;

    int_t st_lb = 0;
    if (myrow == krow(k))
        st_lb = 1;

    int_t nlb = lpanel.nblocks();
    int_t nub = upanel.nblocks();

    int_t exILoc = lpanel.find(ex);
    int_t exJLoc = upanel.find(ex);

    dSchurCompUpLimitedMem(
        streamId,
        st_lb, exILoc, 0, exJLoc,
        k, lpanel, upanel);

    dSchurCompUpLimitedMem(
        streamId,
        st_lb, exILoc, exJLoc + 1, nub,
        k, lpanel, upanel);

    int_t nextStI = exILoc + 1;
    if (exILoc == GLOBAL_BLOCK_NOT_FOUND)
        nextStI = st_lb;
    /*
    for j we don't need to change since, if exJLoc == GLOBAL_BLOCK_NOT_FOUND =-1
    then exJLoc+1 =0 will work out correctly as starting j
    */
    dSchurCompUpLimitedMem(
        streamId,
        nextStI, nlb, 0, exJLoc,
        k, lpanel, upanel);

    dSchurCompUpLimitedMem(
        streamId,
        nextStI, nlb, exJLoc + 1, nub,
        k, lpanel, upanel);

    // checkCudaLocal(cudaStreamSynchronize(A_gpu.cuStreams[streamId]));
    return 0;
}

int_t LUstruct_v100::dSchurCompUpdatePartGPU(
    int_t iSt, int_t iEnd, int_t jSt, int_t jEnd,
    int_t k, lpanel_t &lpanel, upanel_t &upanel,
    cublasHandle_t handle, cudaStream_t cuStream,
    double *gemmBuff)
{
    if (iSt >= iEnd || jSt >= jEnd)
        return 0;

    cublasSetStream(handle, cuStream);
    int gemm_m = lpanel.stRow(iEnd) - lpanel.stRow(iSt);
    int gemm_n = upanel.stCol(jEnd) - upanel.stCol(jSt);
    int gemm_k = supersize(k);
    double alpha = 1.0;
    double beta = 0.0;
#ifndef NDEBUG
    printf("m=%d, n=%d, k=%d\n", gemm_m, gemm_n, gemm_k);
#endif
    cublasDgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N,
                gemm_m, gemm_n, gemm_k, &alpha,
                lpanel.blkPtrGPU(iSt), lpanel.LDA(),
                upanel.blkPtrGPU(jSt), upanel.LDA(), &beta,
                gemmBuff, gemm_m);

    // setting up scatter
    dim3 dimBlock(ldt); // 1d thread
    dim3 dimGrid(iEnd - iSt, jEnd - jSt);
    size_t sharedMemorySize = 3 * A_gpu.maxSuperSize * sizeof(int_t);

    scatterGPU<<<dimGrid, dimBlock, sharedMemorySize, cuStream>>>(
        iSt, jSt,
        gemmBuff, gemm_m,
        lpanel.gpuPanel, upanel.gpuPanel, dA_gpu);

    return 0;
}

int_t LUstruct_v100::dSchurCompUpLimitedMem(
    int streamId,
    int_t lStart, int_t lEnd,
    int_t uStart, int_t uEnd,
    int_t k, lpanel_t &lpanel, upanel_t &upanel)
{

    if (lStart >= lEnd || uStart >= uEnd)
        return 0;
    int iSt = lStart;
    int iEnd = iSt;
    int nrows = lpanel.stRow(lEnd) - lpanel.stRow(lStart);
    int ncols = upanel.stCol(uEnd) - upanel.stCol(uStart);

    int maxGemmRows = nrows;
    int maxGemmCols = ncols;
    // entire gemm doesn't fit in gemm buffer
    if (nrows * ncols > A_gpu.gemmBufferSize)
    {
        int maxGemmOpSize = (int)sqrt(A_gpu.gemmBufferSize);
        int numberofRowChunks = (nrows + maxGemmOpSize - 1) / maxGemmOpSize;
        maxGemmRows = nrows / numberofRowChunks;
        maxGemmCols = A_gpu.gemmBufferSize / maxGemmRows;
    }

    while (iEnd < lEnd)
    {
        iSt = iEnd;
        iEnd = lpanel.getEndBlock(iSt, maxGemmRows);
        if (iEnd > lEnd)
            iEnd = lEnd;

        assert(iEnd > iSt);
        int jSt = uStart;
        int jEnd = uStart;
        while (jEnd < uEnd)
        {
            jSt = jEnd;
            jEnd = upanel.getEndBlock(jSt, maxGemmCols);
            if (jEnd > uEnd)
                jEnd = uEnd;

            cublasHandle_t handle = A_gpu.cuHandles[streamId];
            cudaStream_t cuStream = A_gpu.cuStreams[streamId];
            dSchurCompUpdatePartGPU(iSt, iEnd, jSt, jEnd,
                                    k, lpanel, upanel, handle, cuStream, A_gpu.gpuGemmBuffs[streamId]);
        }
    }

    return 0;
}

int getMPIProcsPerGPU()
{
    if (!(getenv("MPI_PROCESS_PER_GPU")))
    {
        return 1;
    }
    else
    {
        int devCount;
        cudaGetDeviceCount(&devCount);
        int envCount = atoi(getenv("MPI_PROCESS_PER_GPU"));
        envCount = SUPERLU_MAX(envCount, 0);
        return SUPERLU_MIN(envCount, devCount);
    }
}

#define USABLE_GPU_MEM_FRACTION 0.9

size_t getGPUMemPerProcs(MPI_Comm baseCommunicator)
{

    size_t mfree, mtotal;
    // TODO: shared memory communicator should be part of
    //  LU struct
    //  MPI_Comm sharedComm;
    //  MPI_Comm_split_type(baseCommunicator, MPI_COMM_TYPE_SHARED,
    //                      0, MPI_INFO_NULL, &sharedComm);
    //  MPI_Barrier(sharedComm);
    cudaMemGetInfo(&mfree, &mtotal);
    // MPI_Barrier(sharedComm);
    // MPI_Comm_free(&sharedComm);
#if 0
    printf("Total memory %zu & free memory %zu\n", mtotal, mfree);
#endif
    return (size_t)(USABLE_GPU_MEM_FRACTION * (double)mfree) / getMPIProcsPerGPU();
}

int_t LUstruct_v100::setLUstruct_GPU()
{
    int i, stream;
    
#if (DEBUGlevel >= 1)
    int iam = 0;
    CHECK_MALLOC(iam, "Enter setLUstruct_GPU()"); fflush(stdout);
#endif
	
    A_gpu.Pr = Pr;
    A_gpu.Pc = Pc;
    A_gpu.maxSuperSize = ldt;

    /* Sherry: this mapping may be inefficient on Frontier */
    /*Mapping to device*/
    int deviceCount;
    cudaGetDeviceCount(&deviceCount); // How many GPUs
    int device_id = grid3d->iam % deviceCount;
    cudaSetDevice(device_id);

    double tRegion[5];
    size_t useableGPUMem = getGPUMemPerProcs(grid3d->comm);
    /**
     *  Memory is divided into two parts data memory and buffer memory
     *  data memory is used for useful data
     *  bufferMemory is used for buffers
     * */
    size_t memReqData = 0;

    /*Memory for XSUP*/
    memReqData += (nsupers + 1) * sizeof(int_t);

    tRegion[0] = SuperLU_timer_();
    
    size_t totalNzvalSize = 0; /* too big for gemmBufferSize */
    size_t max_gemmCsize = 0;  /* Sherry added 2/20/2023 */
    
    /*Memory for lpapenl and upanel Data*/
    for (i = 0; i < CEILING(nsupers, Pc); ++i)
    {
        if (i * Pc + mycol < nsupers && isNodeInMyGrid[i * Pc + mycol] == 1)
        {
            memReqData += lPanelVec[i].totalSize();
            totalNzvalSize += lPanelVec[i].nzvalSize();
	    //max_gemmCsize = SUPERoLU_MAX(max_gemmCsize, ???);
        }
    }
    for (i = 0; i < CEILING(nsupers, Pr); ++i)
    {
        if (i * Pr + myrow < nsupers && isNodeInMyGrid[i * Pr + myrow] == 1)
        {
            memReqData += uPanelVec[i].totalSize();
            totalNzvalSize += uPanelVec[i].nzvalSize();
        }
    }
    
    memReqData += CEILING(nsupers, Pc) * sizeof(lpanelGPU_t);
    memReqData += CEILING(nsupers, Pr) * sizeof(upanelGPU_t);

    memReqData += sizeof(LUstructGPU_t);
    
    // Per stream data
    // TODO: estimate based on ancestor size
    int_t maxBuffSize = sp_ienv_dist (8, options);
    int maxsup = sp_ienv_dist(3, options); // max. supernode size
    maxBuffSize = SUPERLU_MAX(maxsup * maxsup, maxBuffSize); // Sherry added 7/10/23
    A_gpu.gemmBufferSize = SUPERLU_MIN(maxBuffSize, totalNzvalSize);
    
    size_t dataPerStream = 3 * sizeof(double) * maxLvalCount + 3 * sizeof(double) * maxUvalCount + 2 * sizeof(int_t) * maxLidxCount + 2 * sizeof(int_t) * maxUidxCount + A_gpu.gemmBufferSize * sizeof(double) + ldt * ldt * sizeof(double);
    if (memReqData + 2 * dataPerStream > useableGPUMem)
    {
        printf("Not enough memory on GPU: available = %zu, required for 2 streams =%zu, exiting\n", useableGPUMem, memReqData + 2 * dataPerStream);
        exit(-1);
    }

    tRegion[0] = SuperLU_timer_() - tRegion[0];
#if ( PRNTlevel>=1 )    
    // print the time taken to estimate memory on GPU
    if (grid3d->iam == 0)
    {
        printf("Time taken to estimate memory on GPU: %f\n", tRegion[0]);
	printf("\t.. totalNzvalSize %ld, gemmBufferSize %ld\n",
	       (long) totalNzvalSize, (long) A_gpu.gemmBufferSize);
    }
#endif

    /*Memory for lapenlPanel Data*/
    tRegion[1] = SuperLU_timer_();

    int_t maxNumberOfStream = (useableGPUMem - memReqData) / dataPerStream;

    int numberOfStreams = SUPERLU_MIN(getNumLookAhead(options), maxNumberOfStream);
    numberOfStreams = SUPERLU_MIN(numberOfStreams, MAX_CUDA_STREAMS);
    int rNumberOfStreams;
    MPI_Allreduce(&numberOfStreams, &rNumberOfStreams, 1,
                  MPI_INT, MPI_MIN, grid3d->comm);
    A_gpu.numCudaStreams = rNumberOfStreams;

    if (!grid3d->iam)
        printf("Using %d CUDA LookAhead streams\n", rNumberOfStreams);
    size_t totalMemoryRequired = memReqData + numberOfStreams * dataPerStream;

#if 0 /**** Old code ****/
    upanelGPU_t *uPanelVec_GPU = new upanelGPU_t[CEILING(nsupers, Pr)];
    lpanelGPU_t *lPanelVec_GPU = new lpanelGPU_t[CEILING(nsupers, Pc)];
    void *gpuBasePtr, *gpuCurrentPtr;
    cudaMalloc(&gpuBasePtr, totalMemoryRequired);
    gpuCurrentPtr = gpuBasePtr;

    A_gpu.xsup = (int_t *)gpuCurrentPtr;
    gpuCurrentPtr = (int_t *)gpuCurrentPtr + (nsupers + 1);
    cudaMemcpy(A_gpu.xsup, xsup, (nsupers + 1) * sizeof(int_t), cudaMemcpyHostToDevice);

    for (int i = 0; i < CEILING(nsupers, Pc); ++i)
    {
        if (i * Pc + mycol < nsupers && isNodeInMyGrid[i * Pc + mycol] == 1)
        {
            lPanelVec_GPU[i] = lPanelVec[i].copyToGPU(gpuCurrentPtr);
            gpuCurrentPtr = (char *)gpuCurrentPtr + lPanelVec[i].totalSize();
        }
    }
    A_gpu.lPanelVec = (lpanelGPU_t *)gpuCurrentPtr;
    gpuCurrentPtr = (char *)gpuCurrentPtr + CEILING(nsupers, Pc) * sizeof(lpanelGPU_t);
    cudaMemcpy(A_gpu.lPanelVec, lPanelVec_GPU,
               CEILING(nsupers, Pc) * sizeof(lpanelGPU_t), cudaMemcpyHostToDevice);

    for (int i = 0; i < CEILING(nsupers, Pr); ++i)
    {
        if (i * Pr + myrow < nsupers && isNodeInMyGrid[i * Pr + myrow] == 1)
        {
            uPanelVec_GPU[i] = uPanelVec[i].copyToGPU(gpuCurrentPtr);
            gpuCurrentPtr = (char *)gpuCurrentPtr + uPanelVec[i].totalSize();
        }
    }
    A_gpu.uPanelVec = (upanelGPU_t *)gpuCurrentPtr;
    gpuCurrentPtr = (char *)gpuCurrentPtr + CEILING(nsupers, Pr) * sizeof(upanelGPU_t);
    cudaMemcpy(A_gpu.uPanelVec, uPanelVec_GPU,
               CEILING(nsupers, Pr) * sizeof(upanelGPU_t), cudaMemcpyHostToDevice);

    for (int stream = 0; stream < A_gpu.numCudaStreams; stream++)
    {

        cudaStreamCreate(&A_gpu.cuStreams[stream]);
        cublasCreate(&A_gpu.cuHandles[stream]);
        A_gpu.LvalRecvBufs[stream] = (double *)gpuCurrentPtr;
        gpuCurrentPtr = (double *)gpuCurrentPtr + maxLvalCount;
        A_gpu.UvalRecvBufs[stream] = (double *)gpuCurrentPtr;
        gpuCurrentPtr = (double *)gpuCurrentPtr + maxUvalCount;
        A_gpu.LidxRecvBufs[stream] = (int_t *)gpuCurrentPtr;
        gpuCurrentPtr = (int_t *)gpuCurrentPtr + maxLidxCount;
        A_gpu.UidxRecvBufs[stream] = (int_t *)gpuCurrentPtr;
        gpuCurrentPtr = (int_t *)gpuCurrentPtr + maxUidxCount;

        A_gpu.gpuGemmBuffs[stream] = (double *)gpuCurrentPtr;
        gpuCurrentPtr = (double *)gpuCurrentPtr + A_gpu.gemmBufferSize;
        A_gpu.dFBufs[stream] = (double *)gpuCurrentPtr;
        gpuCurrentPtr = (double *)gpuCurrentPtr + ldt * ldt;

        /*lookAhead buffers and stream*/
        cublasCreate(&A_gpu.lookAheadLHandle[stream]);
        cudaStreamCreate(&A_gpu.lookAheadLStream[stream]);
        A_gpu.lookAheadLGemmBuffer[stream] = (double *)gpuCurrentPtr;
        gpuCurrentPtr = (double *)gpuCurrentPtr + maxLvalCount;
        cublasCreate(&A_gpu.lookAheadUHandle[stream]);
        cudaStreamCreate(&A_gpu.lookAheadUStream[stream]);
        A_gpu.lookAheadUGemmBuffer[stream] = (double *)gpuCurrentPtr;
        gpuCurrentPtr = (double *)gpuCurrentPtr + maxUvalCount;
    }
    // cudaCheckError();
    // allocate
    dA_gpu = (LUstructGPU_t *)gpuCurrentPtr;

    cudaMemcpy(dA_gpu, &A_gpu, sizeof(LUstructGPU_t), cudaMemcpyHostToDevice);
    gpuCurrentPtr = (LUstructGPU_t *)gpuCurrentPtr + 1;

#else /* else of #if 0 ----> this is the current active code - Sherry */
    gpuErrchk(cudaMalloc(&A_gpu.xsup, (nsupers + 1) * sizeof(int_t)));
    gpuErrchk(cudaMemcpy(A_gpu.xsup, xsup, (nsupers + 1) * sizeof(int_t), cudaMemcpyHostToDevice));

    double tLsend, tUsend;
#if 0
    tLsend = SuperLU_timer_();
    upanelGPU_t *uPanelVec_GPU = copyUpanelsToGPU();
    tLsend = SuperLU_timer_() - tLsend;
    tUsend = SuperLU_timer_();
    lpanelGPU_t *lPanelVec_GPU = copyLpanelsToGPU();
    tUsend = SuperLU_timer_() - tUsend;
#else 
    upanelGPU_t *uPanelVec_GPU = new upanelGPU_t[CEILING(nsupers, Pr)];
    lpanelGPU_t *lPanelVec_GPU = new lpanelGPU_t[CEILING(nsupers, Pc)];
    tLsend = SuperLU_timer_();
    for (i = 0; i < CEILING(nsupers, Pc); ++i)
    {
        if (i * Pc + mycol < nsupers && isNodeInMyGrid[i * Pc + mycol] == 1)
            lPanelVec_GPU[i] = lPanelVec[i].copyToGPU();
    }
    tLsend = SuperLU_timer_() - tLsend;
    tUsend = SuperLU_timer_();
    // cudaCheckError();
    for (i = 0; i < CEILING(nsupers, Pr); ++i)
    {
        if (i * Pr + myrow < nsupers && isNodeInMyGrid[i * Pr + myrow] == 1)
            uPanelVec_GPU[i] = uPanelVec[i].copyToGPU();
    }
    tUsend = SuperLU_timer_() - tUsend;
#endif
    tRegion[1] = SuperLU_timer_() - tRegion[1];
    printf("TRegion L,U send: \t %g\n", tRegion[1]);
    printf("Time to send Lpanel=%g  and U panels =%g \n", tLsend, tUsend);
    fflush(stdout);

    gpuErrchk(cudaMalloc(&A_gpu.lPanelVec, CEILING(nsupers, Pc) * sizeof(lpanelGPU_t)));
    gpuErrchk(cudaMemcpy(A_gpu.lPanelVec, lPanelVec_GPU,
               CEILING(nsupers, Pc) * sizeof(lpanelGPU_t), cudaMemcpyHostToDevice));
    gpuErrchk(cudaMalloc(&A_gpu.uPanelVec, CEILING(nsupers, Pr) * sizeof(upanelGPU_t)));
    gpuErrchk(cudaMemcpy(A_gpu.uPanelVec, uPanelVec_GPU,
               CEILING(nsupers, Pr) * sizeof(upanelGPU_t), cudaMemcpyHostToDevice));

    tRegion[2] = SuperLU_timer_();
    int dfactBufSize = 0;
    // TODO: does it work with NULL pointer?
    cusolverDnHandle_t cusolverH = NULL;
    cusolverDnCreate(&cusolverH);
    
    cusolverDnDgetrf_bufferSize(cusolverH, ldt, ldt, NULL, ldt, &dfactBufSize);
    printf("Size of dfactBuf is %d\n", dfactBufSize);
    tRegion[2] = SuperLU_timer_() - tRegion[2];
    printf("TRegion dfactBuf: \t %g\n", tRegion[2]);
    fflush(stdout);
    
    tRegion[3] = SuperLU_timer_();

    double tcuMalloc=SuperLU_timer_();

    /* Sherry: where are these freed ?? */
    for (stream = 0; stream < A_gpu.numCudaStreams; stream++)
    {
        gpuErrchk(cudaMalloc(&A_gpu.LvalRecvBufs[stream], sizeof(double) * maxLvalCount));
        gpuErrchk(cudaMalloc(&A_gpu.UvalRecvBufs[stream], sizeof(double) * maxUvalCount));
        gpuErrchk(cudaMalloc(&A_gpu.LidxRecvBufs[stream], sizeof(int_t) * maxLidxCount));
        gpuErrchk(cudaMalloc(&A_gpu.UidxRecvBufs[stream], sizeof(int_t) * maxUidxCount));
        // allocate the space for diagonal factor on GPU
        gpuErrchk(cudaMalloc(&A_gpu.diagFactWork[stream], sizeof(double) * dfactBufSize));
        gpuErrchk(cudaMalloc(&A_gpu.diagFactInfo[stream], sizeof(int)));

        /*lookAhead buffers and stream*/
        gpuErrchk(cudaMalloc(&A_gpu.lookAheadLGemmBuffer[stream], sizeof(double) * maxLvalCount));

        gpuErrchk(cudaMalloc(&A_gpu.lookAheadUGemmBuffer[stream], sizeof(double) * maxUvalCount));
	// Sherry: replace this by new code 
        //cudaMalloc(&A_gpu.dFBufs[stream], ldt * ldt * sizeof(double));
        //cudaMalloc(&A_gpu.gpuGemmBuffs[stream], A_gpu.gemmBufferSize * sizeof(double));
    }
    
    /* Sherry: dfBufs[] changed to double pointer **, max(batch, numCudaStreams) */
    int mxLeafNode = trf3Dpartition->mxLeafNode, mx_fsize = 0;

    /* Compute gemmCsize[] for batch operations 
       !!!!!!! WARNING: this only works for 1 MPI  !!!!!! */
    if ( options->batchCount > 0 ) {
	trf3Dpartition->gemmCsizes = int32Calloc_dist(mxLeafNode);
	int k, k0, k_st, k_end, offset, Csize;
	
	for (int ilvl = 0; ilvl < maxLvl; ++ilvl) {  /* Loop through the Pz tree levels */
	    int treeId = trf3Dpartition->myTreeIdxs[ilvl];
	    sForest_t* sforest = trf3Dpartition->sForests[treeId];
	    if (sforest){
		int_t *perm_c_supno = sforest->nodeList ;
        mx_fsize = max(mx_fsize, sforest->nNodes);

		int maxTopoLevel = sforest->topoInfo.numLvl;/* number of levels at each outer-tree node */
		for (int topoLvl = 0; topoLvl < maxTopoLevel; ++topoLvl) {
		    k_st = sforest->topoInfo.eTreeTopLims[topoLvl];
		    k_end = sforest->topoInfo.eTreeTopLims[topoLvl + 1];
		
		    for (k0 = k_st; k0 < k_end; ++k0) {
			offset = k0 - k_st;
			k = perm_c_supno[k0];
			Csize = lPanelVec[k].nzrows() * uPanelVec[k].nzcols();
			trf3Dpartition->gemmCsizes[offset] =
			    SUPERLU_MAX(trf3Dpartition->gemmCsizes[offset], Csize);
		    }
		}
	    }
	}
    }
    
    int num_dfbufs;  /* number of diagonal buffers */
    if ( options->batchCount > 0 ) { /* use batch code */
	num_dfbufs = mxLeafNode;
    } else { /* use pipelined code */
	num_dfbufs = MAX_CUDA_STREAMS;
    }
    int num_gemmbufs = num_dfbufs;
    printf(".. setLUstrut_GPU: num_dfbufs %d, num_gemmbufs %d\n", num_dfbufs, num_gemmbufs); fflush(stdout);

    A_gpu.dFBufs = (double **) SUPERLU_MALLOC(num_dfbufs * sizeof(double *));
    A_gpu.gpuGemmBuffs = (double **) SUPERLU_MALLOC(num_gemmbufs * sizeof(double *));
    
    int l, sum_diag_size = 0, sum_gemmC_size = 0;
    
    if ( options->batchCount > 0 ) { /* set up variable-size buffers for batch code */
	for (i = 0; i < num_dfbufs; ++i) {
	    l = trf3Dpartition->diagDims[i];
	    gpuErrchk(cudaMalloc(&(A_gpu.dFBufs[i]), l * l * sizeof(double)));
	    //printf("\t diagDims[%d] %d\n", i, l);
	    gpuErrchk(cudaMalloc(&(A_gpu.gpuGemmBuffs[i]), trf3Dpartition->gemmCsizes[i] * sizeof(double)));
	    sum_diag_size += l * l;
	    sum_gemmC_size += trf3Dpartition->gemmCsizes[i];
	}
    } else { /* uniform-size buffers */
	l = ldt * ldt;
	for (i = 0; i < num_dfbufs; ++i) {
	    gpuErrchk(cudaMalloc(&(A_gpu.dFBufs[i]), l * sizeof(double)));
	    gpuErrchk(cudaMalloc(&(A_gpu.gpuGemmBuffs[i]), A_gpu.gemmBufferSize * sizeof(double)));
	}
    }
    
    // Wajih: Adding allocation for batched LU and SCU marshalled data
    // TODO: these are serialized workspaces, so the allocations can be shared 
    A_gpu.marshall_data.setBatchSize(num_dfbufs);
    A_gpu.sc_marshall_data.setBatchSize(num_dfbufs);

    ///////////////////////////////////////////////////////////////////////////
    // New intermediate code for batched routine 
    ///////////////////////////////////////////////////////////////////////////

    d_localLU.Lrowind_bc_cnt = host_Llu->Lrowind_bc_cnt;
    gpuErrchk( cudaMalloc(&(d_localLU.Lrowind_bc_dat), d_localLU.Lrowind_bc_cnt * sizeof(int_t)) );
    gpuErrchk( cudaMalloc(&(d_localLU.Lrowind_bc_offset), nsupers * sizeof(long int)) );
    gpuErrchk( cudaMalloc(&(d_localLU.Lrowind_bc_ptr), nsupers * sizeof(int_t*)) );

    d_localLU.Lnzval_bc_cnt = host_Llu->Lnzval_bc_cnt;
    gpuErrchk( cudaMalloc(&(d_localLU.Lnzval_bc_dat), d_localLU.Lnzval_bc_cnt * sizeof(double)) );
    gpuErrchk( cudaMalloc(&(d_localLU.Lnzval_bc_offset), nsupers * sizeof(long int)) );
    gpuErrchk( cudaMalloc(&(d_localLU.Lnzval_bc_ptr), nsupers * sizeof(double*)) );

    // Generate the pointers using the offsets 
    generateOffsetPointers(d_localLU.Lrowind_bc_dat, d_localLU.Lrowind_bc_offset, d_localLU.Lrowind_bc_ptr, nsupers);
    generateOffsetPointers(d_localLU.Lnzval_bc_dat, d_localLU.Lnzval_bc_offset, d_localLU.Lnzval_bc_ptr, nsupers);

    // Copy the index and nzval data over to the GPU 
    gpuErrchk( cudaMemcpy(d_localLU.Lrowind_bc_dat, host_Llu->Lrowind_bc_dat, d_localLU.Lrowind_bc_cnt * sizeof(int_t), cudaMemcpyHostToDevice) );
    gpuErrchk( cudaMemcpy(d_localLU.Lnzval_bc_dat, host_Llu->Lnzval_bc_dat, d_localLU.Lnzval_bc_cnt * sizeof(double), cudaMemcpyHostToDevice) );

    // TODO: where should these be freed?
    // Allocate GPU copy for the node list 
    gpuErrchk(cudaMalloc(&(A_gpu.dperm_c_supno), sizeof(int) * mx_fsize));
    // Allocate GPU copy of all the gemm buffer pointers and copy the host array to the GPU 
    gpuErrchk(cudaMalloc(&(A_gpu.dgpuGemmBuffs), sizeof(double*) * num_gemmbufs));
    gpuErrchk(cudaMemcpy(A_gpu.dgpuGemmBuffs, A_gpu.gpuGemmBuffs, sizeof(double*) * num_gemmbufs, cudaMemcpyHostToDevice));

    tcuMalloc = SuperLU_timer_() - tcuMalloc;
#if ( PRNTlevel>=1 )
    printf("Time to allocate GPU memory: %g\n", tcuMalloc);
    printf("\t.. sum_diag_size %d\t sum_gemmC_size %d\n", sum_diag_size, sum_gemmC_size);
    fflush(stdout);
#endif

    double tcuStream=SuperLU_timer_();
    
    for (stream = 0; stream < A_gpu.numCudaStreams; stream++)
    {
        cublasCreate(&A_gpu.cuHandles[stream]);
        cusolverDnCreate(&A_gpu.cuSolveHandles[stream]);
    }
    tcuStream = SuperLU_timer_() - tcuStream;
    printf("Time to create cublas streams: %g\n", tcuStream);

    double tcuStreamCreate=SuperLU_timer_();
    for (stream = 0; stream < A_gpu.numCudaStreams; stream++)
    {
        cudaStreamCreate(&A_gpu.cuStreams[stream]);
        cublasCreate(&A_gpu.cuHandles[stream]);
        /*lookAhead buffers and stream*/
        cublasCreate(&A_gpu.lookAheadLHandle[stream]);
        cudaStreamCreate(&A_gpu.lookAheadLStream[stream]);
        cublasCreate(&A_gpu.lookAheadUHandle[stream]);
        cudaStreamCreate(&A_gpu.lookAheadUStream[stream]);

        // Wajih: Need to create at least one magma queue
#ifdef HAVE_MAGMA
        if(stream == 0)
        {
            magma_queue_create_from_cuda(
                device_id, A_gpu.cuStreams[stream], A_gpu.cuHandles[stream], 
                NULL, &A_gpu.magma_queue
            );
        }
#endif
    }
    tcuStreamCreate = SuperLU_timer_() - tcuStreamCreate;
    printf("Time to create CUDA streams: %g\n", tcuStreamCreate);

    tRegion[3] = SuperLU_timer_() - tRegion[3];
    printf("TRegion stream: \t %g\n", tRegion[3]);
    // allocate
    gpuErrchk(cudaMalloc(&dA_gpu, sizeof(LUstructGPU_t)));
    gpuErrchk(cudaMemcpy(dA_gpu, &A_gpu, sizeof(LUstructGPU_t), cudaMemcpyHostToDevice));

#endif
    
    // cudaCheckError();
    
#if (DEBUGlevel >= 1)
	CHECK_MALLOC(iam, "Exit setLUstruct_GPU()");
#endif
    return 0;
} /* setLUstruct_GPU */

int_t LUstruct_v100::copyLUGPUtoHost()
{

    for (int_t i = 0; i < CEILING(nsupers, Pc); ++i)
        if (i * Pc + mycol < nsupers && isNodeInMyGrid[i * Pc + mycol] == 1)
            lPanelVec[i].copyFromGPU();

    for (int_t i = 0; i < CEILING(nsupers, Pr); ++i)
        if (i * Pr + myrow < nsupers && isNodeInMyGrid[i * Pr + myrow] == 1)
            uPanelVec[i].copyFromGPU();
    return 0;
}

int_t LUstruct_v100::copyLUHosttoGPU()
{
    for (int_t i = 0; i < CEILING(nsupers, Pc); ++i)
        if (i * Pc + mycol < nsupers && isNodeInMyGrid[i * Pc + mycol] == 1)
            lPanelVec[i].copyBackToGPU();

    for (int_t i = 0; i < CEILING(nsupers, Pr); ++i)
        if (i * Pr + myrow < nsupers && isNodeInMyGrid[i * Pr + myrow] == 1)
            uPanelVec[i].copyBackToGPU();
    return 0;
}

int_t LUstruct_v100::checkGPU()
{

    for (int_t i = 0; i < CEILING(nsupers, Pc); ++i)
        lPanelVec[i].checkGPU();

    for (int_t i = 0; i < CEILING(nsupers, Pr); ++i)
        uPanelVec[i].checkGPU();

    std::cout << "Checking LU struct completed succesfully"
              << "\n";
    return 0;
}

// Marshall Functors for batched execution 
struct MarshallLUFunc {
    int k_st, *ld_batch, *dim_batch;
    double** diag_ptrs;
    LUstructGPU_t *A_gpu;

    MarshallLUFunc(int k_st, double** diag_ptrs, int *ld_batch, int *dim_batch, LUstructGPU_t *A_gpu)
    {
        this->k_st = k_st;
        this->ld_batch = ld_batch;
        this->dim_batch = dim_batch;
        this->diag_ptrs = diag_ptrs;
        this->A_gpu = A_gpu;
    }
    
    __device__ void operator()(const unsigned int &i) const
    {   
        int k = A_gpu->dperm_c_supno[k_st + i];
        int* xsup = A_gpu->xsup;
        lpanelGPU_t &lpanel = A_gpu->lPanelVec[A_gpu->g2lCol(k)];

        diag_ptrs[i] = lpanel.blkPtr(0);
        ld_batch[i] = lpanel.LDA();
        dim_batch[i] = SuperSize(k);
    }
};

struct MarshallLUFunc_flat {
    int k_st, *ld_batch, *dim_batch;
    double** diag_ptrs, **Lnzval_bc_ptr;
    int** Lrowind_bc_ptr, *dperm_c_supno, *xsup;

    MarshallLUFunc_flat(
        int k_st, double** diag_ptrs, int *ld_batch, int *dim_batch, double** Lnzval_bc_ptr,
        int** Lrowind_bc_ptr, int *dperm_c_supno, int *xsup
    )
    {
        this->k_st = k_st;
        this->ld_batch = ld_batch;
        this->dim_batch = dim_batch;
        this->diag_ptrs = diag_ptrs;

        this->Lnzval_bc_ptr = Lnzval_bc_ptr;
        this->Lrowind_bc_ptr = Lrowind_bc_ptr;
        this->dperm_c_supno = dperm_c_supno;
        this->xsup = xsup;
    }
    
    __device__ void operator()(const unsigned int &i) const
    {   
        int k = dperm_c_supno[k_st + i];
        int *Lrowind_bc = Lrowind_bc_ptr[k];

        diag_ptrs[i] = Lnzval_bc_ptr[k];
        ld_batch[i] = Lrowind_bc[1];
        dim_batch[i] = SuperSize(k);
    }
};

struct MarshallTRSMUFunc {
    int k_st, *diag_ld_batch, *diag_dim_batch, *panel_ld_batch, *panel_dim_batch;
    double** diag_ptrs, **panel_ptrs;
    LUstructGPU_t *A_gpu;

    MarshallTRSMUFunc(
        int k_st, double** diag_ptrs, int *diag_ld_batch, int *diag_dim_batch, double** panel_ptrs,
        int *panel_ld_batch, int *panel_dim_batch, LUstructGPU_t *A_gpu
    )
    {
        this->k_st = k_st;
        this->diag_ptrs = diag_ptrs;
        this->diag_ld_batch = diag_ld_batch;
        this->diag_dim_batch = diag_dim_batch;
        this->panel_ptrs = panel_ptrs;
        this->panel_ld_batch = panel_ld_batch;
        this->panel_dim_batch = panel_dim_batch;
        this->A_gpu = A_gpu;
    }
    
    __device__ void operator()(const unsigned int &i) const
    {   
        int k = A_gpu->dperm_c_supno[k_st + i];
        int* xsup = A_gpu->xsup;
        int ksupc = SuperSize(k);

        upanelGPU_t &upanel = A_gpu->uPanelVec[A_gpu->g2lRow(k)];
        lpanelGPU_t &lpanel = A_gpu->lPanelVec[A_gpu->g2lCol(k)];

        if(!upanel.isEmpty())
        {
            panel_ptrs[i] = upanel.blkPtr(0);
            panel_ld_batch[i] = upanel.LDA();
            panel_dim_batch[i] = upanel.nzcols();
            diag_ptrs[i] = lpanel.blkPtr(0);
            diag_ld_batch[i] = lpanel.LDA();
            diag_dim_batch[i] = ksupc;
        }
        else
        {
            panel_ptrs[i] = diag_ptrs[i] = NULL;
            panel_ld_batch[i] = diag_ld_batch[i] = 1;
            panel_dim_batch[i] = diag_dim_batch[i] = 0;
        }    
    }
};

struct MarshallTRSMLFunc {
    int k_st, *diag_ld_batch, *diag_dim_batch, *panel_ld_batch, *panel_dim_batch;
    double** diag_ptrs, **panel_ptrs;
    LUstructGPU_t *A_gpu;

    MarshallTRSMLFunc(
        int k_st, double** diag_ptrs, int *diag_ld_batch, int *diag_dim_batch, double** panel_ptrs,
        int *panel_ld_batch, int *panel_dim_batch, LUstructGPU_t *A_gpu
    )
    {
        this->k_st = k_st;
        this->diag_ptrs = diag_ptrs;
        this->diag_ld_batch = diag_ld_batch;
        this->diag_dim_batch = diag_dim_batch;
        this->panel_ptrs = panel_ptrs;
        this->panel_ld_batch = panel_ld_batch;
        this->panel_dim_batch = panel_dim_batch;
        this->A_gpu = A_gpu;
    }
    
    __device__ void operator()(const unsigned int &i) const
    {
        int k = A_gpu->dperm_c_supno[k_st + i];
        int* xsup = A_gpu->xsup;
        int ksupc = SuperSize(k);

        lpanelGPU_t &lpanel = A_gpu->lPanelVec[A_gpu->g2lCol(k)];

        if(!lpanel.isEmpty())
        {
            double *lPanelStPtr = lpanel.blkPtr(0);
            int_t len = lpanel.nzrows();
            if(lpanel.haveDiag())
            {
                lPanelStPtr = lpanel.blkPtr(1);
                len -= lpanel.nbrow(0);
            }
            panel_ptrs[i] = lPanelStPtr;
            panel_ld_batch[i] = lpanel.LDA();
            panel_dim_batch[i] = len;
            diag_ptrs[i] = lpanel.blkPtr(0);
            diag_ld_batch[i] = lpanel.LDA();
            diag_dim_batch[i] = ksupc;
        }
        else
        {
            panel_ptrs[i] = diag_ptrs[i] = NULL;
            panel_ld_batch[i] = diag_ld_batch[i] = 1;
            panel_dim_batch[i] = diag_dim_batch[i] = 0;
        }    
    }
};


struct MarshallTRSMLFunc_flat {
    int k_st, *diag_ld_batch, *diag_dim_batch, *panel_ld_batch, *panel_dim_batch;
    double** diag_ptrs, **panel_ptrs, **Lnzval_bc_ptr;
    int** Lrowind_bc_ptr, *dperm_c_supno, *xsup;

    MarshallTRSMLFunc_flat(
        int k_st, double** diag_ptrs, int *diag_ld_batch, int *diag_dim_batch, double** panel_ptrs,
        int *panel_ld_batch, int *panel_dim_batch, double** Lnzval_bc_ptr, int** Lrowind_bc_ptr, 
        int *dperm_c_supno, int *xsup
    )
    {
        this->k_st = k_st;
        this->diag_ptrs = diag_ptrs;
        this->diag_ld_batch = diag_ld_batch;
        this->diag_dim_batch = diag_dim_batch;
        this->panel_ptrs = panel_ptrs;
        this->panel_ld_batch = panel_ld_batch;
        this->panel_dim_batch = panel_dim_batch;

        this->Lnzval_bc_ptr = Lnzval_bc_ptr;
        this->Lrowind_bc_ptr = Lrowind_bc_ptr;
        this->dperm_c_supno = dperm_c_supno;
        this->xsup = xsup;
    }
    
    __device__ void operator()(const unsigned int &i) const
    {
        int k = dperm_c_supno[k_st + i];
        int ksupc = SuperSize(k);
        int *Lrowind_bc = Lrowind_bc_ptr[k];
        double* Lnzval = Lnzval_bc_ptr[k];

        if(!Lnzval && !Lrowind_bc)
        {
            int diag_block_offset = Lrowind_bc[BC_HEADER + 1];
            int nzrows = Lrowind_bc[1];
            int len = nzrows - diag_block_offset;

            panel_ptrs[i] = Lnzval + diag_block_offset;
            panel_ld_batch[i] = nzrows;
            panel_dim_batch[i] = len;
            diag_ptrs[i] = Lnzval;
            diag_ld_batch[i] = nzrows;
            diag_dim_batch[i] = ksupc;
        }
        else
        {
            panel_ptrs[i] = diag_ptrs[i] = NULL;
            panel_ld_batch[i] = diag_ld_batch[i] = 1;
            panel_dim_batch[i] = diag_dim_batch[i] = 0;
        }    
    }
};

struct MarshallInitSCUFunc {
    int k_st, *ist, *iend, *maxGemmRows, *maxGemmCols;
    lpanelGPU_t* lpanels;
    upanelGPU_t* upanels;
    LUstructGPU_t *A_gpu;

    MarshallInitSCUFunc(
        int k_st, int *ist, int *iend, int *maxGemmRows, int *maxGemmCols, 
        lpanelGPU_t* lpanels, upanelGPU_t* upanels, LUstructGPU_t *A_gpu
    )
    {
        this->k_st = k_st;
        this->ist = ist;
        this->iend = iend;
        this->maxGemmRows = maxGemmRows;
        this->maxGemmCols = maxGemmCols;
        this->lpanels = lpanels;
        this->upanels = upanels;
        this->A_gpu = A_gpu;
    }
    
    __device__ void operator()(const unsigned int &i) const
    {   
        int k = A_gpu->dperm_c_supno[k_st + i];
        size_t gemmBufferSize = A_gpu->gemmBufferSize;
        
        lpanelGPU_t &lpanel = A_gpu->lPanelVec[A_gpu->g2lCol(k)];
        upanelGPU_t &upanel = A_gpu->uPanelVec[A_gpu->g2lCol(k)];
        
        lpanels[i] = lpanel;
        upanels[i] = upanel;

        if(!upanel.isEmpty() && !lpanel.isEmpty())
        {
            int_t st_lb = 1;
            int_t nlb = lpanel.nblocks();
            int_t nub = upanel.nblocks();

            ist[i] = iend[i] = st_lb;
            int nrows = lpanel.stRow(nlb) - lpanel.stRow(st_lb);
            int ncols = upanel.nzcols();

            int max_rows = nrows;
            int max_cols = ncols;
            // entire gemm doesn't fit in gemm buffer
            if (nrows * ncols > gemmBufferSize)
            {
                int maxGemmOpSize = (int)sqrt((double)gemmBufferSize);
                int numberofRowChunks = (nrows + maxGemmOpSize - 1) / maxGemmOpSize;
                max_rows = nrows / numberofRowChunks;
                max_cols = gemmBufferSize / max_rows;
            }

            maxGemmRows[i] = max_rows;
            maxGemmCols[i] = max_cols;
        }
        else
        {
            ist[i] = iend[i] = 0;
            maxGemmRows[i] = maxGemmCols[i] = 0;
        }
    }
};

struct MarshallSCUOuter_Predicate
{
    __host__ __device__ bool operator()(const int &x)
    {
        return x == 1;
    }
};

struct MarshallSCUOuterFunc {
    int k_st, *ist, *iend, *jst, *jend, *maxGemmRows, *done_flags;
    LUstructGPU_t *A_gpu;

    MarshallSCUOuterFunc(int k_st, int *ist, int *iend, int *jst, int *jend, int *maxGemmRows, int* done_flags, LUstructGPU_t *A_gpu)
    {
        this->k_st = k_st;
        this->ist = ist;
        this->iend = iend;
        this->jst = jst;
        this->jend = jend;
        this->maxGemmRows = maxGemmRows;
        this->done_flags = done_flags;
        this->A_gpu = A_gpu;
    }
    
    __device__ void operator()(const unsigned int &i) const
    {
        int k = A_gpu->dperm_c_supno[k_st + i];
        lpanelGPU_t &lpanel = A_gpu->lPanelVec[A_gpu->g2lCol(k)];
        upanelGPU_t &upanel = A_gpu->uPanelVec[A_gpu->g2lCol(k)];
        int& iEnd = iend[i];

        // Not done if even one operation still has work to do 
        if(!lpanel.isEmpty() && !upanel.isEmpty() && iEnd < lpanel.nblocks())
        {
            int& iSt = ist[i];
            iSt = iEnd;
            iEnd = lpanel.getEndBlock(iSt, maxGemmRows[i]);
            assert(iEnd > iSt);
            jst[i] = jend[i] = 0;
            done_flags[i] = 0;
        }
        else
        {
            done_flags[i] = 1;
        }
    }
};

struct MarshallSCUInner_Predicate
{
    __host__ __device__ bool operator()(const int &x)
    {
        return x == 0;
    }
};

template<typename T>
struct element_diff : public thrust::unary_function<T,T>
{
    T* st, *end;
    element_diff(T* st, T *end) 
    {
        this->st = st;
        this->end = end;
    }
    
    __device__ T operator()(const T &x) const
    {
        return end[x] - st[x];
    }
};


struct MarshallSCUInnerFunc {
    int k_st, *ist, *iend, *jst, *jend, *maxGemmCols;
    LUstructGPU_t *A_gpu;
    double** A_ptrs, **B_ptrs, **C_ptrs;
    int* lda_array, *ldb_array, *ldc_array, *m_array, *n_array, *k_array;

    MarshallSCUInnerFunc(
        int k_st, int *ist, int *iend, int *jst, int *jend, int *maxGemmCols, 
        double** A_ptrs, int* lda_array, double** B_ptrs, int* ldb_array, double **C_ptrs, int *ldc_array,
        int *m_array, int *n_array, int *k_array, LUstructGPU_t *A_gpu
    )
    {
        this->k_st = k_st;
        this->ist = ist;
        this->iend = iend;
        this->jst = jst;
        this->jend = jend;
        this->maxGemmCols = maxGemmCols;
        this->A_ptrs = A_ptrs;
        this->B_ptrs = B_ptrs;
        this->C_ptrs = C_ptrs;
        this->lda_array = lda_array;
        this->ldb_array = ldb_array;
        this->ldc_array = ldc_array;
        this->m_array = m_array;
        this->n_array = n_array;
        this->k_array = k_array;
        this->A_gpu = A_gpu;
    }

    __device__ void operator()(const unsigned int &i) const
    {
        int k = A_gpu->dperm_c_supno[k_st + i];
        int* xsup = A_gpu->xsup;
        lpanelGPU_t &lpanel = A_gpu->lPanelVec[A_gpu->g2lCol(k)];
        upanelGPU_t &upanel = A_gpu->uPanelVec[A_gpu->g2lCol(k)];
        
        int iSt = ist[i], iEnd = iend[i]; 
        int& jSt = jst[i], &jEnd = jend[i];
        
        // Not done if even one operation still has work to do 
        if(!lpanel.isEmpty() && !upanel.isEmpty() && jEnd < upanel.nblocks())
        {
            jSt = jEnd;
            jEnd = upanel.getEndBlock(jSt, maxGemmCols[i]);
            assert(jEnd > jSt);
        
            A_ptrs[i] = lpanel.blkPtr(iSt);
            B_ptrs[i] = upanel.blkPtr(jSt);
            C_ptrs[i] = A_gpu->dgpuGemmBuffs[i];

            lda_array[i] = lpanel.LDA();
            ldb_array[i] = upanel.LDA();
            ldc_array[i] = lpanel.stRow(iEnd) - lpanel.stRow(iSt);
                        
            m_array[i] = ldc_array[i];
            n_array[i] = upanel.stCol(jEnd) - upanel.stCol(jSt);
            k_array[i] = SuperSize(k);
        }
        else
        {
            A_ptrs[i] = B_ptrs[i] = C_ptrs[i] = NULL;
            lda_array[i] = ldb_array[i] = ldc_array[i] = 1;
            m_array[i] = n_array[i] = k_array[i] = 0;
        }
    }
};

// Marshalling routines for batched execution 
void LUstruct_v100::marshallBatchedLUData(int k_st, int k_end, int_t *perm_c_supno)
{
    // First gather up all the pointer and meta data on the host 
    LUMarshallData& mdata = A_gpu.marshall_data;
    mdata.batchsize = k_end - k_st;
    
    // MarshallLUFunc func(k_st, mdata.dev_diag_ptrs, mdata.dev_diag_ld_array, mdata.dev_diag_dim_array, dA_gpu);

    MarshallLUFunc_flat func(
        k_st, mdata.dev_diag_ptrs, mdata.dev_diag_ld_array, mdata.dev_diag_dim_array, 
        d_localLU.Lnzval_bc_ptr, d_localLU.Lrowind_bc_ptr, A_gpu.dperm_c_supno, A_gpu.xsup
    );

    thrust::for_each(
        thrust::system::cuda::par, thrust::counting_iterator<int>(0),
        thrust::counting_iterator<int>(mdata.batchsize), func
    );

    // double **diag_ptrs = mdata.host_diag_ptrs.data();
    // int *ld_batch = mdata.host_diag_ld_array.data();
    // int *dim_batch = mdata.host_diag_dim_array.data();

	// mdata.batchsize = 0;

    // for (int_t k0 = k_st; k0 < k_end; k0++)
    // {
    //     int_t k = perm_c_supno[k0];
        
	// 	if (iam == procIJ(k, k))
	// 	{			
    //         assert(mdata.batchsize < mdata.host_diag_ptrs.size());

    //         lpanel_t &lpanel = lPanelVec[g2lCol(k)];
	// 		diag_ptrs[mdata.batchsize] = lpanel.blkPtrGPU(0);
	// 		ld_batch[mdata.batchsize] = lpanel.LDA();
	// 		dim_batch[mdata.batchsize] = SuperSize(k);	
	// 		mdata.batchsize++;
	// 	}     
    // }

    // mdata.setMaxDiag();
    // // Then copy the marshalled data over to the GPU 
    // gpuErrchk(cudaMemcpy(mdata.dev_diag_ptrs, diag_ptrs, mdata.batchsize * sizeof(double*), cudaMemcpyHostToDevice));
    // gpuErrchk(cudaMemcpy(mdata.dev_diag_ld_array, ld_batch, mdata.batchsize * sizeof(int), cudaMemcpyHostToDevice));
    // gpuErrchk(cudaMemcpy(mdata.dev_diag_dim_array, dim_batch, mdata.batchsize * sizeof(int), cudaMemcpyHostToDevice));
}

void LUstruct_v100::marshallBatchedTRSMUData(int k_st, int k_end, int_t *perm_c_supno)
{
    // First gather up all the pointer and meta data on the host 
    LUMarshallData& mdata = A_gpu.marshall_data;
    mdata.batchsize = k_end - k_st;

    MarshallTRSMUFunc func(
        k_st, mdata.dev_diag_ptrs, mdata.dev_diag_ld_array, mdata.dev_diag_dim_array, 
        mdata.dev_panel_ptrs, mdata.dev_panel_ld_array, mdata.dev_panel_dim_array, dA_gpu
    );

    thrust::for_each(
        thrust::system::cuda::par, thrust::counting_iterator<int>(0),
        thrust::counting_iterator<int>(mdata.batchsize), func
    );

    // double **panel_ptrs = mdata.host_panel_ptrs.data();
    // int *panel_ld_batch = mdata.host_panel_ld_array.data();
    // int *panel_dim_batch = mdata.host_panel_dim_array.data();
    // double **diag_ptrs = mdata.host_diag_ptrs.data();
    // int *diag_ld_batch = mdata.host_diag_ld_array.data();
    // int *diag_dim_batch = mdata.host_diag_dim_array.data();

	// mdata.batchsize = 0;

    // for (int_t k0 = k_st; k0 < k_end; k0++)
    // {
    //     int_t k = perm_c_supno[k0];
    //     int_t buffer_offset = k0 - k_st;
	// 	int ksupc = SuperSize(k);

	// 	if (myrow == krow(k))
	// 	{			
    //         upanel_t& upanel = uPanelVec[g2lRow(k)];
    //         lpanel_t &lpanel = lPanelVec[g2lCol(k)];
    //         if(!upanel.isEmpty())
    //         {
    //             assert(mdata.batchsize < mdata.host_diag_ptrs.size());

    //             panel_ptrs[mdata.batchsize] = upanel.blkPtrGPU(0);
    //             panel_ld_batch[mdata.batchsize] = upanel.LDA();
    //             panel_dim_batch[mdata.batchsize] = upanel.nzcols();
                
    //             // Hackathon change: using the original diagonal block instead of the bcast buffer
    //             // diag_ptrs[mdata.batchsize] = A_gpu.dFBufs[buffer_offset];
    //             // diag_ld_batch[mdata.batchsize] = ksupc;
    //             // diag_dim_batch[mdata.batchsize] = ksupc;
    //             diag_ptrs[mdata.batchsize] = lpanel.blkPtrGPU(0);
    //             diag_ld_batch[mdata.batchsize] = lpanel.LDA();
    //             diag_dim_batch[mdata.batchsize] = ksupc;

    //             mdata.batchsize++;
    //         }
	// 	}     
    // }

    // mdata.setMaxDiag();
    // mdata.setMaxPanel();
    
    // // Then copy the marshalled data over to the GPU 
    // gpuErrchk(cudaMemcpy(mdata.dev_diag_ptrs, diag_ptrs, mdata.batchsize * sizeof(double*), cudaMemcpyHostToDevice));
    // gpuErrchk(cudaMemcpy(mdata.dev_diag_ld_array, diag_ld_batch, mdata.batchsize * sizeof(int), cudaMemcpyHostToDevice));
    // gpuErrchk(cudaMemcpy(mdata.dev_diag_dim_array, diag_dim_batch, mdata.batchsize * sizeof(int), cudaMemcpyHostToDevice));
    // gpuErrchk(cudaMemcpy(mdata.dev_panel_ptrs, panel_ptrs, mdata.batchsize * sizeof(double*), cudaMemcpyHostToDevice));
    // gpuErrchk(cudaMemcpy(mdata.dev_panel_ld_array, panel_ld_batch, mdata.batchsize * sizeof(int), cudaMemcpyHostToDevice));
    // gpuErrchk(cudaMemcpy(mdata.dev_panel_dim_array, panel_dim_batch, mdata.batchsize * sizeof(int), cudaMemcpyHostToDevice));
}

void LUstruct_v100::marshallBatchedTRSMLData(int k_st, int k_end, int_t *perm_c_supno)
{
    // First gather up all the pointer and meta data on the host 
    LUMarshallData& mdata = A_gpu.marshall_data;
    mdata.batchsize = k_end - k_st;

    // MarshallTRSMLFunc func(
    //     k_st, mdata.dev_diag_ptrs, mdata.dev_diag_ld_array, mdata.dev_diag_dim_array, 
    //     mdata.dev_panel_ptrs, mdata.dev_panel_ld_array, mdata.dev_panel_dim_array, dA_gpu
    // );

    MarshallTRSMLFunc_flat func(
        k_st, mdata.dev_diag_ptrs, mdata.dev_diag_ld_array, mdata.dev_diag_dim_array, 
        mdata.dev_panel_ptrs, mdata.dev_panel_ld_array, mdata.dev_panel_dim_array,
        d_localLU.Lnzval_bc_ptr, d_localLU.Lrowind_bc_ptr, A_gpu.dperm_c_supno, A_gpu.xsup
    );

    thrust::for_each(
        thrust::system::cuda::par, thrust::counting_iterator<int>(0),
        thrust::counting_iterator<int>(mdata.batchsize), func
    );

    // double **panel_ptrs = mdata.host_panel_ptrs.data();
    // int *panel_ld_batch = mdata.host_panel_ld_array.data();
    // int *panel_dim_batch = mdata.host_panel_dim_array.data();
    // double **diag_ptrs = mdata.host_diag_ptrs.data();
    // int *diag_ld_batch = mdata.host_diag_ld_array.data();
    // int *diag_dim_batch = mdata.host_diag_dim_array.data();

	// mdata.batchsize = 0;

    // for (int_t k0 = k_st; k0 < k_end; k0++)
    // {
    //     int_t k = perm_c_supno[k0];
    //     int_t buffer_offset = k0 - k_st;
	// 	int ksupc = SuperSize(k);

	// 	if (mycol == kcol(k))
	// 	{			
    //         lpanel_t &lpanel = lPanelVec[g2lCol(k)];
    //         if(!lpanel.isEmpty())
    //         {
    //             assert(mdata.batchsize < mdata.host_diag_ptrs.size());

    //             double *lPanelStPtr = lpanel.blkPtrGPU(0);
    //             int_t len = lpanel.nzrows();
    //             if(lpanel.haveDiag())
    //             {
    //                 /* code */
    //                 lPanelStPtr = lpanel.blkPtrGPU(1);
    //                 len -= lpanel.nbrow(0);
    //             }
    //             panel_ptrs[mdata.batchsize] = lPanelStPtr;
    //             panel_ld_batch[mdata.batchsize] = lpanel.LDA();
    //             panel_dim_batch[mdata.batchsize] = len;
                
    //             // Hackathon change: using the original diagonal block instead of the bcast buffer
    //             // diag_ptrs[mdata.batchsize] = A_gpu.dFBufs[buffer_offset];
    //             // diag_ld_batch[mdata.batchsize] = ksupc;
    //             // diag_dim_batch[mdata.batchsize] = ksupc;
    //             diag_ptrs[mdata.batchsize] = lpanel.blkPtrGPU(0);
    //             diag_ld_batch[mdata.batchsize] = lpanel.LDA();
    //             diag_dim_batch[mdata.batchsize] = ksupc;

    //             mdata.batchsize++;
    //         }
	// 	}     
    // }
    
    // mdata.setMaxDiag();
    // mdata.setMaxPanel();

    // // Then copy the marshalled data over to the GPU 
    // cudaMemcpy(mdata.dev_diag_ptrs, diag_ptrs, mdata.batchsize * sizeof(double*), cudaMemcpyHostToDevice);
    // cudaMemcpy(mdata.dev_diag_ld_array, diag_ld_batch, mdata.batchsize * sizeof(int), cudaMemcpyHostToDevice);
    // cudaMemcpy(mdata.dev_diag_dim_array, diag_dim_batch, mdata.batchsize * sizeof(int), cudaMemcpyHostToDevice);
    // cudaMemcpy(mdata.dev_panel_ptrs, panel_ptrs, mdata.batchsize * sizeof(double*), cudaMemcpyHostToDevice);
    // cudaMemcpy(mdata.dev_panel_ld_array, panel_ld_batch, mdata.batchsize * sizeof(int), cudaMemcpyHostToDevice);
    // cudaMemcpy(mdata.dev_panel_dim_array, panel_dim_batch, mdata.batchsize * sizeof(int), cudaMemcpyHostToDevice);
}

void LUstruct_v100::initSCUMarshallData(int k_st, int k_end, int_t *perm_c_supno)
{
    SCUMarshallData& sc_mdata = A_gpu.sc_marshall_data;
    sc_mdata.batchsize = k_end - k_st;

    MarshallInitSCUFunc func(
        k_st, sc_mdata.dev_ist, sc_mdata.dev_iend, sc_mdata.dev_maxGemmRows, sc_mdata.dev_maxGemmCols, 
        sc_mdata.dev_gpu_lpanels, sc_mdata.dev_gpu_upanels, dA_gpu
    );
    
    thrust::for_each(
        thrust::system::cuda::par, thrust::counting_iterator<int>(0),
        thrust::counting_iterator<int>(sc_mdata.batchsize), func
    );

    // for (int_t k0 = k_st; k0 < k_end; k0++)
    // {
    //     int_t k = perm_c_supno[k0];
    //     int_t buffer_offset = k0 - k_st;

    //     assert(buffer_offset < sc_mdata.upanels.size());

    //     // Wajih: TODO: figure out what this offset does
    //     int offset = 0;
    //     if (UidxSendCounts[k] > 0 && LidxSendCounts[k] > 0) 
    //     {
    //         sc_mdata.upanels[buffer_offset] = getKUpanel(k, offset);
    //         sc_mdata.lpanels[buffer_offset] = getKLpanel(k, offset);

    //         // Set gemm loop parameters for the panels 
    //         upanel_t& upanel = sc_mdata.upanels[buffer_offset];
    //         lpanel_t& lpanel = sc_mdata.lpanels[buffer_offset];
            
    //         sc_mdata.host_gpu_upanels[buffer_offset] = upanel.gpuPanel;
    //         sc_mdata.host_gpu_lpanels[buffer_offset] = lpanel.gpuPanel;

    //         if(!upanel.isEmpty() && !lpanel.isEmpty())
    //         {
    //             int_t st_lb = 0;
    //             if (myrow == krow(k))
    //                 st_lb = 1;

    //             int_t nlb = lpanel.nblocks();
    //             int_t nub = upanel.nblocks();
                
    //             sc_mdata.ist[buffer_offset] = st_lb;
    //             sc_mdata.iend[buffer_offset] = sc_mdata.ist[buffer_offset];

    //             int nrows = lpanel.stRow(nlb) - lpanel.stRow(st_lb);
    //             int ncols = upanel.nzcols();

    //             int maxGemmRows = nrows;
    //             int maxGemmCols = ncols;
    //             // entire gemm doesn't fit in gemm buffer
    //             if (nrows * ncols > A_gpu.gemmBufferSize)
    //             {
    //                 int maxGemmOpSize = (int)sqrt(A_gpu.gemmBufferSize);
    //                 int numberofRowChunks = (nrows + maxGemmOpSize - 1) / maxGemmOpSize;
    //                 maxGemmRows = nrows / numberofRowChunks;
    //                 maxGemmCols = A_gpu.gemmBufferSize / maxGemmRows;
    //             }

    //             sc_mdata.maxGemmRows[buffer_offset] = maxGemmRows;
    //             sc_mdata.maxGemmCols[buffer_offset] = maxGemmCols;
    //         }
    //     }
    // }

    // sc_mdata.copyPanelDataToGPU();
}

int LUstruct_v100::marshallSCUBatchedDataOuter(int k_st, int k_end, int_t *perm_c_supno)
{
    SCUMarshallData& sc_mdata = A_gpu.sc_marshall_data;
    sc_mdata.batchsize = k_end - k_st;

    // Temporarily use the m array for the done flags
    int *done_flags = sc_mdata.dev_m_array;
    MarshallSCUOuterFunc func(
        k_st, sc_mdata.dev_ist, sc_mdata.dev_iend, sc_mdata.dev_jst, sc_mdata.dev_jend, 
        sc_mdata.dev_maxGemmRows, done_flags, dA_gpu 
    );

    thrust::for_each(
        thrust::system::cuda::par, thrust::counting_iterator<int>(0),
        thrust::counting_iterator<int>(sc_mdata.batchsize), func
    );

    bool done = thrust::all_of(
        thrust::system::cuda::par, done_flags, done_flags + sc_mdata.batchsize,
        MarshallSCUOuter_Predicate()
    );

    return done;

    // int done_i = 1;
    // for (int k0 = k_st; k0 < k_end; k0++)
    // {
    //     int k = perm_c_supno[k0];
    //     int buffer_index = k0 - k_st;
    //     lpanel_t& lpanel = sc_mdata.lpanels[buffer_index];
    //     upanel_t& upanel = sc_mdata.upanels[buffer_index];
    //     if(lpanel.isEmpty() || upanel.isEmpty())
    //         continue;

    //     int& iEnd = sc_mdata.iend[buffer_index];
    //     // Not done if even one operation still has work to do 
    //     if(iEnd < lpanel.nblocks())
    //     {
    //         done_i = 0;
    //         int& iSt = sc_mdata.ist[buffer_index];
    //         iSt = iEnd;
    //         iEnd = lpanel.getEndBlock(iSt, sc_mdata.maxGemmRows[buffer_index]);
    //         assert(iEnd > iSt);
    //         sc_mdata.jst[buffer_index] = sc_mdata.jend[buffer_index] = 0;
    //     }
    // }

    // return done_i;
}

int LUstruct_v100::marshallSCUBatchedDataInner(int k_st, int k_end, int_t *perm_c_supno)
{
    SCUMarshallData& sc_mdata = A_gpu.sc_marshall_data;
    int knum = k_end - k_st;
    sc_mdata.batchsize = knum;

    MarshallSCUInnerFunc func(
        k_st, sc_mdata.dev_ist, sc_mdata.dev_iend, sc_mdata.dev_jst, sc_mdata.dev_jend, sc_mdata.dev_maxGemmCols, 
        sc_mdata.dev_A_ptrs, sc_mdata.dev_lda_array, sc_mdata.dev_B_ptrs, sc_mdata.dev_ldb_array, sc_mdata.dev_C_ptrs, 
        sc_mdata.dev_ldc_array, sc_mdata.dev_m_array, sc_mdata.dev_n_array, sc_mdata.dev_k_array, dA_gpu
    );
    
    thrust::counting_iterator<int> start(0), end(knum);
    thrust::for_each(thrust::system::cuda::par, start, end, func);

    // Set the max dims in the marshalled data 
    sc_mdata.max_m = thrust::reduce(thrust::system::cuda::par, sc_mdata.dev_m_array, sc_mdata.dev_m_array + knum, 0, thrust::maximum<int>());
    sc_mdata.max_n = thrust::reduce(thrust::system::cuda::par, sc_mdata.dev_n_array, sc_mdata.dev_n_array + knum, 0, thrust::maximum<int>());
    sc_mdata.max_k = thrust::reduce(thrust::system::cuda::par, sc_mdata.dev_k_array, sc_mdata.dev_k_array + knum, 0, thrust::maximum<int>());
    sc_mdata.max_ilen = thrust::transform_reduce(thrust::system::cuda::par, start, end, element_diff<int>(sc_mdata.dev_ist, sc_mdata.dev_iend), 0, thrust::maximum<int>());
    sc_mdata.max_jlen = thrust::transform_reduce(thrust::system::cuda::par, start, end, element_diff<int>(sc_mdata.dev_jst, sc_mdata.dev_jend), 0, thrust::maximum<int>());
    
    printf("SCU %d -> %d: %d %d %d %d %d\n", k_st, k_end, sc_mdata.max_m, sc_mdata.max_n, sc_mdata.max_k, sc_mdata.max_ilen, sc_mdata.max_jlen);

    return thrust::all_of(
        thrust::system::cuda::par, sc_mdata.dev_m_array, sc_mdata.dev_m_array + sc_mdata.batchsize,
        MarshallSCUInner_Predicate()
    );
    // int done_j = 1;
    // for(int k0 = k_st; k0 < k_end; k0++)
    // {   
    //     int k = perm_c_supno[k0];
    //     int buffer_index = k0 - k_st;
    //     lpanel_t& lpanel = sc_mdata.lpanels[buffer_index];
    //     upanel_t& upanel = sc_mdata.upanels[buffer_index];
        
    //     if(lpanel.isEmpty() || upanel.isEmpty())
    //         continue;

    //     int iSt = sc_mdata.ist[buffer_index];
    //     int iEnd = sc_mdata.iend[buffer_index]; 

    //     int& jSt = sc_mdata.jst[buffer_index];
    //     int& jEnd = sc_mdata.jend[buffer_index];

    //     // Not done if even one operation still has work to do 
    //     if(jEnd < upanel.nblocks())
    //     {
    //         jSt = jEnd;
    //         jEnd = upanel.getEndBlock(jSt, sc_mdata.maxGemmCols[buffer_index]);

    //         assert(jEnd > jSt);
    //         done_j = 0;
    //         // printf("k = %d, ist = %d, iend = %d, jst = %d, jend = %d\n", k, iSt, iEnd, jSt, jEnd);
            
    //         sc_mdata.host_m_array[buffer_index] = lpanel.stRow(iEnd) - lpanel.stRow(iSt);
    //         sc_mdata.host_n_array[buffer_index] = upanel.stCol(jEnd) - upanel.stCol(jSt);
    //         sc_mdata.host_k_array[buffer_index] = supersize(k);
        
    //         sc_mdata.host_A_ptrs[buffer_index] = lpanel.blkPtrGPU(iSt);
    //         sc_mdata.host_B_ptrs[buffer_index] = upanel.blkPtrGPU(jSt);
    //         sc_mdata.host_C_ptrs[buffer_index] = A_gpu.gpuGemmBuffs[buffer_index];

    //         sc_mdata.host_lda_array[buffer_index] = lpanel.LDA();
    //         sc_mdata.host_ldb_array[buffer_index] = upanel.LDA();
    //         sc_mdata.host_ldc_array[buffer_index] = sc_mdata.host_m_array[buffer_index];
    //     }
    //     else
    //     {
    //         sc_mdata.host_A_ptrs[buffer_index] = NULL;
    //         sc_mdata.host_B_ptrs[buffer_index] = NULL;
    //         sc_mdata.host_C_ptrs[buffer_index] = NULL;

    //         sc_mdata.host_m_array[buffer_index] = 0;
    //         sc_mdata.host_n_array[buffer_index] = 0;
    //         sc_mdata.host_k_array[buffer_index] = 0;

    //         sc_mdata.host_lda_array[buffer_index] = 1;
    //         sc_mdata.host_ldb_array[buffer_index] = 1;
    //         sc_mdata.host_ldc_array[buffer_index] = 1;
    //     }
    // } 

    // if(done_j == 0)
    // {   
    //     // Upload the buffers to the gpu 
    //     sc_mdata.setMaxDims();
    //     sc_mdata.copyToGPU();
    // }

    // return done_j;
}

/**
 * @brief Pack non-zero values into a vector.
 *
 * @param spNzvalArray The array of non-zero values.
 * @param nzvalSize The size of the array of non-zero values.
 * @param valOffset The offset of the non-zero values.
 * @param packedNzvals The vector to store the non-zero values.
 * @param packedNzvalsIndices The vector to store the indices of the non-zero values.
 */
void packNzvals(std::vector<double> &packedNzvals, std::vector<int_t> &packedNzvalsIndices,
                double *spNzvalArray, int_t nzvalSize, int_t valOffset)
{
    for (int k = 0; k < nzvalSize; k++)
    {
        if (spNzvalArray[k] != 0)
        {
            packedNzvals.push_back(spNzvalArray[k]);
            packedNzvalsIndices.push_back(valOffset + k);
        }
    }
}

const int AVOID_CPU_NZVAL = 1;
lpanelGPU_t *LUstruct_v100::copyLpanelsToGPU()
{
    lpanelGPU_t *lPanelVec_GPU = new lpanelGPU_t[CEILING(nsupers, Pc)];

    // TODO: set gpuLvalSize, gpuLidxSize
    gpuLvalSize = 0;
    gpuLidxSize = 0;
    for (int_t i = 0; i < CEILING(nsupers, Pc); ++i)
    {
        if (i * Pc + mycol < nsupers && isNodeInMyGrid[i * Pc + mycol] == 1)
        {
            gpuLvalSize += sizeof(double) * lPanelVec[i].nzvalSize();
            gpuLidxSize += sizeof(int_t) * lPanelVec[i].indexSize();
        }
    }

    double *valBuffer = (double *)SUPERLU_MALLOC(gpuLvalSize);
    int_t *idxBuffer = (int_t *)SUPERLU_MALLOC(gpuLidxSize);

    // allocate memory buffer on GPU
    gpuErrchk(cudaMalloc(&gpuLvalBasePtr, gpuLvalSize));
    gpuErrchk(cudaMalloc(&gpuLidxBasePtr, gpuLidxSize));

    size_t valOffset = 0;
    size_t idxOffset = 0;
    double tCopyToCPU = SuperLU_timer_();

    std::vector<double> packedNzvals;
    std::vector<int_t> packedNzvalsIndices;

    // do a memcpy to CPU buffer
    for (int_t i = 0; i < CEILING(nsupers, Pc); ++i)
    {
        if (i * Pc + mycol < nsupers && isNodeInMyGrid[i * Pc + mycol] == 1)
        {
            if (lPanelVec[i].isEmpty())
            {
                lpanelGPU_t ithLpanel(NULL, NULL);
                lPanelVec[i].gpuPanel = ithLpanel;
                lPanelVec_GPU[i] = ithLpanel;
            }
            else
            {
                lpanelGPU_t ithLpanel(&gpuLidxBasePtr[idxOffset], &gpuLvalBasePtr[valOffset]);
                lPanelVec[i].gpuPanel = ithLpanel;
                lPanelVec_GPU[i] = ithLpanel;
                if (AVOID_CPU_NZVAL)
                    packNzvals(packedNzvals, packedNzvalsIndices, lPanelVec[i].val, lPanelVec[i].nzvalSize(), valOffset);
                else
                    memcpy(&valBuffer[valOffset], lPanelVec[i].val, sizeof(double) * lPanelVec[i].nzvalSize());

                memcpy(&idxBuffer[idxOffset], lPanelVec[i].index, sizeof(int_t) * lPanelVec[i].indexSize());

                valOffset += lPanelVec[i].nzvalSize();
                idxOffset += lPanelVec[i].indexSize();
            }
        }
    }
    tCopyToCPU = SuperLU_timer_() - tCopyToCPU;
    std::cout << "Time to copy-L to CPU: " << tCopyToCPU << "\n";
    // do a cudaMemcpy to GPU
    double tLsend = SuperLU_timer_();
    if (AVOID_CPU_NZVAL)
        copyToGPU(gpuLvalBasePtr, packedNzvals, packedNzvalsIndices);
    else
    {
#if 0
            cudaMemcpy(gpuLvalBasePtr, valBuffer, gpuLvalSize, cudaMemcpyHostToDevice);
#else
        copyToGPU_Sparse(gpuLvalBasePtr, valBuffer, gpuLvalSize);
#endif
    }
    // find
    gpuErrchk(cudaMemcpy(gpuLidxBasePtr, idxBuffer, gpuLidxSize, cudaMemcpyHostToDevice));
    tLsend = SuperLU_timer_() - tLsend;
    printf("cudaMemcpy time L =%g \n", tLsend);

    SUPERLU_FREE(valBuffer);
    SUPERLU_FREE(idxBuffer);
    return lPanelVec_GPU;
} /* copyLpanelsToGPU */


upanelGPU_t *LUstruct_v100::copyUpanelsToGPU()
{
#if (DEBUGlevel >= 1)
    int iam = 0;
    CHECK_MALLOC(iam, "Enter copyUpanelsToGPU()");
#endif
    
    upanelGPU_t *uPanelVec_GPU = new upanelGPU_t[CEILING(nsupers, Pr)];

    gpuUvalSize = 0;
    gpuUidxSize = 0;
    for (int_t i = 0; i < CEILING(nsupers, Pr); ++i)
    {
        if (i * Pr + myrow < nsupers && isNodeInMyGrid[i * Pr + myrow] == 1)
        {
            gpuUvalSize += sizeof(double) * uPanelVec[i].nzvalSize();
            gpuUidxSize += sizeof(int_t) * uPanelVec[i].indexSize();
        }
    }

    // TODO: set gpuUvalSize, gpuUidxSize

    // allocate memory buffer on GPU
    gpuErrchk(cudaMalloc(&gpuUvalBasePtr, gpuUvalSize));
    gpuErrchk(cudaMalloc(&gpuUidxBasePtr, gpuUidxSize));

    size_t valOffset = 0;
    size_t idxOffset = 0;

    double tCopyToCPU = SuperLU_timer_();
    for (int_t i = 0; i < CEILING(nsupers, Pr); ++i)
    {
        if (i * Pr + myrow < nsupers && isNodeInMyGrid[i * Pr + myrow] == 1)
        {
            if (uPanelVec[i].isEmpty())
            {
                upanelGPU_t ithupanel(NULL, NULL);
                uPanelVec[i].gpuPanel = ithupanel;
                uPanelVec_GPU[i] = ithupanel;
            }
        }
    }

    int_t *idxBuffer = NULL;
    if ( gpuUidxSize>0 ) /* Sherry fix: gpuUidxSize can be 0 */
	idxBuffer = (int_t *)SUPERLU_MALLOC(gpuUidxSize);

    if (AVOID_CPU_NZVAL)
    {
        printf("AVOID_CPU_NZVAL is set\n");
        std::vector<double> packedNzvals;
        std::vector<int_t> packedNzvalsIndices;
        for (int_t i = 0; i < CEILING(nsupers, Pr); ++i)
        {
            if (i * Pr + myrow < nsupers && isNodeInMyGrid[i * Pr + myrow] == 1)
            {
                if (!uPanelVec[i].isEmpty())
                {

                    upanelGPU_t ithupanel(&gpuUidxBasePtr[idxOffset], &gpuUvalBasePtr[valOffset]);
                    uPanelVec[i].gpuPanel = ithupanel;
                    uPanelVec_GPU[i] = ithupanel;
                    packNzvals(packedNzvals, packedNzvalsIndices, uPanelVec[i].val,
                               uPanelVec[i].nzvalSize(), valOffset);
                    memcpy(&idxBuffer[idxOffset], uPanelVec[i].index, sizeof(int_t) * uPanelVec[i].indexSize());

                    valOffset += uPanelVec[i].nzvalSize();
                    idxOffset += uPanelVec[i].indexSize();
                }
            }
        }
        tCopyToCPU = SuperLU_timer_() - tCopyToCPU;
        printf("copyU to CPU-buff time = %g\n", tCopyToCPU);

        // do a cudaMemcpy to GPU
        double tLsend = SuperLU_timer_();
        copyToGPU(gpuUvalBasePtr, packedNzvals, packedNzvalsIndices);
        gpuErrchk(cudaMemcpy(gpuUidxBasePtr, idxBuffer, gpuUidxSize, cudaMemcpyHostToDevice));
        tLsend = SuperLU_timer_() - tLsend;
        printf("cudaMemcpy time U =%g \n", tLsend);
        // SUPERLU_FREE(valBuffer);
    }
    else /* AVOID_CPU_NZVAL not set */
    {
        // do a memcpy to CPU buffer
        double *valBuffer = (double *)SUPERLU_MALLOC(gpuUvalSize);

        for (int_t i = 0; i < CEILING(nsupers, Pr); ++i)
        {
            if (i * Pr + myrow < nsupers && isNodeInMyGrid[i * Pr + myrow] == 1)
            {
                if (!uPanelVec[i].isEmpty())
                {

                    upanelGPU_t ithupanel(&gpuUidxBasePtr[idxOffset], &gpuUvalBasePtr[valOffset]);
                    uPanelVec[i].gpuPanel = ithupanel;
                    uPanelVec_GPU[i] = ithupanel;
                    memcpy(&valBuffer[valOffset], uPanelVec[i].val, sizeof(double) * uPanelVec[i].nzvalSize());
                    memcpy(&idxBuffer[idxOffset], uPanelVec[i].index, sizeof(int_t) * uPanelVec[i].indexSize());

                    valOffset += uPanelVec[i].nzvalSize();
                    idxOffset += uPanelVec[i].indexSize();
                }
            }
        }
        tCopyToCPU = SuperLU_timer_() - tCopyToCPU;
        printf("copyU to CPU-buff time = %g\n", tCopyToCPU);

        // do a cudaMemcpy to GPU
        double tLsend = SuperLU_timer_();
        const int USE_GPU_COPY = 1;
        if (USE_GPU_COPY)
        {
            gpuErrchk(cudaMemcpy(gpuUvalBasePtr, valBuffer, gpuUvalSize, cudaMemcpyHostToDevice));
        }
        else
            copyToGPU_Sparse(gpuUvalBasePtr, valBuffer, gpuUvalSize);

        gpuErrchk(cudaMemcpy(gpuUidxBasePtr, idxBuffer, gpuUidxSize, cudaMemcpyHostToDevice));
        tLsend = SuperLU_timer_() - tLsend;
        printf("cudaMemcpy time U =%g \n", tLsend);

        SUPERLU_FREE(valBuffer);
    } /* end else AVOID_CPU_NZVAL not set */
    
    if ( gpuUidxSize>0 ) /* Sherry fix: gpuUidxSize can be 0 */
	SUPERLU_FREE(idxBuffer);

#if (DEBUGlevel >= 1)
    CHECK_MALLOC(iam, "Exit copyUpanelsToGPU()");
#endif
    
    return uPanelVec_GPU;
    
} /* copyUpanelsToGPU */
#endif
