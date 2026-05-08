#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")"

cc_bin="${CC:-cc}"
nvcc_bin="${NVCC:-/usr/local/cuda/bin/nvcc}"
cuda_arch="${CUDA_ARCH:-sm_120}"

if ! command -v "$cc_bin" >/dev/null 2>&1; then
  echo "C compiler not found: $cc_bin" >&2
  echo "macOS: run 'xcode-select --install'" >&2
  echo "Ubuntu/Debian: run 'sudo apt install build-essential'" >&2
  exit 1
fi

"$cc_bin" -O3 -march=native -pthread rpow-native-miner.c -o rpow-native-miner
chmod +x rpow-native-miner

echo "Built ./rpow-native-miner"

if command -v "$nvcc_bin" > /dev/null 2>&1; then
  "$nvcc_bin" -O3 -std=c++17 -arch="$cuda_arch" rpow-gpu-miner.cu -o rpow-gpu-miner
  chmod +x rpow-gpu-miner
  echo "Built ./rpow-gpu-miner with CUDA_ARCH=$cuda_arch"
else
  echo "CUDA nvcc not found: $nvcc_bin; skipped GPU miner" >&2
fi

echo "Run CPU: node rpow-cli.js mine --count 1 --engine native"
echo "Run GPU: node rpow-cli.js mine --count 1 --engine gpu --workers 16"