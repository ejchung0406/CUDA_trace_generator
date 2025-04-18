/*
 * SPDX-FileCopyrightText: Copyright (c) 2019 NVIDIA CORPORATION & AFFILIATES.
 * All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 * list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 * this list of conditions and the following disclaimer in the documentation
 * and/or other materials provided with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <unordered_set>

/* every tool needs to include this once */
#include "nvbit_tool.h"

/* nvbit interface file */
#include "nvbit.h"

/* nvbit utility functions */
#include "utils/utils.h"

/* kernel id counter, maintained in system memory */
uint32_t kernel_id = 0;

/* total instruction counter, maintained in system memory, incremented by
 * "counter" every time a kernel completes  */
uint64_t total_instr = 0;
uint64_t total_cg = 0;
uint64_t total_indirect = 0;
uint64_t total_shfl = 0;
uint64_t total_ballot = 0;

/* kernel instruction counter, updated by the GPU */
__managed__ uint64_t instr_counter = 0;
__managed__ uint64_t shfl_counter = 0;
__managed__ uint64_t ballot_counter = 0;
__managed__ uint64_t indirect_counter = 0;

/* global control variables for this tool */
uint32_t instr_begin_interval = 0;
uint32_t instr_end_interval = UINT32_MAX;
uint32_t start_grid_num = 0;
uint32_t end_grid_num = UINT32_MAX;
int verbose = 0;
int count_warp_level = 1;
int exclude_pred_off = 0;
int active_from_start = 1;
bool mangled = false;

/* used to select region of insterest when active from start is off */
bool active_region = true;

/* a pthread mutex, used to prevent multiple kernels to run concurrently and
 * therefore to "corrupt" the counter variable */
pthread_mutex_t mutex;

/* nvbit_at_init() is executed as soon as the nvbit tool is loaded. We typically
 * do initializations in this call. In this case for instance we get some
 * environment variables values which we use as input arguments to the tool */
void nvbit_at_init() {
    /* just make sure all managed variables are allocated on GPU */
    setenv("CUDA_MANAGED_FORCE_DEVICE_ALLOC", "1", 1);

    /* we get some environment variables that are going to be use to selectively
     * instrument (within a interval of kernel indexes and instructions). By
     * default we instrument everything. */
    GET_VAR_INT(
        instr_begin_interval, "INSTR_BEGIN", 0,
        "Beginning of the instruction interval where to apply instrumentation");
    GET_VAR_INT(
        instr_end_interval, "INSTR_END", UINT32_MAX,
        "End of the instruction interval where to apply instrumentation");
    GET_VAR_INT(start_grid_num, "START_GRID_NUM", 0,
                "Beginning of the kernel gird launch interval where to apply "
                "instrumentation");
    GET_VAR_INT(
        end_grid_num, "END_GRID_NUM", UINT32_MAX,
        "End of the kernel launch interval where to apply instrumentation");
    GET_VAR_INT(count_warp_level, "COUNT_WARP_LEVEL", 1,
                "Count warp level or thread level instructions");
    GET_VAR_INT(exclude_pred_off, "EXCLUDE_PRED_OFF", 0,
                "Exclude predicated off instruction from count");
    GET_VAR_INT(
        active_from_start, "ACTIVE_FROM_START", 1,
        "Start instruction counting from start or wait for cuProfilerStart "
        "and cuProfilerStop");
    GET_VAR_INT(mangled, "MANGLED_NAMES", 1,
                "Print kernel names mangled or not");

    GET_VAR_INT(verbose, "TOOL_VERBOSE", 0, "Enable verbosity inside the tool");
    if (active_from_start == 0) {
        active_region = false;
    }

    std::string pad(100, '-');
    printf("%s\n", pad.c_str());
}

/* Set used to avoid re-instrumenting the same functions multiple times */
std::unordered_set<CUfunction> already_instrumented;

