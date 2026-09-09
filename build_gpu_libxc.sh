#!/usr/bin/env bash
set -euo pipefail

# Quantum ESPRESSO 7.6
# NVIDIA HPC SDK 26.5 + CUDA 13.2
# OpenACC + CUDA GPU build
# NVIDIA GPU architecture: sm_89
# Libxc 5.2.3 built with NVHPC

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SRC_DIR}/build-libxc"
LIBXC_DIR="${HOME}/libxc-5.2.3/build-nvhpc"

cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" \
  -DCMAKE_Fortran_COMPILER=nvfortran \
  -DCMAKE_C_COMPILER=nvc \
  -DCMAKE_CXX_COMPILER=nvc++ \
  -DCMAKE_Fortran_FLAGS="-acc" \
  -DCMAKE_EXE_LINKER_FLAGS="-acc" \
  -DQE_ENABLE_MPI=ON \
  -DQE_ENABLE_OPENMP=ON \
  -DQE_ENABLE_LIBXC=ON \
  -DQE_GPU="openacc;cuda" \
  -DQE_GPU_ARCHS=sm_89 \
  -DLIBXC_INCLUDE_DIR="${LIBXC_DIR}" \
  -DLIBXC_INCLUDE_DIR_F03="${LIBXC_DIR}" \
  -DLIBXC_LIBRARIES="${LIBXC_DIR}/libxc.a" \
  -DLIBXC_LIBRARIES_F03="${LIBXC_DIR}/libxcf03.a" \
  -DLIBXC_ROOT="${LIBXC_DIR}"

cmake --build "${BUILD_DIR}" -j6 --target pw
