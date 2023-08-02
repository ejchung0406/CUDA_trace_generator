#!/usr/bin/python
#########################################################################################
# Author: Jaekyu Lee (kacear@gmail.com)
# Date: 7/17/2011
# Description:
#   submit a batch of macsim simulation jobs
#   see README for examples
#
# Note:
#   1. when you specify -cmd option, please remove all '--'
#   2. all .out .stat.out. files will be automatically gzipped unless specifying -disable-gzip
#   3. by specifying -nproc, you can choose number of nodes to be allocated to your jobs
#########################################################################################

import sys
import os
import argparse
import subprocess

def process_options():
  parser = argparse.ArgumentParser(description='run.py')
  parser.add_argument('-proc', action='store', default='1', dest='nproc', help='number of processors that this job requires')
  return parser

def check_segfault_in_file(file_path):
  if not os.path.exists(file_path):
    print(f"File path {file_path} doesn't exist.")
    return True
  
  with open(file_path, "r") as file:
    contents = file.read()

  if "Segmentation fault" in contents or "Aborted" in contents:
    print(f"Segmentation fault or Aborted occurred in file path {file_path}.")
    return True
  
  if not "Success" in contents:
    print(f"Regenerating Traces.")
    return True
  
  return False

def main(argv):
  global args

  # parse arguments
  parser = process_options()
  args = parser.parse_args()
  current_dir = os.getcwd()

  ## path to binary
  macsim_files = ["/fast_data/echung67/macsim/bin/macsim",
                  "/fast_data/echung67/macsim/bin/params.in",
                  "/fast_data/echung67/macsim/bin/trace_file_list"]
  trace_path_base = "/fast_data/echung67/trace/nvbit/"
  rodinia_bin = "/fast_data/echung67/gpu-rodinia/bin/linux/cuda/"
  nvbit_bin = "/fast_data/echung67/nvbit_release/tools/main/main.so"
  compress_bin = "/fast_data/echung67/nvbit_release/tools/main/compress"
  result_dir = os.path.join(current_dir, "run")

  benchmark_names = [
    # Rodinia
    "backprop",
    "bfs",
    "dwt2d",
    "euler3d",
    "gaussian",
    "heartwall",
    "hotspot",
    "lavaMD",
    "lud_cuda",
    "needle",
    "nn",
    "particlefilter_float",
    "particlefilter_naive",
    "pathfinder",
    "sc_gpu",
    "srad_v1",
    "srad_v2",

    # GraphBig
    # "graphbig_bfs_topo_atomic", // To-do: add bin path

    # Gunrock


    # ETC
    "vectoradd",
    "vectormultadd",
    ]

  benchmark_dataset = {
    # Rodinia
    "backprop": ["128", "256", "512", "1024", "2048", "4096", "8192", "16384",
                 "32768", "65536", "131072", "262144", "524288", "1048576"],
    "bfs": ["/fast_data/echung67/rodinia-data/bfs/graph1k.txt",
            "/fast_data/echung67/rodinia-data/bfs/graph2k.txt",
            "/fast_data/echung67/rodinia-data/bfs/graph4k.txt",
            "/fast_data/echung67/rodinia-data/bfs/graph8k.txt",
            "/fast_data/echung67/rodinia-data/bfs/graph16k.txt",
            "/fast_data/echung67/rodinia-data/bfs/graph32k.txt",
            "/fast_data/echung67/rodinia-data/bfs/graph64k.txt",
            "/fast_data/echung67/rodinia-data/bfs/graph128k.txt",
            "/fast_data/echung67/rodinia-data/bfs/graph256k.txt",
            "/fast_data/echung67/rodinia-data/bfs/graph512k.txt"
            # "/fast_data/echung67/rodinia-data/bfs/graph1M.txt",
            # "/fast_data/echung67/rodinia-data/bfs/graph2M.txt",
            ],
    "dwt2d": ["/fast_data/echung67/rodinia-data/dwt2d/192.bmp -d 192x192 -f -5 -l 3",
              "/fast_data/echung67/rodinia-data/dwt2d/rgb.bmp -d 1024x1024 -f -5 -l 3"],
    "euler3d": ["/fast_data/echung67/rodinia-data/cfd/fvcorr.domn.097K"],
    "gaussian": ["-f /fast_data/echung67/rodinia-data/gaussian/matrix3.txt",
                 "-f /fast_data/echung67/rodinia-data/gaussian/matrix4.txt",
                 "-f /fast_data/echung67/rodinia-data/gaussian/matrix16.txt",
                 "-f /fast_data/echung67/rodinia-data/gaussian/matrix32.txt",
                 "-f /fast_data/echung67/rodinia-data/gaussian/matrix48.txt",
                 "-f /fast_data/echung67/rodinia-data/gaussian/matrix64.txt",
                 "-f /fast_data/echung67/rodinia-data/gaussian/matrix80.txt",
                 "-f /fast_data/echung67/rodinia-data/gaussian/matrix96.txt",
                 "-f /fast_data/echung67/rodinia-data/gaussian/matrix112.txt",
                 "-f /fast_data/echung67/rodinia-data/gaussian/matrix128.txt",
                 ],
    "heartwall": ["/fast_data/echung67/rodinia-data/heartwall/test.avi 10"],
    "hotspot": ["512 512 100 /fast_data/echung67/rodinia-data/hotspot/temp_512 /fast_data/echung67/rodinia-data/hotspot/power_512 none",
                "512 512 1000 /fast_data/echung67/rodinia-data/hotspot/temp_512 /fast_data/echung67/rodinia-data/hotspot/power_512 none",
                "512 2 2 /fast_data/echung67/rodinia-data/hotspot/temp_512 /fast_data/echung67/rodinia-data/hotspot/power_512 none"],
    "lavaMD": ["-boxes1d 1", "-boxes1d 2", "-boxes1d 3", "-boxes1d 5",
               "-boxes1d 7", "-boxes1d 10"],
    "lud_cuda": ["-i /fast_data/echung67/rodinia-data/lud/64.dat",
                 "-i /fast_data/echung67/rodinia-data/lud/256.dat",
                 "-i /fast_data/echung67/rodinia-data/lud/512.dat"],
    "needle": ["32 10",
               "64 10",
               "128 10"],
    "nn": ["/fast_data/echung67/rodinia-data/nn/inputGen/list64k.txt -r 30 -lat 30 -lng 90",
           "/fast_data/echung67/rodinia-data/nn/inputGen/list128k.txt -r 30 -lat 30 -lng 90",
           "/fast_data/echung67/rodinia-data/nn/inputGen/list256k.txt -r 30 -lat 30 -lng 90",
           "/fast_data/echung67/rodinia-data/nn/inputGen/list512k.txt -r 30 -lat 30 -lng 90",
           "/fast_data/echung67/rodinia-data/nn/inputGen/list1024k.txt -r 30 -lat 30 -lng 90",
           "/fast_data/echung67/rodinia-data/nn/inputGen/list2048k.txt -r 30 -lat 30 -lng 90",
           "/fast_data/echung67/rodinia-data/nn/inputGen/list4096k.txt -r 30 -lat 30 -lng 90",
           "/fast_data/echung67/rodinia-data/nn/inputGen/list8192k.txt -r 30 -lat 30 -lng 90",
           "/fast_data/echung67/rodinia-data/nn/inputGen/list16384k.txt -r 30 -lat 30 -lng 90",
           "/fast_data/echung67/rodinia-data/nn/inputGen/list32768k.txt -r 30 -lat 30 -lng 90",
           ],
    "particlefilter_float": ["-x 64 -y 64 -z 5 -np 10"],
    "particlefilter_naive": ["-x 128 -y 128 -z 10 -np 1000"],
    "pathfinder": ["10000 50 10",
                   "50000 250 50",
                   "50000 500 100"],
    "sc_gpu": ["2 5 4 16 16 32 none none 1",
               "3 3 4 16 16 4 none none 1",
               "10 20 16 64 16 100 none none 1"],
    "srad_v1": ["3 0.5 64 64",
                "6 0.5 64 64",
                "10 0.5 64 64"],
    "srad_v2": ["64 64 0 32 0 32 0.5 10"],
    
    # GraphBig
    # "graphbig_bfs_topo_atomic": [""],

    # Gunrock


    # ETC
    "vectoradd": ["4096", "16384", "65536"],
    "vectormultadd": ["4096", "16384", "65536"]
  }

  benchmark_subdir = {
    # Rodinia
    "backprop": ["128", "256", "512", "1024", "2048", "4096", "8192", "16384", 
                 "32768", "65536", "131072", "262144", "524288", "1048576"],
    "bfs": ["graph1k", "graph2k", "graph4k", "graph8k", "graph16k", "graph32k",
              "graph64k", "graph128k", "graph256k", "graph512k"],
    "dwt2d": ["192", "1024"],
    "euler3d": ["fvcorr.domn.097K"],
    "gaussian": ["matrix3", "matrix4", "matrix16", "matrix32", "matrix48", "matrix64", "matrix80", "matrix96", "matrix112", "matrix128"],
    "heartwall": ["frames10"],
    "hotspot": ["r512h512i100", "r512h512i1000", "r512h2i2"],
    "lavaMD": ["1", "2", "3", "5", "7", "10"],
    "lud_cuda": ["64", "256", "512"],
    "needle": ["32", "64", "128"],
    "nn": ["64k", "128k", "256k", "512k", "1024k", "2048k", "4096k", "8192k", "16384k", "32768k"],
    "particlefilter_float": ["10"],
    "particlefilter_naive": ["1000"],
    "pathfinder": ["10", "50", "100"],
    "sc_gpu": ["2-5-4-16-16-32", "3-3-4-16-16-4", "10-20-16-64-16-100"],
    "srad_v1": ["3", "6", "10"],
    "srad_v2": ["10"],  

    # GraphBig
    # "graphbig_bfs_topo_atomic": [""],

    # Gunrock


    # ETC
    "vectoradd": ["4096", "16384", "65536"],
    "vectormultadd": ["4096", "16384", "65536"]
  }

  for bench_name in benchmark_names:
    bench_datasets = benchmark_dataset[bench_name]
    bench_subdirs = benchmark_subdir[bench_name]
    for bench_dataset, bench_subdir in zip(bench_datasets, bench_subdirs):
      # create the result directory
      subdir = os.path.join(result_dir, bench_name, bench_subdir)
      if not (check_segfault_in_file(os.path.join(subdir, "nvbit_result.txt"))): continue # de-comment this line if you want the traces to be overwritten
      print(f"Trace Generation: {bench_name}/{bench_subdir}")
      if not os.path.exists(subdir):
        os.makedirs(subdir)
      os.chdir(subdir)

      os.system(f"rm -rf {subdir}/*")
      for macsim_file in macsim_files:
        os.system(f"cp {macsim_file} {subdir}")
      os.system(f"cp {nvbit_bin} {subdir}")
      os.system(f"cp {compress_bin} {subdir}")

      python_file = os.path.join(subdir, "nvbit.py")
      with open(python_file, "w") as f:
        f.write("import os\n\n")
        # f.write("print(os.getcwd())\n")
        bin = rodinia_bin # When running GraphBig or Gunrock, this path should be changed..
        f.write(f"os.system('CUDA_INJECTION64_PATH=./{os.path.basename(nvbit_bin)} {os.path.join(bin, bench_name)} {bench_dataset} > nvbit_result.txt 2>&1')\n")
        f.write(f"os.system('./compress')\n")
        # copy traces in subdir to trace_path_base
        f.write("current_dir = os.getcwd()\n")
        f.write("base_dir = os.path.basename(os.path.dirname(current_dir))\n")
        f.write("parent_dir = os.path.basename(current_dir)\n")
        f.write(f"dest_dir = os.path.join(\"{trace_path_base}\", base_dir, parent_dir)\n")
        f.write("os.system(f\"rm -rf {dest_dir}/*\")\n")
        f.write(f"if not os.path.exists(dest_dir):\n")
        f.write(f"    os.makedirs(dest_dir)\n")
        f.write("subdirs = [name for name in os.listdir(current_dir) if os.path.isdir(os.path.join(current_dir, name))]\n")
        f.write("for subdir in subdirs:\n")
        f.write(f"    src_dir = os.path.join(current_dir, subdir)\n")
        f.write("    os.system(f\"mv {src_dir} {os.path.join(dest_dir, subdir)}\")\n")
        f.write("os.system(f\"mv kernel_config.txt {dest_dir}/kernel_config.txt\")")

      # Execute nvbit python script
      os.system("python3 nvbit.py") 

  # If segmentation fault, re-run the python script for "max_try" times
  for bench_name in benchmark_names:
    bench_datasets = benchmark_dataset[bench_name]
    bench_subdirs = benchmark_subdir[bench_name]
    for bench_dataset, bench_subdir in zip(bench_datasets, bench_subdirs):
      subdir = os.path.join(result_dir, bench_name, bench_subdir)
      nvbit_result_path = os.path.join(subdir, "nvbit_result.txt")
      max_try = 3
      os.chdir(subdir)
      while (check_segfault_in_file(nvbit_result_path) and max_try > 0):
        max_try -= 1
        os.system("python3 nvbit.py")

      if (check_segfault_in_file(nvbit_result_path)):
        print(f"trace generation for subdir {subdir} failed")

      # To-do: At the end of the program, print which traces were generated successfully and which ones were not 

  return

if __name__ == '__main__':
  main(sys.argv)
    