void instrument_function_if_needed(CUcontext ctx, CUfunction func) {
    /* Get related functions of the kernel (device function that can be
     * called by the kernel) */
    std::vector<CUfunction> related_functions =
        nvbit_get_related_functions(ctx, func);

    /* add kernel itself to the related function vector */
    related_functions.push_back(func);

    /* iterate on function */
    for (auto f : related_functions) {
        /* "recording" function was instrumented, if set insertion failed
         * we have already encountered this function */
        if (!already_instrumented.insert(f).second) {
            continue;
        }

        /* Get the vector of instruction composing the loaded CUFunction "f" */
        const std::vector<Instr *> &instrs = nvbit_get_instrs(ctx, f);

        /* If verbose we print function name and number of" static" instructions
         */
        if (verbose) {
            printf("inspecting %s - num instrs %ld\n",
                   nvbit_get_func_name(ctx, f), instrs.size());
        }

        /* We iterate on the vector of instruction */
        for (auto i : instrs) {
            /* Check if the instruction falls in the interval where we want to
             * instrument */
            if (i->getIdx() >= instr_begin_interval &&
                i->getIdx() < instr_end_interval) {
                /* If verbose we print which instruction we are instrumenting
                 * (both offset in the function and SASS string) */
                if (verbose == 1) {
                    i->print();
                } else if (verbose == 2) {
                    i->printDecoded();
                }

                /* Check indirect function calls */
                if (std::string(i->getOpcode()) == "CALL.ABS" && 
                    std::string(i->getSass()).find("R") != std::string::npos) {
                    /* Insert a call to "count_instrs" before the instruction "i" */
                    nvbit_insert_call(i, "count_instrs", IPOINT_BEFORE);
                    if (exclude_pred_off) {
                        /* pass predicate value */
                        nvbit_add_call_arg_guard_pred_val(i);
                    } else {
                        /* pass always true */
                        nvbit_add_call_arg_const_val32(i, 1);
                    }

                    /* add count warps option */
                    nvbit_add_call_arg_const_val32(i, count_warp_level);
                    /* add pointer to counter location */
                    nvbit_add_call_arg_const_val64(i, (uint64_t)&indirect_counter);
                }

                /* Check __shfl_sync() */
                if (std::string(i->getOpcodeShort()) == "SHFL") {
                    /* Insert a call to "count_instrs" before the instruction "i" */
                    nvbit_insert_call(i, "count_instrs", IPOINT_BEFORE);
                    if (exclude_pred_off) {
                        /* pass predicate value */
                        nvbit_add_call_arg_guard_pred_val(i);
                    } else {
                        /* pass always true */
                        nvbit_add_call_arg_const_val32(i, 1);
                    }

                    /* add count warps option */
                    nvbit_add_call_arg_const_val32(i, count_warp_level);
                    /* add pointer to counter location */
                    nvbit_add_call_arg_const_val64(i, (uint64_t)&shfl_counter);
                }

                /* Check __ballot_sync() */
                if (std::string(i->getOpcode()) == "VOTE.BALL") {
                    /* Insert a call to "count_instrs" before the instruction "i" */
                    nvbit_insert_call(i, "count_instrs", IPOINT_BEFORE);
                    if (exclude_pred_off) {
                        /* pass predicate value */
                        nvbit_add_call_arg_guard_pred_val(i);
                    } else {
                        /* pass always true */
                        nvbit_add_call_arg_const_val32(i, 1);
                    }

                    /* add count warps option */
                    nvbit_add_call_arg_const_val32(i, count_warp_level);
                    /* add pointer to counter location */
                    nvbit_add_call_arg_const_val64(i, (uint64_t)&ballot_counter);
                }

                /* Insert a call to "count_instrs" before the instruction "i" */
                nvbit_insert_call(i, "count_instrs", IPOINT_BEFORE);
                if (exclude_pred_off) {
                    /* pass predicate value */
                    nvbit_add_call_arg_guard_pred_val(i);
                } else {
                    /* pass always true */
                    nvbit_add_call_arg_const_val32(i, 1);
                }

                /* add count warps option */
                nvbit_add_call_arg_const_val32(i, count_warp_level);
                /* add pointer to counter location */
                nvbit_add_call_arg_const_val64(i, (uint64_t)&instr_counter);

            }
        }
    }
}

/* This call-back is triggered every time a CUDA driver call is encountered.
 * Here we can look for a particular CUDA driver call by checking at the
 * call back ids  which are defined in tools_cuda_api_meta.h.
 * This call back is triggered bith at entry and at exit of each CUDA driver
 * call, is_exit=0 is entry, is_exit=1 is exit.
 * */
