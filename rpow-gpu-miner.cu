#include <cuda_runtime.h>

#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>

#ifdef _WIN32
#include <windows.h>
static uint64_t now_ms(void) {
  FILETIME ft;
  ULARGE_INTEGER uli;
  GetSystemTimeAsFileTime(&ft);
  uli.LowPart = ft.dwLowDateTime;
  uli.HighPart = ft.dwHighDateTime;
  return (uli.QuadPart / 10000ull) - 11644473600000ull;
}
#else
static uint64_t now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return (uint64_t)ts.tv_sec * 1000ull + (uint64_t)ts.tv_nsec / 1000000ull;
}
#endif

__constant__ uint8_t c_prefix[64];
__constant__ int c_prefix_len;
__constant__ int c_difficulty;

__device__ __constant__ uint32_t k256[64] = {
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};

__device__ __forceinline__ uint32_t rotr32(uint32_t x, int n) {
  return (x >> n) | (x << (32 - n));
}

__device__ __forceinline__ uint32_t ch(uint32_t x, uint32_t y, uint32_t z) {
  return (x & y) ^ (~x & z);
}

__device__ __forceinline__ uint32_t maj(uint32_t x, uint32_t y, uint32_t z) {
  return (x & y) ^ (x & z) ^ (y & z);
}

__device__ __forceinline__ uint32_t ep0(uint32_t x) {
  return rotr32(x, 2) ^ rotr32(x, 13) ^ rotr32(x, 22);
}

__device__ __forceinline__ uint32_t ep1(uint32_t x) {
  return rotr32(x, 6) ^ rotr32(x, 11) ^ rotr32(x, 25);
}

__device__ __forceinline__ uint32_t sig0(uint32_t x) {
  return rotr32(x, 7) ^ rotr32(x, 18) ^ (x >> 3);
}

__device__ __forceinline__ uint32_t sig1(uint32_t x) {
  return rotr32(x, 17) ^ rotr32(x, 19) ^ (x >> 10);
}

__device__ __forceinline__ uint8_t message_byte(uint64_t nonce, int pos, int total_blocks) {
  const int msg_len = c_prefix_len + 8;
  if (pos < c_prefix_len) return c_prefix[pos];
  if (pos < msg_len) return (uint8_t)((nonce >> ((pos - c_prefix_len) * 8)) & 0xffu);
  if (pos == msg_len) return 0x80u;
  const int len_start = total_blocks * 64 - 8;
  if (pos >= len_start) {
    const uint64_t bit_len = (uint64_t)msg_len * 8ull;
    return (uint8_t)((bit_len >> ((7 - (pos - len_start)) * 8)) & 0xffu);
  }
  return 0;
}

__device__ __forceinline__ uint32_t message_word(uint64_t nonce, int word_index, int block_start, int total_blocks) {
  const int pos = block_start + word_index * 4;
  return ((uint32_t)message_byte(nonce, pos, total_blocks) << 24)
    | ((uint32_t)message_byte(nonce, pos + 1, total_blocks) << 16)
    | ((uint32_t)message_byte(nonce, pos + 2, total_blocks) << 8)
    | ((uint32_t)message_byte(nonce, pos + 3, total_blocks));
}

__device__ __forceinline__ void sha256_block(uint32_t state[8], uint64_t nonce, int block_start, int total_blocks) {
  uint32_t w[16];
#pragma unroll
  for (int i = 0; i < 16; ++i) w[i] = message_word(nonce, i, block_start, total_blocks);

  uint32_t a = state[0], b = state[1], c = state[2], d = state[3];
  uint32_t e = state[4], f = state[5], g = state[6], h = state[7];

#pragma unroll
  for (int i = 0; i < 64; ++i) {
    uint32_t wi;
    if (i < 16) {
      wi = w[i];
    } else {
      wi = sig1(w[(i - 2) & 15]) + w[(i - 7) & 15] + sig0(w[(i - 15) & 15]) + w[i & 15];
      w[i & 15] = wi;
    }
    const uint32_t t1 = h + ep1(e) + ch(e, f, g) + k256[i] + wi;
    const uint32_t t2 = ep0(a) + maj(a, b, c);
    h = g;
    g = f;
    f = e;
    e = d + t1;
    d = c;
    c = b;
    b = a;
    a = t1 + t2;
  }

  state[0] += a; state[1] += b; state[2] += c; state[3] += d;
  state[4] += e; state[5] += f; state[6] += g; state[7] += h;
}

__device__ __forceinline__ void sha256_nonce(uint64_t nonce, uint32_t state[8]) {
  state[0] = 0x6a09e667; state[1] = 0xbb67ae85; state[2] = 0x3c6ef372; state[3] = 0xa54ff53a;
  state[4] = 0x510e527f; state[5] = 0x9b05688c; state[6] = 0x1f83d9ab; state[7] = 0x5be0cd19;
  const int msg_len = c_prefix_len + 8;
  const int total_blocks = msg_len <= 55 ? 1 : 2;
  sha256_block(state, nonce, 0, total_blocks);
  if (total_blocks == 2) sha256_block(state, nonce, 64, total_blocks);
}

