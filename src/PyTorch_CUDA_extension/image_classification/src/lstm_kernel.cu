#include <stdio.h>
#include <cublas_v2.h>
#include <curand.h>
#include <TH.h>
#include <THC.h>
#include <THCGeneral.h>

#define TRAINING (false)

#ifdef __cplusplus
	extern "C" {
#endif

// TODO: may invoke THCudaCheck(cudaGetLastError());
// Define some error checking macros.
#define cudaErrCheck(stat) { cudaErrCheck_((stat), __FILE__, __LINE__); }
void cudaErrCheck_(cudaError_t stat, const char *file, int line) {
    if (stat != cudaSuccess) {
        fprintf(stderr, "CUDA Error: %s %s %d\n", cudaGetErrorString(stat), file, line);
    }
}

#define cublasErrCheck(stat) { cublasErrCheck_((stat), __FILE__, __LINE__); }
void cublasErrCheck_(cublasStatus_t stat, const char *file, int line) {
    if (stat != CUBLAS_STATUS_SUCCESS) {
        fprintf(stderr, "cuBLAS Error: %d %s %d\n", stat, file, line);
    }
}

#define curandErrCheck(stat) { curandErrCheck_((stat), __FILE__, __LINE__); }
void curandErrCheck_(curandStatus_t stat, const char *file, int line) {
    if (stat != CURAND_STATUS_SUCCESS) {
        fprintf(stderr, "cuRand Error: %d %s %d\n", stat, file, line);
    }
}


// Device functions
__forceinline__ __device__ float sigmoidf(float in) {
    return 1.f / (1.f + expf(-in));
}

__global__ void set_ones(float * arr, int len) {
    int index = blockIdx.x * blockDim.x + threadIdx.x;
    if(index >= len) return;
    arr[index] = 1.;
}

__global__ void LSTM_unit_fused(int hiddenSize,
                                int miniBatch,
                                float * __restrict__ h_in, // (miniBatch, 4 * hiddenSize)
                                float * __restrict__ x_in, // (miniBatch, 4 * hiddenSize)
                                float * __restrict__ bias,
                                float * __restrict__ linearGates,
                                float * __restrict__ h_out,
                                float * __restrict__ x_out,
                                float * __restrict__ c_in,
                                float * __restrict__ c_out,
                                bool training) {

    int index = blockIdx.x * blockDim.x + threadIdx.x;
    int numElements = miniBatch * hiddenSize;

    if (index >= numElements) return;

    int currentBatch = index / hiddenSize;
    int gateIndex = (index % hiddenSize) + 4 * currentBatch * hiddenSize;

    float gate[4];

    for (int i = 0; i < 4; i++) {
        gate[i] = x_in[i * hiddenSize + gateIndex] + h_in[i * hiddenSize + gateIndex];
        gate[i] += bias[i * hiddenSize + index % hiddenSize] + bias[(i + 4) * hiddenSize + index % hiddenSize];

        if (training) linearGates[gateIndex + i * hiddenSize] = gate[i];
    }

    float in_gate = sigmoidf(gate[0]);
    float forget_gate = sigmoidf(gate[1]);
    float in_gate2 = tanhf(gate[2]);
    float out_gate = sigmoidf(gate[3]);

    float value = (c_in[index] * forget_gate) + (in_gate * in_gate2);

    c_out[index] = value;

    value = out_gate * tanhf(value);

    h_out[index] = value;
    x_out[index] = value;
}


void forward(THCState* state,
            //   THFloatTensor* h_data_cpu, // numLayers * miniBatch * hiddenSize
              THFloatTensor* x_data_cpu, // seqLength * miniBatch * inputSize
            //   THFloatTensor* c_data_cpu, // numLayers * miniBatch * hiddenSize
              THFloatTensor* weight_cpu,
              THFloatTensor* bias_cpu,
              THIntTensor* _hiddenSize,
              THIntTensor* _miniBatch,
              THIntTensor* _seqLength,
              THIntTensor* _numLayers) {

	// // start timing
    // float elapsedTime;
    // cudaEvent_t start, stop;
    // cudaErrCheck(cudaEventCreate(&start));
    // cudaErrCheck(cudaEventCreate(&stop));
    // cudaErrCheck(cudaEventRecord(start));

    int hiddenSize = THIntTensor_data(_hiddenSize)[0];
    int miniBatch = THIntTensor_data(_miniBatch)[0];
    int seqLength = THIntTensor_data(_seqLength)[0];
    int numLayers = THIntTensor_data(_numLayers)[0];
    int numElements = hiddenSize * miniBatch;

    // alloc device memory
    float *h_data, *x_data, *c_data;
    cudaErrCheck(cudaMalloc((void**)&h_data, (numLayers) * (seqLength + 1) * numElements * sizeof(float)));
    cudaErrCheck(cudaMalloc((void**)&x_data, (numLayers + 1) * (seqLength) * numElements * sizeof(float)));
    cudaErrCheck(cudaMalloc((void**)&c_data, (numLayers) * (seqLength + 1) * numElements * sizeof(float)));

    // continue alloc device memory
    float *weight, *weight_T;
    cudaErrCheck(cudaMalloc((void**)&weight, numLayers * hiddenSize * hiddenSize * 8 * sizeof(float)));
    cudaErrCheck(cudaMalloc((void**)&weight_T, numLayers * hiddenSize * hiddenSize * 8 * sizeof(float)));

    float *bias;
    cudaErrCheck(cudaMalloc((void**)&bias, numLayers * hiddenSize * 8 * sizeof(float)));

    // move from host to device
    // cudaErrCheck(cudaMemcpy(h_data, THFloatTensor_data(h_data_cpu), numLayers * numElements * sizeof(float), cudaMemcpyHostToDevice));
    cudaErrCheck(cudaMemcpy(x_data, THFloatTensor_data(x_data_cpu), seqLength * numElements * sizeof(float), cudaMemcpyHostToDevice));
    // cudaErrCheck(cudaMemcpy(c_data, THFloatTensor_data(c_data_cpu), numLayers * numElements * sizeof(float), cudaMemcpyHostToDevice));
    cudaErrCheck(cudaMemcpy(weight, THFloatTensor_data(weight_cpu), numLayers * hiddenSize * hiddenSize * 8 * sizeof(float), cudaMemcpyHostToDevice));
    cudaErrCheck(cudaMemcpy(bias, THFloatTensor_data(bias_cpu), numLayers * hiddenSize * 8 * sizeof(float), cudaMemcpyHostToDevice));

    // verify x - correct
    // for(int qq = 0; qq < seqLength; qq++) {
    //     printf("time: %d\n", qq);
    //     float* temp = (float*)malloc(numElements * sizeof(float));
    //     cudaErrCheck(cudaMemcpy(temp,
    //                 x_data + qq * numElements,
    //                 numElements * sizeof(float),
    //                 cudaMemcpyDeviceToHost));
    //     for(int pp = 0; pp < numElements; pp++){
    //         printf("%f  ", temp[pp]);
    //     }
    //     printf("\n\n");
    //     free(temp);
    // }

    float *h_in, *x_in;
    cudaErrCheck(cudaMalloc((void**)&h_in, 4 * numLayers * numElements * sizeof(float)));
    cudaErrCheck(cudaMalloc((void**)&x_in, 4 * seqLength * numElements * sizeof(float)));

    float *linearGates;
    // Activations
    if (TRAINING) {
        cudaErrCheck(cudaMalloc((void**)&linearGates, 4 * seqLength * numLayers * numElements * sizeof(float)));
    }

    // (operation + layer) wise streams for optimization 6
    cudaStream_t *stream_x, *stream_h;
    stream_x = (cudaStream_t*)malloc(numLayers * sizeof(cudaStream_t));
    stream_h = (cudaStream_t*)malloc(numLayers * sizeof(cudaStream_t));

    for (int i = 0; i < numLayers; i++) {
        cudaErrCheck(cudaStreamCreate(&stream_x[i]));
        cudaErrCheck(cudaStreamCreateWithPriority(&stream_h[i], 0, -1));
    }

    // alloc events
    cudaEvent_t **events_x, **events_h;
    events_x = (cudaEvent_t**)malloc(numLayers * sizeof(cudaEvent_t*));
    events_h = (cudaEvent_t**)malloc(numLayers * sizeof(cudaEvent_t*));
    for (int i = 0; i < numLayers; i++) {
        events_x[i] = (cudaEvent_t*)malloc(seqLength * sizeof(cudaEvent_t));
        events_h[i] = (cudaEvent_t*)malloc(seqLength * sizeof(cudaEvent_t));
    }

    // initiate random inputs
    curandGenerator_t gen;
    curandErrCheck(curandCreateGenerator(&gen, CURAND_RNG_PSEUDO_DEFAULT));
    curandErrCheck(curandSetPseudoRandomGeneratorSeed(gen, 1782ULL));
    cudaErrCheck(cudaMemset(h_data, 0, (numLayers) * (seqLength + 1) * numElements * sizeof(float)));
    cudaErrCheck(cudaMemset(c_data, 0, (numLayers) * (seqLength + 1) * numElements * sizeof(float)));
    // curandErrCheck(curandGenerateUniform(gen, h_data, (seqLength + 1) * (numLayers) * numElements));
    // curandErrCheck(curandGenerateUniform(gen, c_data, (seqLength + 1) * (numLayers) * numElements));
    // curandErrCheck(curandGenerateUniform(gen, x_data, (seqLength) * (numLayers + 1) * numElements));
    // curandErrCheck(curandGenerateUniform(gen, weight, numLayers * hiddenSize * hiddenSize * 8));
    // curandErrCheck(curandGenerateUniform(gen, bias, numLayers * hiddenSize * 8));
    curandErrCheck(curandDestroyGenerator(gen));

    dim3 blockDim, gridDim;
    blockDim.x = 256;
    gridDim.x = ((numLayers) * (seqLength + 1) * numElements + blockDim.x - 1) / blockDim.x;
    // set_ones<<<gridDim,blockDim>>>(c_data, (numLayers) * (seqLength + 1) * numElements);
    // set_ones<<<gridDim,blockDim>>>(h_data, (numLayers) * (seqLength + 1) * numElements);

    // verify initialization - cudaMemset can only initialize zeros
    // for(int qq = 0; qq < seqLength + 1; qq++) {
    //     printf("time: %d\n", qq);
    //     float* temp = (float*)malloc(numElements * sizeof(float));
    //     cudaErrCheck(cudaMemcpy(temp,
    //                 h_data + qq * numElements,
    //                 numElements * sizeof(float),
    //                 cudaMemcpyDeviceToHost));
    //     for(int pp = 0; pp < numElements; pp++){
    //         printf("%f  ", temp[pp]);
    //     }
    //     printf("\n\n");
    //     free(temp);
    // }

    // create cuBLAS handle.
    cublasHandle_t handle;
    cublasErrCheck(cublasCreate(&handle));

    cudaErrCheck(cudaDeviceSynchronize());

    // LSTM

    // const cublasOperation_t a_trans = CUBLAS_OP_N;
    const cublasOperation_t a_trans = CUBLAS_OP_T; // do not do optimization 4
    const cublasOperation_t b_trans = CUBLAS_OP_N; // always N

    // cublasSgemm(): C = alpha * (A + B) + beta * C
    float alpha = 1.f;
    float beta  = 0.f;

    if (a_trans == CUBLAS_OP_N) {
        // printf("MANNUALY TRANSPOSE\n");
        // do optimization 4 here, transpose A
        for (int layer = 0; layer <numLayers; layer++) {

            // for x(t)
            float *W_weight_in = weight + layer * hiddenSize * hiddenSize * 8;
            float *W_weight_out = weight_T + layer * hiddenSize * hiddenSize * 8;

            // for h(t-1)
            float *R_weight_in = weight + layer * hiddenSize * hiddenSize * 8 + hiddenSize * hiddenSize * 4;
            float *R_weight_out = weight_T + layer * hiddenSize * hiddenSize * 8 + hiddenSize * hiddenSize * 4;

            // transposed weights: hiddenSize * (4 * hiddenSize)
            cublasErrCheck(cublasSetStream(handle, stream_x[layer]));
						cublasErrCheck(cublasSgeam(handle, CUBLAS_OP_T, // trans A
                                        CUBLAS_OP_N, // trans B
                                        4 * hiddenSize, // #rows in A & C
                                        hiddenSize, // #cols in B & C
                                        &alpha, // scale A
                                        W_weight_in, // A
                                        hiddenSize, // leading dim in A
                                        &beta, // scale B
                                        NULL, // B
                                        4 * hiddenSize, // leading dim in B
                                        W_weight_out, // C
                                        4 * hiddenSize)); // leading dim in C

            cublasErrCheck(cublasSetStream(handle, stream_h[layer]));
						cublasErrCheck(cublasSgeam(handle, CUBLAS_OP_T, // trans A
                                        CUBLAS_OP_N, // trans B
                                        4 * hiddenSize, // #rows in A & C
                                        hiddenSize, // #cols in B & C
                                        &alpha, // scale A
                                        R_weight_in, // A
                                        hiddenSize, // leading dim in A
                                        &beta, // scale B
                                        NULL, // B
                                        4 * hiddenSize, // leading dim in B
                                        R_weight_out, // C
                                        4 * hiddenSize)); // leading dim in C
        }
    }
    else {
        // printf("NO TRANSPOSE\n");
        weight_T = weight;
    }

    int lStart = 0; // layer starts from
    int lEnd = 0;   // layer ends at
    int tStart = 0; // timestep starts from
    int tEnd = 0;   // timestep ends at
    int recurBatchSize = 4; // optimization 5 will make it 2

    while (true) {
        // Many layer "scheduling".
        if (lEnd == 0) {
            lStart = 0;
            lEnd = 1;
            tStart = 0;
        }
        else {
            // Move "up" and "left"
            lStart++;
            lEnd++;

            tStart -= recurBatchSize;

            // Over the top or off the left, reset to layer 0
            if (lEnd > numLayers || tStart < 0) {
                tStart += (lStart + 1) * recurBatchSize;

                lStart = 0;
                lEnd = 1;
            }

            // Off the right, step up
            while (tStart >= seqLength && lEnd <= numLayers) {
                lStart++;
                lEnd++;

                tStart -= recurBatchSize;
            }


            // Over the top or off the left, done!
            if (lEnd > numLayers || tStart < 0) {
                break;
            }
        }

        tEnd = tStart + recurBatchSize;
        if (tEnd > seqLength) tEnd = seqLength;

        // lStart, lEnd always differ 1
        for (int layer = lStart; layer < lEnd; layer++) {

            // do x(t) * W_weight on stream_x[layer]
            cublasErrCheck(cublasSetStream(handle, stream_x[layer]));

            // tStart, tEnd differ recurBatchSize
            for (int i = tStart; i < tEnd; i++) {
                if (layer > 0) {
                    cudaErrCheck(cudaStreamWaitEvent(stream_x[layer], events_h[layer - 1][i], 0));
                    cudaErrCheck(cudaEventDestroy(events_h[layer - 1][i]));
                }
            }

            // x(t) = x(t) * [W_weight]
            // (miniBatch, 4 * hiddenSize) TODO: transpose
						cublasErrCheck(cublasSgemm(handle,
                                    a_trans, b_trans,
                                    4 * hiddenSize, // #rows of A and C
                                    miniBatch * (tEnd - tStart), // #cols of B and C
                                    hiddenSize, // #cols of A and B
                                    &alpha,
                                    &weight_T[layer * 8 * hiddenSize * hiddenSize], // A
                                    a_trans == CUBLAS_OP_N ? 4 * hiddenSize : hiddenSize, // leading dimension of A, where we can try different data layout
                                    x_data + tStart * numElements + layer * seqLength * numElements, // B
                                    hiddenSize, // leading dimension of B, where we can try different data layout
                                    &beta,
                                    x_in + 4 * tStart * numElements, // C
                                    4 * hiddenSize // leading dimension of C
                                    ));

            for (int i = tStart; i < tEnd; i++) {
                cudaErrCheck(cudaEventCreate(&events_x[layer][i], cudaEventDisableTiming));
                cudaErrCheck(cudaEventRecord(events_x[layer][i], stream_x[layer]));
            }

            for (int i = tStart; i < tEnd; i++) {

                // verify input h - correctly locate output h from last time step
                // if(i == 0) {
                //     printf("VERIFY h\n");
                //     float* temp = (float*)malloc(numElements * sizeof(float));
                //     cudaErrCheck(cudaMemcpy(temp,
                //                 h_data + i * numElements + layer * (seqLength + 1) * numElements,
                //                 numElements * sizeof(float),
                //                 cudaMemcpyDeviceToHost));
                //     for(int pp = 0; pp < numElements; pp++){
                //         printf("%f  ", temp[pp]);
                //     }
                //     printf("\n\n");
                //     free(temp);
                // }

                // verify R weight
                // if(i == 0) {
                //     printf("VERIFY R\n");
                //     float* temp = (float*)malloc(hiddenSize * 4 * hiddenSize * sizeof(float));
                //     cudaErrCheck(cudaMemcpy(temp,
                //                 weight_T + 4 * hiddenSize * hiddenSize + layer * 8 * hiddenSize * hiddenSize,
                //                 hiddenSize * 4 * hiddenSize * sizeof(float),
                //                 cudaMemcpyDeviceToHost));
                //     for(int pp = 0; pp < hiddenSize * 4 * hiddenSize; pp++){
                //         printf("%f  ", temp[pp]);
                //     }
                //     printf("\n\n");
                //     free(temp);
                // }

                // do h(t-1) *= [R_weight] on stream_h[layer]
                cublasErrCheck(cublasSetStream(handle, stream_h[layer]));

                // h(t-1) = h(t-1) * [R_weight]
                // (miniBatch, 4 * hiddenSize) TODO: transpose
								cublasErrCheck(cublasSgemm(handle,
                                        a_trans, b_trans,
                                        4 * hiddenSize, miniBatch, hiddenSize,
                                        &alpha,
                                        &weight_T[4 * hiddenSize * hiddenSize + layer * 8 * hiddenSize * hiddenSize],
                                        a_trans == CUBLAS_OP_N ? 4 * hiddenSize : hiddenSize,
                                        h_data + i * numElements + layer * (seqLength + 1) * numElements,
                                        hiddenSize,
                                        &beta,
                                        h_in + 4 * layer * numElements,
                                        4 * hiddenSize));

                cudaErrCheck(cudaStreamWaitEvent(stream_h[layer], events_x[layer][i], 0));
                cudaErrCheck(cudaEventDestroy(events_x[layer][i]));

                // verify h * R
                // if(i == 0) {
                //     printf("VERIFY h * R\n");
                //     float* temp = (float*)malloc(4 * numElements * sizeof(float));
                //     cudaErrCheck(cudaMemcpy(temp,
                //                 h_in + 4 * layer * numElements,
                //                 4 * numElements * sizeof(float),
                //                 cudaMemcpyDeviceToHost));
                //     for(int pp = 0; pp < 4 * numElements; pp++){
                //         printf("%f  ", temp[pp]);
                //     }
                //     printf("\n\n");
                //     free(temp);
                // }

                dim3 blockDim, gridDim;

                blockDim.x = 256;
                gridDim.x = (numElements + blockDim.x - 1) / blockDim.x;

                LSTM_unit_fused <<< gridDim, blockDim, 0, stream_h[layer] >>>
                            (hiddenSize, miniBatch,
                            h_in + 4 * layer * numElements,
                            x_in + 4 * i * numElements,
                            bias + 8 * layer * hiddenSize,
                            TRAINING ? linearGates + 4 * (i * numElements + layer * seqLength * numElements) : NULL,
                            h_data + (i + 1) * numElements + layer * (seqLength + 1) * numElements,
                            x_data + i * numElements + (layer + 1) * seqLength * numElements,
                            c_data + i * numElements + layer * (seqLength + 1) * numElements,
                            c_data + (i + 1) * numElements + layer * (seqLength + 1) * numElements,
                            TRAINING);
                cudaErrCheck(cudaGetLastError());

                if (layer != numLayers - 1) {
                    cudaErrCheck(cudaEventCreate(&events_h[layer][i], cudaEventDisableTiming));
                    cudaErrCheck(cudaEventRecord(events_h[layer][i], stream_h[layer]));
                }
                // verify output h - h(1) correct
                // if(i == 1) {
                //     float* temp = (float*)malloc(numElements * sizeof(float));
                //     cudaErrCheck(cudaMemcpy(temp,
                //                 h_data + (i + 1) * numElements + layer * (seqLength + 1) * numElements,
                //                 numElements * sizeof(float),
                //                 cudaMemcpyDeviceToHost));
                //     for(int pp = 0; pp < numElements; pp++){
                //         printf("%f  ", temp[pp]);
                //     }
                //     printf("\n\n");
                //     free(temp);
                // }
            }
        }
    }

    // copy back the last hidden State to x_data_cpu[0:numElements]
    cudaErrCheck(cudaMemcpy(THFloatTensor_data(x_data_cpu),
                            h_data + (numLayers) * (seqLength + 1) * numElements - numElements,
                            numElements * sizeof(float),
                            cudaMemcpyDeviceToHost));

    // free everything
    // cudaErrCheck(cudaFree(h_data));
    // cudaErrCheck(cudaFree(x_data));
    // cudaErrCheck(cudaFree(c_data));

    if (weight != weight_T) cudaErrCheck(cudaFree(weight));
    cudaErrCheck(cudaFree(weight_T));

    cudaErrCheck(cudaFree(bias));

    cudaErrCheck(cudaFree(h_in));
    cudaErrCheck(cudaFree(x_in));
    if (TRAINING) cudaErrCheck(cudaFree(linearGates));

    for (int i = 0; i < numLayers; i++) {
        if (stream_x[i] != NULL) cudaErrCheck(cudaStreamDestroy(stream_x[i]));
        if (stream_h[i] != NULL) cudaErrCheck(cudaStreamDestroy(stream_h[i]));
    }

    free(stream_x);
    free(stream_h);

    for (int i = 0; i < numLayers; i++) {
        free(events_x[i]);
        free(events_h[i]);
    }
    free(events_x);
    free(events_h);

	// // stop timing
    // cudaErrCheck(cudaEventRecord(stop));
    // cudaErrCheck(cudaEventSynchronize(stop));
    // cudaErrCheck(cudaEventElapsedTime(&elapsedTime, start, stop));
    // cudaErrCheck(cudaDeviceSynchronize());
	// printf("CUDA time:\t%f\n", elapsedTime / 1000);
}

#ifdef __cplusplus
	}
#endif