void nvbit_at_cuda_event(CUcontext ctx, int is_exit, nvbit_api_cuda_t cbid,
                         const char *name, void *params, CUresult *pStatus) {
    /* Identify all the possible CUDA launch events */
    if (cbid == API_CUDA_cuLaunch || cbid == API_CUDA_cuLaunchKernel_ptsz ||
        cbid == API_CUDA_cuLaunchGrid || cbid == API_CUDA_cuLaunchGridAsync ||
        cbid == API_CUDA_cuLaunchKernel ||
        cbid == API_CUDA_cuLaunchKernelEx ||
        cbid == API_CUDA_cuLaunchKernelEx_ptsz) {
        /* cast params to launch parameter based on cbid since if we are here
         * we know these are the right parameters types */
        CUfunction func;
        if (cbid == API_CUDA_cuLaunchKernelEx_ptsz ||
            cbid == API_CUDA_cuLaunchKernelEx) {
            cuLaunchKernelEx_params* p = (cuLaunchKernelEx_params*)params;
            func = p->f;
        } else {
            cuLaunchKernel_params* p = (cuLaunchKernel_params*)params;
            func = p->f;
        }

        if (!is_exit) {
            /* if we are entering in a kernel launch:
             * 1. Lock the mutex to prevent multiple kernels to run concurrently
             * (overriding the counter) in case the user application does that
             * 2. Instrument the function if needed
             * 3. Select if we want to run the instrumented or original
             * version of the kernel
             * 4. Reset the kernel instruction counter */

            pthread_mutex_lock(&mutex);
            instrument_function_if_needed(ctx, func);

            if (active_from_start) {
                if (kernel_id >= start_grid_num && kernel_id < end_grid_num) {
                    active_region = true;
                } else {
                    active_region = false;
                }
            }

            if (active_region) {
                nvbit_enable_instrumented(ctx, func, true);
            } else {
                nvbit_enable_instrumented(ctx, func, false);
            }

            instr_counter = 0;
            indirect_counter = 0;
            shfl_counter = 0;
            ballot_counter = 0;
        } else {
            /* if we are exiting a kernel launch:
             * 1. Wait until the kernel is completed using
             * cudaDeviceSynchronize()
             * 2. Get number of thread blocks in the kernel
             * 3. Print the thread instruction counters
             * 4. Release the lock*/
            CUDA_SAFECALL(cudaDeviceSynchronize());
            total_instr += instr_counter;
            total_indirect += indirect_counter;
            total_shfl += shfl_counter;
            total_ballot += ballot_counter;

            // int num_ctas = 0;
            // if (cbid == API_CUDA_cuLaunchKernel_ptsz ||
            //     cbid == API_CUDA_cuLaunchKernel) {
            //     cuLaunchKernel_params *p2 = (cuLaunchKernel_params *)params;
            //     num_ctas = p2->gridDimX * p2->gridDimY * p2->gridDimZ;
            // } else if (cbid == API_CUDA_cuLaunchKernelEx_ptsz ||
            //     cbid == API_CUDA_cuLaunchKernelEx) {
            //     cuLaunchKernelEx_params *p2 = (cuLaunchKernelEx_params *)params;
            //     num_ctas = p2->config->gridDimX * p2->config->gridDimY *
            //         p2->config->gridDimZ;
            // }
            // printf(
            //     "\nkernel %d - %s - #thread-blocks %d,  kernel "
            //     "instructions %ld, total instructions %ld\n",
            //     kernel_id++, nvbit_get_func_name(ctx, func, mangled), num_ctas,
            //     counter, tot_app_instrs);
            pthread_mutex_unlock(&mutex);
        }
    } else if (cbid == API_CUDA_cuLaunchCooperativeKernel || 
               cbid == API_CUDA_cuLaunchCooperativeKernel_ptsz || 
               cbid == API_CUDA_cuLaunchCooperativeKernelMultiDevice) {
        if (is_exit) {
            total_cg += 1;
        }
    } else if (cbid == API_CUDA_cuProfilerStart && is_exit) {
        if (!active_from_start) {
            active_region = true;
        }
    } else if (cbid == API_CUDA_cuProfilerStop && is_exit) {
        if (!active_from_start) {
            active_region = false;
        }
    }
}

void nvbit_at_term() {
    printf("Total indirect function calls: %ld\n", total_indirect);
    printf("Total cooperative group kernel launches: %ld\n", total_cg);
    if (count_warp_level == 1)
        printf("Total instructions (warp level): %ld\n", total_instr);
    else
        printf("Total instructions (thread level): %ld\n", total_instr);
    printf("Total __shfl_sync() calls: %ld\n", total_shfl);
    printf("Total __ballot_sync() calls: %ld\n", total_ballot);
}
