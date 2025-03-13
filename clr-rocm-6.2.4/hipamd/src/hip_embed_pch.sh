#!/bin/bash
# Copyright (c) 2020 - 2022 Advanced Micro Devices, Inc. All rights reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

printUsage() {
  echo
  echo "Usage: $(basename "$0") HIP_BUILD_INC_DIR HIP_INC_DIR HIP_AMD_INC_DIR LLVM_DIR [option] [RTC_LIB_OUTPUT]"
  echo
  echo "Options:"
  echo "  -p,  --generate_pch  Generate pre-compiled header (default)"
  echo "  -r,  --generate_rtc  Generate preprocessor expansion (hiprtc_header.o)"
  echo "  -h,  --help          Prints this help"
  echo
  echo
  return 0
}

if [ "$1" == "" ]; then
  printUsage
  exit 0
fi

HIP_BUILD_INC_DIR="$1"
HIP_INC_DIR="$2"
HIP_AMD_INC_DIR="$3"
LLVM_DIR="$4"
# By default, generate pch
TARGET="generatepch"

while [ "$5" != "" ];
do
  case "$5" in
    -h | --help )
        printUsage ; exit 0 ;;
    -p | --generate_pch )
        TARGET="generatepch" ; break ;;
    -r | --generate_rtc )
        TARGET="generatertc" ; break ;;
    *)
        echo " UNEXPECTED ERROR Parm : [$4] ">&2 ; exit 20 ;;
  esac
  shift 1
done

# Allow hiprtc lib name to be set by argument 7
if [[ "$6" != "" ]]; then
  rtc_shared_lib_out="$6"
else
  if [[ "$OSTYPE" == cygwin ]]; then
    rtc_shared_lib_out=hiprtc-builtins64.dll
  else
    rtc_shared_lib_out=libhiprtc-builtins.so
  fi
fi

if [[ "$OSTYPE" == cygwin || "$OSTYPE" == msys ]]; then
  isWindows=1
  tmpdir=.
else
  isWindows=0
  tmpdir=/tmp
fi

# Expected first argument $1 to be output file name.
create_hip_macro_file() {
cat >$1 <<EOF
#define __device__ __attribute__((device))
#define __host__ __attribute__((host))
#define __global__ __attribute__((global))
#define __constant__ __attribute__((constant))
#define __shared__ __attribute__((shared))

#define launch_bounds_impl0(requiredMaxThreadsPerBlock)                                            \
    __attribute__((amdgpu_flat_work_group_size(1, requiredMaxThreadsPerBlock)))
#define launch_bounds_impl1(requiredMaxThreadsPerBlock, minBlocksPerMultiprocessor)                \
    __attribute__((amdgpu_flat_work_group_size(1, requiredMaxThreadsPerBlock),                     \
                   amdgpu_waves_per_eu(minBlocksPerMultiprocessor)))
#define select_impl_(_1, _2, impl_, ...) impl_
#define __launch_bounds__(...)                                                                     \
    select_impl_(__VA_ARGS__, launch_bounds_impl1, launch_bounds_impl0)(__VA_ARGS__)

EOF
}

