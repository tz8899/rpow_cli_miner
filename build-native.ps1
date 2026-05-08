$ErrorActionPreference = "Stop"

Set-Location $PSScriptRoot

$gcc = Get-Command gcc -ErrorAction SilentlyContinue
if (-not $gcc) {
  Write-Error @"
gcc was not found.

Install MSYS2 from https://www.msys2.org/, open "MSYS2 MinGW x64", then run:
  pacman -S --needed mingw-w64-x86_64-gcc

After that, run this script again from PowerShell if gcc is available in PATH,
or build manually from the MSYS2 MinGW x64 shell:
  gcc -O3 -march=native -pthread rpow-native-miner.c -o rpow-native-miner.exe
"@
}

gcc -O3 -march=native -pthread rpow-native-miner.c -o rpow-native-miner.exe

Write-Host "Built .\rpow-native-miner.exe"

$nvcc = Get-Command nvcc -ErrorAction SilentlyContinue
if ($nvcc) {
  $cudaArch = $env:CUDA_ARCH
  if (-not $cudaArch) { $cudaArch = "sm_120" }
  & $nvcc.Source -O3 -std=c++17 "-arch=$cudaArch" rpow-gpu-miner.cu -o rpow-gpu-miner.exe
  Write-Host "Built .\rpow-gpu-miner.exe with CUDA_ARCH=$cudaArch"
} else {
  Write-Host "CUDA nvcc not found; skipped GPU miner build"
}

Write-Host "Run CPU: node rpow-cli.js mine --count 1 --engine native"
Write-Host "Run GPU: node rpow-cli.js mine --count 1 --engine gpu --workers 16"