__device__ __forceinline__ int trailing_zero_bits_state(const uint32_t state[8]) {
  int bits = 0;
#pragma unroll
  for (int i = 7; i >= 0; --i) {
    const uint32_t word = state[i];
    if (word == 0) {
      bits += 32;
    } else {
      return bits + (__ffs(word) - 1);
    }
  }
  return bits;
}

__device__ __forceinline__ void state_to_digest(const uint32_t state[8], uint8_t out[32]) {
#pragma unroll
  for (int i = 0; i < 8; ++i) {
    out[i * 4] = (uint8_t)(state[i] >> 24);
    out[i * 4 + 1] = (uint8_t)(state[i] >> 16);
    out[i * 4 + 2] = (uint8_t)(state[i] >> 8);
    out[i * 4 + 3] = (uint8_t)(state[i]);
  }
}

__global__ void mine_kernel(
  uint64_t base_nonce,
  uint64_t *found_nonce,
  unsigned long long *found_offset,
  int *found,
  uint8_t *found_digest,
  int rounds_per_thread
) {
  const uint64_t lane = (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;
  const uint64_t stride = (uint64_t)gridDim.x * blockDim.x;

  for (int round = 0; round < rounds_per_thread; ++round) {
    if (*found) return;
    const uint64_t offset = lane + (uint64_t)round * stride;
    const uint64_t nonce = base_nonce + offset;
    uint32_t state[8];
    sha256_nonce(nonce, state);
    if (trailing_zero_bits_state(state) >= c_difficulty) {
      if (atomicCAS(found, 0, 1) == 0) {
        *found_nonce = nonce;
        *found_offset = (unsigned long long)offset;
        state_to_digest(state, found_digest);
      }
      return;
    }
  }
}

static int hexval(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

static int parse_hex(const char *hex, uint8_t *out, size_t *out_len) {
  size_t n = strlen(hex);
  if (n % 2 || n / 2 > 64) return -1;
  for (size_t i = 0; i < n / 2; ++i) {
    int hi = hexval(hex[i * 2]);
    int lo = hexval(hex[i * 2 + 1]);
    if (hi < 0 || lo < 0) return -1;
    out[i] = (uint8_t)((hi << 4) | lo);
  }
  *out_len = n / 2;
  return 0;
}

static uint64_t parse_u64(const char *s) {
  errno = 0;
  uint64_t v = strtoull(s, NULL, 10);
  if (errno) {
    fprintf(stderr, "bad integer: %s\n", s);
    exit(2);
  }
  return v;
}

static void check_cuda(cudaError_t err, const char *what) {
  if (err != cudaSuccess) {
    fprintf(stderr, "%s: %s\n", what, cudaGetErrorString(err));
    exit(1);
  }
}

int main(int argc, char **argv) {
  uint8_t prefix[64] = {0};
  size_t prefix_len = 0;
  const char *prefix_hex = NULL;
  int difficulty = 0;
  int workers = 16;
  int device_id = 0;
  int local_size = 256;
  int rounds_per_thread = 128;
  int blocks_override = 0;
  uint64_t start_nonce = 0;
  uint64_t cutoff_ms = 0;
  uint64_t progress_ms = 1000;

  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--prefix") && i + 1 < argc) prefix_hex = argv[++i];
    else if (!strcmp(argv[i], "--difficulty") && i + 1 < argc) difficulty = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--workers") && i + 1 < argc) workers = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--device") && i + 1 < argc) device_id = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--local-size") && i + 1 < argc) local_size = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--rounds") && i + 1 < argc) rounds_per_thread = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--blocks") && i + 1 < argc) blocks_override = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--start") && i + 1 < argc) start_nonce = parse_u64(argv[++i]);
    else if (!strcmp(argv[i], "--cutoff-ms") && i + 1 < argc) cutoff_ms = parse_u64(argv[++i]);
    else if (!strcmp(argv[i], "--progress-ms") && i + 1 < argc) progress_ms = parse_u64(argv[++i]);
  }

  if (!prefix_hex || parse_hex(prefix_hex, prefix, &prefix_len) || difficulty <= 0) {
    fprintf(stderr, "usage: rpow-gpu-miner --prefix HEX --difficulty N [--workers N] [--device N] [--start N] [--cutoff-ms N]\n");
    return 2;
  }
  if (workers <= 0) workers = 16;
  if (local_size <= 0) local_size = 256;
  if (rounds_per_thread <= 0) rounds_per_thread = 128;

  int device_count = 0;
  check_cuda(cudaGetDeviceCount(&device_count), "cudaGetDeviceCount");
  if (device_id < 0 || device_id >= device_count) {
    fprintf(stderr, "bad CUDA device: %d (count=%d)\n", device_id, device_count);
    return 2;
  }
  check_cuda(cudaSetDevice(device_id), "cudaSetDevice");

  cudaDeviceProp prop{};
  check_cuda(cudaGetDeviceProperties(&prop, device_id), "cudaGetDeviceProperties");
  const int blocks = blocks_override > 0 ? blocks_override : prop.multiProcessorCount * workers;
  const uint64_t batch = (uint64_t)blocks * (uint64_t)local_size * (uint64_t)rounds_per_thread;

  check_cuda(cudaMemcpyToSymbol(c_prefix, prefix, 64), "cudaMemcpyToSymbol(prefix)");
  int prefix_len_i = (int)prefix_len;
  check_cuda(cudaMemcpyToSymbol(c_prefix_len, &prefix_len_i, sizeof(prefix_len_i)), "cudaMemcpyToSymbol(prefix_len)");
  check_cuda(cudaMemcpyToSymbol(c_difficulty, &difficulty, sizeof(difficulty)), "cudaMemcpyToSymbol(difficulty)");

  uint64_t *d_found_nonce = nullptr;
  unsigned long long *d_found_offset = nullptr;
  int *d_found = nullptr;
  uint8_t *d_found_digest = nullptr;
  check_cuda(cudaMalloc(&d_found_nonce, sizeof(uint64_t)), "cudaMalloc(found_nonce)");
  check_cuda(cudaMalloc(&d_found_offset, sizeof(unsigned long long)), "cudaMalloc(found_offset)");
  check_cuda(cudaMalloc(&d_found, sizeof(int)), "cudaMalloc(found)");
  check_cuda(cudaMalloc(&d_found_digest, 32), "cudaMalloc(found_digest)");

  uint64_t current = start_nonce;
  uint64_t total_hashes = 0;
  uint64_t started = now_ms();
  uint64_t last_progress = started;

  while (true) {
    if (cutoff_ms && now_ms() >= cutoff_ms) {
      printf("{\"type\":\"expired\",\"hashes\":\"%" PRIu64 "\"}\n", total_hashes);
      fflush(stdout);
      return 0;
    }

    int zero = 0;
    check_cuda(cudaMemcpy(d_found, &zero, sizeof(zero), cudaMemcpyHostToDevice), "cudaMemcpy(found=0)");
    mine_kernel<<<blocks, local_size>>>(current, d_found_nonce, d_found_offset, d_found, d_found_digest, rounds_per_thread);
    check_cuda(cudaGetLastError(), "mine_kernel launch");
    check_cuda(cudaDeviceSynchronize(), "mine_kernel sync");

    int found = 0;
    check_cuda(cudaMemcpy(&found, d_found, sizeof(found), cudaMemcpyDeviceToHost), "cudaMemcpy(found)");
    if (found) {
      uint64_t nonce = 0;
      unsigned long long offset = 0;
      uint8_t digest[32];
      check_cuda(cudaMemcpy(&nonce, d_found_nonce, sizeof(nonce), cudaMemcpyDeviceToHost), "cudaMemcpy(found_nonce)");
      check_cuda(cudaMemcpy(&offset, d_found_offset, sizeof(offset), cudaMemcpyDeviceToHost), "cudaMemcpy(found_offset)");
      check_cuda(cudaMemcpy(digest, d_found_digest, 32, cudaMemcpyDeviceToHost), "cudaMemcpy(found_digest)");
      total_hashes += (uint64_t)offset + 1ull;
      const double elapsed = (double)(now_ms() - started) / 1000.0;
      const double mhps = elapsed > 0.0 ? ((double)total_hashes / elapsed / 1000000.0) : 0.0;
      printf("{\"type\":\"found\",\"solution_nonce\":\"%" PRIu64 "\",\"hashes\":\"%" PRIu64 "\",\"digest\":\"", nonce, total_hashes);
      for (int i = 0; i < 32; ++i) printf("%02x", digest[i]);
      printf("\",\"speed\":\"%.2f MH/s\",\"device\":\"%s\",\"workers\":%d,\"local_size\":%d}\n", mhps, prop.name, workers, local_size);
      fflush(stdout);
      return 0;
    }

    total_hashes += batch;
    current += batch;
    const uint64_t now = now_ms();
    if (now - last_progress >= progress_ms) {
      const double elapsed = (double)(now - started) / 1000.0;
      const double mhps = elapsed > 0.0 ? ((double)total_hashes / elapsed / 1000000.0) : 0.0;
      printf("{\"type\":\"progress\",\"hashes\":\"%" PRIu64 "\",\"nonce\":\"%" PRIu64 "\",\"speed\":\"%.2f MH/s\",\"device\":\"%s\",\"workers\":%d,\"local_size\":%d}\n",
        total_hashes, current, mhps, prop.name, workers, local_size);
      fflush(stdout);
      last_progress = now;
    }
  }
}