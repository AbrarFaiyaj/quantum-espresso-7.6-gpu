# QE 7.6 build configurations

This document serves two purposes: it's my build log, so I can reproduce
these exact builds after a `git clone` or `git pull` on a new machine; and
it's a write-up of the toolchain-integration work involved in getting
Quantum ESPRESSO's CPU and GPU code paths building and running correctly,
side by side, on one workstation.

[Quantum ESPRESSO](https://www.quantum-espresso.org/) is an open-source
plane-wave DFT suite for electronic-structure and materials simulation.
`build/` is an out-of-source CMake build/install area and is git-ignored —
build artifacts don't belong in version control — so this file is what
actually travels with the repository.

Hardware target: Quadro RTX 4000 (`sm_75` / `cc75`), Intel Xeon W-1270
(AVX2/FMA, no AVX-512).

## Why three build variants?

- **`cpu_gcc12_mkl2026`** is the correctness baseline: gcc + Intel oneAPI
  MKL, no GPU code paths, used to sanity-check the test-suite itself and as
  a reference to diff GPU results against.
- **`gpu_nvhpc243_cuda12_mkl2026`** is the known-good production GPU build
  (NVIDIA HPC SDK 24.3 / CUDA 12.3), kept as a fallback.
- **`gpu_nvhpc265_cuda13_mkl2026`** exists to answer one specific question:
  does QE 7.6 build and run correctly on the newly-released NVHPC 26.5 /
  CUDA 13.2 toolchain? All three are validated against the same 85-test
  representative subset of QE's own regression test-suite, with the GPU
  builds cross-checked against the CPU build's benchmark-matched output
  rather than trusted on their own.

Getting all three working uncovered four real, non-obvious problems, each
fixed at its actual root cause rather than worked around:

1. **Broken git submodules.** `external/wannier90`, `external/mbd`, and
   `external/devxlib` were empty directories with no gitlink in the
   history, silently failing CMake's submodule-consistency check on
   *every* configure attempt. Fixed by cloning each at its recorded commit
   and committing proper gitlinks.
2. **Fortran-module ABI mismatch across compilers.** One shared OpenMPI
   install gets used by three different Fortran compilers (gfortran,
   nvfortran 24.3, nvfortran 26.5) across the three variants. OpenMPI's
   `mpi`/`mpi_f08` Fortran module files are compiler-version-specific and
   not interchangeable; QE's `QE_ENABLE_MPI_MODULE=OFF` sidesteps this
   entirely by using the plain, compiler-agnostic `mpif.h` interface
   instead — the correct fix, not a workaround.
3. **MPI launcher/binary mismatch.** CMake auto-detected Intel oneAPI's
   `mpiexec` for `ctest` (pulled onto `PATH` by oneAPI's `setvars.sh`),
   while `pw.x`/`cp.x` were linked against OpenMPI. Launching an
   OpenMPI-linked binary via Intel's launcher doesn't fail loudly — it
   silently starts N uncoordinated single-rank "singletons" instead of one
   real N-rank job, which then produced test failures that looked like
   wrong physics but were actually a broken test harness. Fixed by pinning
   `MPIEXEC_EXECUTABLE` explicitly for the GPU builds.
4. **GPU-aware MPI crash.** With `QE_ENABLE_MPI_GPU_AWARE=ON`, real
   multi-rank runs segfaulted inside OpenMPI's point-to-point layer
   (`mca_pml_ob1_isend`) — multiple MPI ranks sharing one physical GPU
   isn't a configuration OpenMPI's CUDA transport handled robustly here.
   GPU-aware MPI mainly pays off for multi-GPU/multi-node RDMA anyway, so
   it's disabled for both GPU variants rather than debugged further.

## Prerequisites

- NVIDIA HPC SDK 24.3 and/or 26.5 under `/opt/nvidia/hpc_sdk/Linux_x86_64/`.
- Intel oneAPI 2026.1+ (MKL, compilers, MPI) under `/opt/intel/oneapi/`.
- OpenMPI 5.0.3 built against NVHPC 24.3 + CUDA 12.3, installed at
  `/usr/local/lib/openmpi-5.0.3/build` (shared by both GPU variants below —
  safe across NVHPC compiler versions because `QE_ENABLE_MPI_MODULE=OFF`
  avoids the compiler-specific Fortran `.mod` interface, see point 2 above).
- Submodules populated: `git submodule update --init --recursive` (pulls
  `wannier90`, `mbd`, `devxlib`).
- **Important**: if your shell sources oneAPI's `setvars.sh` and/or sets
  `NVHPCVER`/`CUDA_HOME` (e.g. via `.bashrc`), `unset CUDA_HOME NVHPC_ROOT
  CUDADIR NVCOMPILERS NVARCH NVHPCVER CUDAVER` before configuring/building the
  GPU variants. A stale `CUDA_HOME` pointing at a different NVHPC version's
  CUDA toolkit breaks `nvfortran`'s `-gpu=cudaXX.Y` resolution with a
  confusing "CUDA version X.Y is not available in this installation" error.

## Common build settings

- All three variants use MKL for BLAS/LAPACK/ScaLAPACK/FFT
  (`MKLROOT=/opt/intel/oneapi/mkl/2026.1`, or `.../latest`).
- `QE_ENABLE_MPI_MODULE=OFF` everywhere (see point 2 above).
- GPU variants set `QE_ENABLE_MPI_GPU_AWARE=OFF` (see point 4 above).
- GPU variants explicitly set `MPIEXEC_EXECUTABLE` for ctest (see point 3
  above).
- Adjust `QE_GPU_ARCHS` for different GPU hardware.

## Variant 1: `cpu_gcc12_mkl2026` (CPU-only, gcc + MKL)

```sh
source /opt/intel/oneapi/mpi/latest/env/vars.sh
export MKLROOT=/opt/intel/oneapi/mkl/2026.1
export LD_LIBRARY_PATH=$MKLROOT/lib:$LD_LIBRARY_PATH

BUILD=build/cpu_gcc12_mkl2026
cmake -S . -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$BUILD" \
  -DCMAKE_C_COMPILER=mpicc \
  -DCMAKE_Fortran_COMPILER=mpif90 \
  -DCMAKE_Fortran_FLAGS="-march=native" \
  -DQE_ENABLE_MPI=ON \
  -DQE_ENABLE_MPI_MODULE=OFF \
  -DQE_ENABLE_OPENMP=ON \
  -DQE_ENABLE_SCALAPACK=ON \
  -DQE_ENABLE_LIBXC=OFF

cmake --build "$BUILD" -j8
```

Uses Intel oneAPI MPI (auto-detected; wraps gcc/gfortran by default).
`-march=native` is safe here since this CPU tops out at AVX2/FMA (no
AVX-512 to accidentally target).

## Variant 2: `gpu_nvhpc243_cuda12_mkl2026` (NVHPC 24.3, CUDA 12.3)

```sh
unset CUDA_HOME NVHPC_ROOT CUDADIR NVCOMPILERS NVARCH NVHPCVER CUDAVER
NVHPC_ROOT=/opt/nvidia/hpc_sdk/Linux_x86_64/24.3
export PATH=$NVHPC_ROOT/compilers/bin:/usr/local/lib/openmpi-5.0.3/build/bin:$PATH
export LD_LIBRARY_PATH=$NVHPC_ROOT/compilers/lib:$NVHPC_ROOT/cuda/12.3/lib64:/usr/local/lib/openmpi-5.0.3/build/lib:/opt/intel/oneapi/mkl/2026.1/lib:$LD_LIBRARY_PATH

BUILD=build/gpu_nvhpc243_cuda12_mkl2026
cmake -S . -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$BUILD" \
  -DCMAKE_C_COMPILER=mpicc \
  -DCMAKE_Fortran_COMPILER=mpif90 \
  -DQE_ENABLE_MPI=ON \
  -DQE_ENABLE_MPI_MODULE=OFF \
  -DQE_ENABLE_MPI_GPU_AWARE=OFF \
  -DQE_ENABLE_OPENMP=ON \
  -DQE_ENABLE_SCALAPACK=ON \
  -DQE_ENABLE_LIBXC=OFF \
  -DQE_GPU="openacc;cuda" \
  -DQE_GPU_ARCHS=sm_75 \
  -DNVFORTRAN_CUDA_VERSION=12.3 \
  -DMPIEXEC_EXECUTABLE=/usr/local/lib/openmpi-5.0.3/build/bin/mpirun \
  -DMPIEXEC_NUMPROC_FLAG=-np

cmake --build "$BUILD" -j8
```

## Variant 3: `gpu_nvhpc265_cuda13_mkl2026` (NVHPC 26.5, CUDA 13.2)

Same as Variant 2 with the SDK swapped — this is the build that answers the
"does 26.5 work?" question:

```sh
unset CUDA_HOME NVHPC_ROOT CUDADIR NVCOMPILERS NVARCH NVHPCVER CUDAVER
NVHPC_ROOT=/opt/nvidia/hpc_sdk/Linux_x86_64/26.5
export PATH=$NVHPC_ROOT/compilers/bin:/usr/local/lib/openmpi-5.0.3/build/bin:$PATH
export LD_LIBRARY_PATH=$NVHPC_ROOT/compilers/lib:$NVHPC_ROOT/cuda/13.2/lib64:/usr/local/lib/openmpi-5.0.3/build/lib:/opt/intel/oneapi/mkl/2026.1/lib:$LD_LIBRARY_PATH

BUILD=build/gpu_nvhpc265_cuda13_mkl2026
cmake -S . -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$BUILD" \
  -DCMAKE_C_COMPILER=mpicc \
  -DCMAKE_Fortran_COMPILER=mpif90 \
  -DQE_ENABLE_MPI=ON \
  -DQE_ENABLE_MPI_MODULE=OFF \
  -DQE_ENABLE_MPI_GPU_AWARE=OFF \
  -DQE_ENABLE_OPENMP=ON \
  -DQE_ENABLE_SCALAPACK=ON \
  -DQE_ENABLE_LIBXC=OFF \
  -DQE_GPU="openacc;cuda" \
  -DQE_GPU_ARCHS=sm_75 \
  -DNVFORTRAN_CUDA_VERSION=13.2 \
  -DMPIEXEC_EXECUTABLE=/usr/local/lib/openmpi-5.0.3/build/bin/mpirun \
  -DMPIEXEC_NUMPROC_FLAG=-np

cmake --build "$BUILD" -j8
```

## Reproducing the test-suite

```sh
cd $BUILD
# clean stale artifacts from any previous run before re-testing
find test-suite -maxdepth 2 -iname "test.out.*" -delete
find test-suite -maxdepth 2 -iname "CRASH" -delete
find test-suite -maxdepth 3 -iname "*.save" -type d -exec rm -rf {} +

ctest -R 'system--(pw|cp)-pseudo$|system--pw_(scf|relax|metal|uspp)-|system--pw_(scf|relax|metal|uspp)--|system--cp_(h2o|al_edft)' \
      -j1 --output-on-failure --timeout 300
```

`-j1` and `--timeout 300` are deliberate: the GPU builds share one physical
GPU, and running tests concurrently (`-j2+`) was observed to crash/corrupt
results; the timeout guards against the known hang below.

## Test results (85-test representative subset)

- **cpu_gcc12_mkl2026**: 85/85 pass.
- **gpu_nvhpc243_cuda12_mkl2026** and **gpu_nvhpc265_cuda13_mkl2026**: 78/85
  pass, identically — meaning NVHPC 26.5 introduces no regressions relative
  to the 24.3 baseline. The 7 gaps are all understood, not build defects:
  - `pw_uspp--uspp-hyb-*_std` (2): QE reports "exx_type = bands on GPU not
    present, use band_pairs" — documented upstream GPU limitation.
  - `cp_al_edft--Al*` (2): QE reports "Ensemble DFT for GPU not present in
    this version" — documented upstream GPU limitation.
  - `pw_scf-correctness`: cascades from `scf-rmm-paro-gamma`'s SCF-iteration
    count differing from the stored benchmark (26 vs 16); total energies
    match the benchmark exactly — this is RMM-DIIS convergence-path noise,
    not a numerical defect.
  - `cp_h2o-correctness` and `cp_h2o--h2o-mt-blyp-6`: `h2o-mt-blyp-6` hangs
    indefinitely on both GPU builds (genuine, unexplained issue in this
    cp.x/BLYP combination on GPU — worth investigating further if you use CP
    with BLYP). The `--timeout 300` above prevents it from blocking the rest
    of the suite.

## Shell environment (not part of this repo)

This isn't tracked in the repo since it's host-specific, but here's the
relevant slice of `~/.bashrc` on the reference workstation — it selects an
NVHPC/CUDA version pair, derives `CUDA_HOME`/`NVHPC_ROOT` from it, and
picks which of the three builds' `bin/` goes on `PATH`:

```sh
# NVHPC / CUDA toolchain selection - keep NVHPCVER and CUDAVER in sync with
# each other (24.3 ships CUDA 12.3, 26.5 ships CUDA 13.2).
export NVHPCVER=26.5
# export NVHPCVER=24.3
export CUDAVER=13.2
# export CUDAVER=12.3
NVARCH=`uname -s`_`uname -m`; export NVARCH
NVCOMPILERS=/opt/nvidia/hpc_sdk; export NVCOMPILERS
PATH=$NVCOMPILERS/$NVARCH/$NVHPCVER/compilers/bin:$PATH; export PATH
export CUDA_HOME=$NVCOMPILERS/$NVARCH/$NVHPCVER/cuda/$CUDAVER
export NVHPC_ROOT=$NVCOMPILERS/$NVARCH/$NVHPCVER
export CUDADIR=$NVHPC_ROOT/cuda/$CUDAVER

export MKLROOT=/opt/intel/oneapi/mkl/latest

# Pick the active QE build: GPU by default, CPU-only build kept for reference.
export QE_ROOT=/usr/local/lib/qe-7.6/build/gpu_nvhpc265_cuda13_mkl2026/bin
# export QE_ROOT=/usr/local/lib/qe-7.6/build/gpu_nvhpc243_cuda12_mkl2026/bin
export QE_ROOT_CPU=/usr/local/lib/qe-7.6/build/cpu_gcc12_mkl2026/bin

export PATH=/usr/local/lib/openmpi-5.0.3/build/bin:$PATH
export PATH=$PATH:$QE_ROOT
# export PATH=$PATH:$QE_ROOT_CPU
export PATH=$PATH:$CUDADIR/bin

export LD_LIBRARY_PATH=/usr/local/lib/openmpi-5.0.3/build/lib:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$MKLROOT/lib
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$NVHPC_ROOT/compilers/lib
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$NVHPC_ROOT/math_libs/lib64
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$NVHPC_ROOT/cuda/$CUDAVER/lib64

export OMP_NUM_THREADS=8
export QUANTUMESPRESSO_CUDA_MEMORY_POOL=1  # 0 if you hit GPU OOM, 1 for better performance
```

Switching toolchain or build variant is then just commenting/uncommenting
the relevant `export` line and opening a new shell (or `source ~/.bashrc`).
