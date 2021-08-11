#include <cassert>
#include <cuda_runtime.h>

#include "cublas_v2.h"
#include "lupanels.hpp"

lpanelGPU_t::lpanelGPU_t(lpanel_t &lpanel) : lpanel_CPU(lpanel)
{
    size_t idxSize = sizeof(int_t) * lpanel.indexSize();
    size_t valSize = sizeof(double) * lpanel.nzvalSize();

    // TODO: deal with empty arrays 
    cudaMalloc(&index, idxSize);
    cudaMemcpy(index, lpanel.index, idxSize, cudaMemcpyHostToDevice);

    cudaMalloc(&val, valSize);
    cudaMemcpy(val, lpanel.val, valSize, cudaMemcpyHostToDevice);
}

int lpanelGPU_t::check(lpanel_t &lpanel)
{
    // both should be simulatnously empty or non empty
    assert(isEmpty() == lpanel.isEmpty());

    size_t valSize = sizeof(double) * lpanel.nzvalSize();

    double *tmpArr = double[lpanel.nzvalSize()];
    cudaMemcpy(tmpArr, val, valSize, cudaMemcpyDeviceToHost);

    // TODO: implemen checkArr
    int out = checkArr(tmpArr, lpanel.val, lpanel.nzvalSize());
    delete tmpArr;
    return 0;
}

int_t lpanelGPU_t::panelSolve(cublasHandle_t handle, cudaStream_t cuStream,
                              int_t ksupsz, double *DiagBlk, int_t LDD)
{

    if (lpanel_CPU.isEmpty())
        return 0;
    double *lPanelStPtr = &val[lpanel_CPU.blkPtrOffset(0)];
    int_t len = lpanel_CPU.nzrows();
    if (lpanel_CPU.haveDiag())
    {
        /* code */
        lPanelStPtr = &val[lpanel_CPU.blkPtrOffset(1)];
        len -= lpanel_CPU.nbrow(0);
    }

    double alpha = 1.0;
    // TODO: Add set stream
    cublasStatus_t cbstatus = cublasDtrsm(handle,
                                          𝖢𝖴𝖡𝖫𝖠𝖲_𝖲𝖨𝖣𝖤_𝖱𝖨𝖦𝖧𝖳, CUBLAS_FILL_MODE_UPPER,
                                          𝖢𝖴𝖡𝖫𝖠𝖲_𝖮𝖯_𝖭, CUBLAS_DIAG_NON_UNIT,
                                          len, ksupsz, alpha, DiagBlk, LDD,
                                          lPanelStPtr, lpanel_CPU.LDA());

    // if (isEmpty()) return 0;
    // double *lPanelStPtr = blkPtr(0);
    // int_t len = nzrows();
    // if (haveDiag())
    // {
    //     /* code */
    //     lPanelStPtr = blkPtr(1);
    //     len -= nbrow(0);
    // }
    // double alpha = 1.0;
    // superlu_dtrsm("R", "U", "N", "N",
    //               len, ksupsz, alpha, DiagBlk, LDD,
    //               lPanelStPtr, LDA());
}

int_t lpanelGPU_t::diagFactorPackDiagBlock(int_t k,
                                           double *UBlk, int_t LDU,
                                           double *DiagLBlk, int_t LDD,
                                           double thresh, int_t *xsup,
                                           superlu_dist_options_t *options, SuperLUStat_t *stat, int *info)
{
    // pack and transfer to CPU
    // cudaMemcpy2D
    int kSupSize = SuperSize(k);
    size_t dpitch = LDD * sizeof(double);
    size_t spitch = lpanel_CPU.LDA() * sizeof(double);
    size_t width = kSupSize * sizeof(double);
    size_t height = kSupSize;

    cudaMemcpy2D(DiagLBlk, dpitch, val, spitch,
                 width, height, cudaMemcpyDeviceToHost);

    // call dgetrf2
    dgstrf2(k, DiagLBlk, LDD, UBlk, LDU,
            thresh, xsup, options, stat, info);

    //copy back to device
    cudaMemcpy2D(val, spitch, DiagLBlk, dpitch,
                 width, height, cudaMemcpyHostToDevice);

    return 0;
}


upanelGPU_t::upanelGPU_t(upanel_t &upanel) : upanel_CPU(upanel)
{
    size_t idxSize = sizeof(int_t) * upanel.indexSize();
    size_t valSize = sizeof(double) * upanel.nzvalSize();

    cudaMalloc(&index, idxSize);
    cudaMemcpy(index, upanel.index, idxSize, cudaMemcpyHostToDevice);

    cudaMalloc(&val, valSize);
    cudaMemcpy(val, upanel.val, valSize, cudaMemcpyHostToDevice);
}


int upanelGPU_t::check(upanel_t &upanel)
{
    // both should be simulatnously empty or non empty
    assert(isEmpty() == upanel.isEmpty());

    size_t valSize = sizeof(double) * upanel.nzvalSize();

    double *tmpArr = double[upanel.nzvalSize()];
    cudaMemcpy(tmpArr, val, valSize, cudaMemcpyDeviceToHost);

    // TODO: implemen checkArr
    int out = checkArr(tmpArr, upanel.val, upanel.nzvalSize());
    delete tmpArr;
    return 0;
}



int_t upanelGPU_t::panelSolve(cublasHandle_t handle, cudaStream_t cuStream,
                              int_t ksupsz, double *DiagBlk, int_t LDD)
{
    if (upanel_CPU.isEmpty())
        return 0;

    double alpha = 1.0;
    // TODO: Add set stream
    cublasStatus_t cbstatus =
        cublasDtrsm(handle,
                    𝖢𝖴𝖡𝖫𝖠𝖲_𝖲𝖨𝖣𝖤_LEFT, CUBLAS_FILL_MODE_LOWER,
                    𝖢𝖴𝖡𝖫𝖠𝖲_𝖮𝖯_𝖭, CUBLAS_DIAG_UNIT,
                    ksupsz, upanel_CPU.nzcols(), alpha, DiagBlk, LDD,
                    val, upanel_CPU.LDA());

    // superlu_dtrsm("L", "L", "N", "U",
    //               ksupsz, nzcols(), 1.0, DiagBlk, LDD, val, LDA());
    return 0;
}