generate_pch() {
  tmp=$tmpdir/hip_pch.$$
  mkdir -p $tmp

  create_hip_macro_file $tmp/hip_macros.h

cat >$tmp/hip_pch.h <<EOF
#include "hip/hip_runtime.h"
#include "hip/hip_fp16.h"
EOF

cat << EOF > $tmp/hip_pch.mcin
  .type __hip_pch_wave32,@object
EOF

  if [[ $isWindows -eq 0 ]]; then
cat << EOF >> $tmp/hip_pch.mcin
  .section .note.GNU-stack,"",@progbits
EOF
  fi

cat << EOF >> $tmp/hip_pch.mcin
  .section .hip_pch_wave32,"aMS",@progbits,1
  .data
  .globl __hip_pch_wave32
  .globl __hip_pch_wave32_size
  .p2align 3
__hip_pch_wave32:
  .incbin "$tmp/hip_wave32.pch"
__hip_pch_wave32_size:
  .long __hip_pch_wave32_size - __hip_pch_wave32
  .type __hip_pch_wave64,@object
  .section .hip_pch_wave64,"aMS",@progbits,1
  .data
  .globl __hip_pch_wave64
  .globl __hip_pch_wave64_size
  .p2align 3
__hip_pch_wave64:
  .incbin "$tmp/hip_wave64.pch"
__hip_pch_wave64_size:
  .long __hip_pch_wave64_size - __hip_pch_wave64
EOF

  set -x

  # For gfx10/Navi devices
  $LLVM_DIR/bin/clang -O3 --hip-path=$HIP_INC_DIR/.. -std=c++17 -nogpulib -isystem $HIP_INC_DIR -isystem $HIP_BUILD_INC_DIR -isystem $HIP_AMD_INC_DIR --cuda-device-only --cuda-gpu-arch=gfx1030 -x hip $tmp/hip_pch.h -E >$tmp/pch_wave32.cui &&

  cat $tmp/hip_macros.h >> $tmp/pch_wave32.cui &&

  $LLVM_DIR/bin/clang -cc1 -O3 -emit-pch -triple amdgcn-amd-amdhsa -aux-triple x86_64-unknown-linux-gnu -fcuda-is-device -std=c++17 -fgnuc-version=4.2.1 -o $tmp/hip_wave32.pch -x hip-cpp-output - <$tmp/pch_wave32.cui &&

  # For other devices
  $LLVM_DIR/bin/clang -O3 --hip-path=$HIP_INC_DIR/.. -std=c++17 -nogpulib -isystem $HIP_INC_DIR -isystem $HIP_BUILD_INC_DIR -isystem $HIP_AMD_INC_DIR --cuda-device-only -x hip $tmp/hip_pch.h -E >$tmp/pch_wave64.cui &&

  cat $tmp/hip_macros.h >> $tmp/pch_wave64.cui &&

  $LLVM_DIR/bin/clang -cc1 -O3 -emit-pch -triple amdgcn-amd-amdhsa -aux-triple x86_64-unknown-linux-gnu -fcuda-is-device -std=c++17 -fgnuc-version=4.2.1 -o $tmp/hip_wave64.pch -x hip-cpp-output - <$tmp/pch_wave64.cui &&

  $LLVM_DIR/bin/llvm-mc -o hip_pch.o $tmp/hip_pch.mcin --filetype=obj &&

  rm -rf $tmp
}

generate_rtc_header() {
  tmp=$tmpdir/hip_rtc.$$
  mkdir -p $tmp
  local macroFile="$tmp/hip_macros.h"
  local headerFile="$tmp/hipRTC_header.h"
  local mcinFile="$tmp/hipRTC_header.mcin"

  create_hip_macro_file $macroFile

cat >$headerFile <<EOF
#pragma push_macro("CHAR_BIT")
#pragma push_macro("INT_MAX")
#define CHAR_BIT __CHAR_BIT__
#define INT_MAX __INTMAX_MAX__

#include "hip/hip_runtime.h"
#include "hip/hip_fp16.h"

#pragma pop_macro("CHAR_BIT")
#pragma pop_macro("INT_MAX")
EOF

  echo "// Automatically generated script for HIP RTC." > $mcinFile
  if [[ $isWindows -eq 0 ]]; then
    echo "  .section .note.GNU-stack,"",@progbits" >> $mcinFile
    echo "  .type __hipRTC_header,@object" >> $mcinFile
    echo "  .type __hipRTC_header_size,@object" >> $mcinFile
  fi
cat >>$mcinFile <<EOF
  .section .hipRTC_header,"a"
  .globl __hipRTC_header
  .globl __hipRTC_header_size
  .p2align 3
__hipRTC_header:
  .incbin "$tmp/hiprtc"
__hipRTC_header_size:
  .long __hipRTC_header_size - __hipRTC_header
EOF

  set -x
  $LLVM_DIR/bin/clang -O3 --hip-path=$HIP_INC_DIR/.. -std=c++14 -nogpulib --hip-version=4.4 -isystem $HIP_INC_DIR -isystem $HIP_BUILD_INC_DIR -isystem $HIP_AMD_INC_DIR --cuda-device-only -D__HIPCC_RTC__ -x hip $tmp/hipRTC_header.h -E -P -o $tmp/hiprtc &&
  cat $macroFile >> $tmp/hiprtc &&
  $LLVM_DIR/bin/llvm-mc -o $tmp/hiprtc_header.o $tmp/hipRTC_header.mcin --filetype=obj &&
  $LLVM_DIR/bin/clang $tmp/hiprtc_header.o -o $rtc_shared_lib_out -shared &&
  $LLVM_DIR/bin/clang -O3 --hip-path=$HIP_INC_DIR/.. -std=c++14 -nogpulib -nogpuinc -emit-llvm -c -o $tmp/tmp.bc --cuda-device-only -D__HIPCC_RTC__ --offload-arch=gfx906 -x hip-cpp-output $tmp/hiprtc &&
  rm -rf $tmp
}

case $TARGET in
    (generatertc) generate_rtc_header ;;
    (generatepch) generate_pch ;;
    (*) die "Invalid target $TARGET" ;;
esac

