#include <cuda.h>

#define OP_SUM  0
#define OP_MULT 1

#define ERROR_SUCCESS               0
#define ERROR_MAX_HIST_INSUFFICIENT 1
#define ERROR_INVALID_PARAMETER     2
#define ERROR_SAMPLE_FAILURE        3

#define logisticf(x) 1.0/(1.0+expf(-1.0*x))
#define logitf(x) logf(x) - logf(1.0-x)

const int B = %(B)s;               // blockDim.x

/**
 * Helper function to sum across a block.
 * Assume pS_data is already in shared memory
 * Only the first thread returns a value in pSum
 */
__device__ void reduceBlock( float pSdata[B], float* pSum, int op )
{
   int idx = threadIdx.x * blockDim.y + threadIdx.y;

   // Sync all threads across the block
   __syncthreads();

   // Calculate the minimum value by doing a reduction
   int half = (blockDim.x*blockDim.y) / 2;
   if( idx < half )
   {
       while( half > 0 )
       {
           if(idx < half)
           {
               switch(op)
               {
                   case OP_SUM:
                       pSdata[idx] = pSdata[idx] + pSdata[idx + half];
                       break;
                   case OP_MULT:
                       pSdata[idx] = pSdata[idx] * pSdata[idx + half];
                       break;
                   default:
                       // default to the identity
                       // TODO: throw error?
                       pSdata[idx] = pSdata[idx];
                       break;
               }
           }
           half = half / 2;
           __syncthreads();
       }
   }

   // Store the minimum value back to global memory
   if (idx == 0)
   {
       pSum[0] = pSdata[0];
   }
}


/*
 * Sample a Gamma RV using the Marsaglia Tsang algorithm. This
 * is much faster than algorithms based on Mersenne twister used
 * by Numpy. We do have some overhead from generating extra unif
 * and normal RVs that are just rejected.
 * Our assumption is that W.H.P. we will successfully generate
 * a RV on at least one of the 1024 threads per block.
 * 
 * The vanilla Marsaglia alg requires alpha > 1.0
 * pU is a pointer to an array of uniform random variates, 
 * one for each thread. pN similarly points to normal
 * random variates.
 */
__global__ void sampleGammaRV(float* pU,
                              float* pN,
                              float* pAlpha,
                              float* pBeta,
                              float* pG,
                              int* pStatus)
{
    int x = threadIdx.x;
    int ki = blockIdx.x;
    int kj = blockIdx.y;
    int k_ind = ki*gridDim.y + kj;
    float u = pU[k_ind*blockDim.x + x];
    float n = pN[k_ind*blockDim.x + x];
    
    __shared__ float gamma[B];
    __shared__ bool accept[B];
    
    accept[x] = false;
    
    float a = pAlpha[k_ind];
    float b = pBeta[k_ind];
    
    if (a < 1.0)
    {
        if (x==0)
        {
            pStatus[k_ind] = ERROR_INVALID_PARAMETER;
        }
        return;
    }
    
    float d = a-1.0/3.0;
    float c = 1.0/sqrtf(9.0*d);
    float v = powf(1+c*n,3);

    // if v <= 0 this result is invalid
    if (v<=0)
    {
        accept[x] = false;
    }
    else if (u <=(1-0.0331*powf(n,4.0)) ||
             (logf(u)<0.5*powf(n,2.0)+d*(1-v+logf(v))))
    {
        // rejection sample. The second operation should be
        // performed with low probability. This is the "squeeze"
        gamma[x] = d*v;
        accept[x] = true;
    }
    
    // Reduce across block to find the first accepted sample
    __syncthreads();
    int half = blockDim.x / 2;
    if( x < half )
    {
       while( half > 0 )
       {
           if(x < half)
           {
               // if the latter variate was accepted but the current
               // was not, copy the latter to the current. If the current
               // was accepted we keep it. If neither was accepted we
               // don't change anything.
               if (!accept[x] && accept[x+half])
               {
                   gamma[x] = gamma[x+half];
                   accept[x] = true;
               }
           }
           half = half / 2;
           __syncthreads();
       }
    }
    
    // Store the sample to global memory, or return error if failure
    if (x == 0)
    {
        if (accept[0])
        {
            // rescale the result (assume rate characterization)
            pG[k_ind] = gamma[0]/b;
            pStatus[k_ind] = ERROR_SUCCESS;
        }
        else
        {
            pStatus[k_ind] = ERROR_SAMPLE_FAILURE;
        }
    }
}

/**
 * For each spike, compute the corresponding background rate bin and 
 * the fractional distance between the bin start and endpoints.
 */
__global__ void computeLamOffsetAndFrac(float lam_dt,
                                        int N, 
                                        float Tstart,
                                        float* pS,
                                        int* pLamOffset,
                                        float* pLamFrac
                                        )   
{
    int j = blockIdx.x * blockDim.x + threadIdx.x;
    
    
    if (j < N)
    {
            
        // offset is the floor of the spike time over the bin size
        pLamOffset[j] = int((pS[j]-Tstart)/lam_dt);
        // frac is (spike time - offset*bin_size) / bin_size
        pLamFrac[j] = ((pS[j]-Tstart)-pLamOffset[j]*lam_dt)/lam_dt;
        
        // correct for any rounding/precision errors
        if (pLamFrac[j]<0 &&pLamFrac[j]>-0.001)
        {
            pLamFrac[j] = 0.0;
        }
    }
}

/**
 * Sum the number of spikes attributed to background per process
 * Launch this in a Kx1 grid
 */
__global__ void sumZBkgd(int N,
                         int* pZ,
                         int* pC,
                         int* pZbkgd)
{
    int x     = threadIdx.x;
    int ki    = blockIdx.x;

    __shared__ float zbkgd[B];
    float zbkgdSum;
    zbkgd[x] = 0.0;

    for (int jj=x; jj<N; jj+=B)
    {
        if (pC[jj]==ki && pZ[jj]==-1)
        {
            zbkgd[x]+=1.0;
        }
    }

    reduceBlock(zbkgd, &zbkgdSum, OP_SUM);
    if (x==0)
    {
        pZbkgd[ki] = (int)zbkgdSum;
    }

}

/**
 * Compute the posterior distribution on mu_ki where ki is the process
 * ID. We launch a thread for each process.
 */
__global__ void computeLamHomogPosterior(int K,
		                                 int* pZbkgd,
                                         float alpha_mu,
                                         float beta_mu,
                                         float T,
                                         float* pAlpha_mu_post,
                                         float* pBeta_mu_post
                                         )
{
    int ki = blockIdx.x*blockDim.x + threadIdx.x;

    if (ki < K)
    {
        pAlpha_mu_post[ki] = alpha_mu + (float)pZbkgd[ki];
        pBeta_mu_post[ki] = beta_mu + T;
    }
}

/**
 * Update lambda vector to reflect background rate at each spike time. For
 * homogenous background rate this will be the same for all spikes on a given
 * process.
 */
__global__ void computeLambdaHomogPerSpike(int K,
		                                   float* pLamHomog,
                                           int N,
                                           int* pC,
                                           float* pLam)
{
    int j  = blockIdx.x*blockDim.x + threadIdx.x;
    
    if (j<N)
    {
        // Find cj by searching through pCumSumNs
        for (int cj=0; cj<K; cj++)
        {
        	pLam[cj*N+j] = pLamHomog[cj];
        }
    }    
}

/**
 * Update lambda vector to reflect background rate at each spike time. For
 * time-varying background rate this will be the a linear interpolation between
 * the value specified at each knot.
 */
__global__ void computeLambdaGPPerSpike(int k,
                                        int N,
                                        int N_knots,
                                        float* pLamKnots,
                                        int* pLamOffset,
                                        float* pLamFrac,
                                        float* pLam
                                        )
{
    int j  = blockIdx.x*blockDim.x + threadIdx.x;
    
    if (j<N)
    {
        int off = pLamOffset[j];
        float frac = pLamFrac[j];
        pLam[k*N+j] = expf(pLamKnots[k*N_knots+off])*(1-frac) + 
                      expf(pLamKnots[k*N_knots+off+1])*frac;
    }    
}

/**
 * Compute the log likelihood for a given lambda background rate
 * First compute the trapezoidal integration over the background rate, 
 * since it is linearly interpolated between knots this integral is exact.
 * Second compute the per-spike contribution to the log likelihood.
 */
__global__ void computeLamLogLkhd(int k,
                                  int N,
                                  float* pLamKnots,
                                  float lam_dt,
                                  int N_knots,
                                  int* pZ,
                                  int* pC,
                                  float* pLam,
                                  float* pLL
                                  )
{
    int x = threadIdx.x;
        
    __shared__ float ll[B];
    __shared__ float ll2[B];
    float llTrapSum = 0.0;
    float llSpikeSum = 0.0;
    
    // Step 1: Trapezoidal integration
    ll[x] = 0.0;
    for (int j=x; j<N_knots; j+=B)
    {
        if (j==0 || j==N_knots-1)
        {
            ll[x] += -1.0*lam_dt/2 * expf(pLamKnots[k*N_knots+j]);
        }
        else
        {
            ll[x] += -1.0*lam_dt * expf(pLamKnots[k*N_knots+j]);
        }
    }
    reduceBlock(ll, &llTrapSum, OP_SUM);
    
    // Step 2: Sum per-spike likelihoods for spikes attributed to background
    __syncthreads();
    ll2[x] = 0.0;
    for (int j=x; j<N; j+=B)
    {
        if (pC[j]==k && pZ[j]==-1)
        {
            ll2[x] += logf(pLam[k*N+j]);
        }
    }
    reduceBlock(ll2, &llSpikeSum, OP_SUM);
    
    // Output the total
    if (x==0)
    {
        pLL[0] = llTrapSum + llSpikeSum;
    }
}

/**
 * Update lambda vector to account for differing probabilities
 * as a function of time of day
 */
__global__ void computeTimeOfDayPr(int k,
						      	   int N,
								   int* pToD,
								   float* pPrToD,
								   float* pLam
							 	   )
{
    int j  = blockIdx.x*blockDim.x + threadIdx.x;
    
    if (j<N)
    {
        pLam[k*N+j] *= pPrToD[pToD[j]];
    }    
}