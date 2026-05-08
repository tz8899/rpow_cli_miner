#include <errno.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

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

typedef struct {
  uint8_t data[64];
  uint32_t datalen;
  uint64_t bitlen;
  uint32_t state[8];
} sha256_ctx;

static const uint32_t k[64] = {
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};

#define ROTR(a,b) (((a) >> (b)) | ((a) << (32-(b))))
#define CH(x,y,z) (((x) & (y)) ^ (~(x) & (z)))
#define MAJ(x,y,z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define EP0(x) (ROTR(x,2) ^ ROTR(x,13) ^ ROTR(x,22))
#define EP1(x) (ROTR(x,6) ^ ROTR(x,11) ^ ROTR(x,25))
#define SIG0(x) (ROTR(x,7) ^ ROTR(x,18) ^ ((x) >> 3))
#define SIG1(x) (ROTR(x,17) ^ ROTR(x,19) ^ ((x) >> 10))

static void sha256_transform(sha256_ctx *ctx, const uint8_t data[]) {
  uint32_t a,b,c,d,e,f,g,h,i,j,t1,t2,m[64];
  for (i = 0, j = 0; i < 16; ++i, j += 4)
    m[i] = ((uint32_t)data[j] << 24) | ((uint32_t)data[j+1] << 16) | ((uint32_t)data[j+2] << 8) | data[j+3];
  for (; i < 64; ++i) m[i] = SIG1(m[i-2]) + m[i-7] + SIG0(m[i-15]) + m[i-16];
  a=ctx->state[0]; b=ctx->state[1]; c=ctx->state[2]; d=ctx->state[3];
  e=ctx->state[4]; f=ctx->state[5]; g=ctx->state[6]; h=ctx->state[7];
  for (i = 0; i < 64; ++i) {
    t1 = h + EP1(e) + CH(e,f,g) + k[i] + m[i];
    t2 = EP0(a) + MAJ(a,b,c);
    h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
  }
  ctx->state[0]+=a; ctx->state[1]+=b; ctx->state[2]+=c; ctx->state[3]+=d;
  ctx->state[4]+=e; ctx->state[5]+=f; ctx->state[6]+=g; ctx->state[7]+=h;
}

static void sha256_init(sha256_ctx *ctx) {
  ctx->datalen = 0; ctx->bitlen = 0;
  ctx->state[0]=0x6a09e667; ctx->state[1]=0xbb67ae85; ctx->state[2]=0x3c6ef372; ctx->state[3]=0xa54ff53a;
  ctx->state[4]=0x510e527f; ctx->state[5]=0x9b05688c; ctx->state[6]=0x1f83d9ab; ctx->state[7]=0x5be0cd19;
}

static void sha256_update(sha256_ctx *ctx, const uint8_t data[], size_t len) {
  for (size_t i = 0; i < len; ++i) {
    ctx->data[ctx->datalen++] = data[i];
    if (ctx->datalen == 64) {
      sha256_transform(ctx, ctx->data);
      ctx->bitlen += 512;
      ctx->datalen = 0;
    }
  }
}

static void sha256_final(sha256_ctx *ctx, uint8_t hash[]) {
  uint32_t i = ctx->datalen;
  ctx->data[i++] = 0x80;
  if (ctx->datalen < 56) {
    while (i < 56) ctx->data[i++] = 0x00;
  } else {
    while (i < 64) ctx->data[i++] = 0x00;
    sha256_transform(ctx, ctx->data);
    memset(ctx->data, 0, 56);
  }
  ctx->bitlen += ctx->datalen * 8;
  ctx->data[63] = ctx->bitlen;
  ctx->data[62] = ctx->bitlen >> 8;
  ctx->data[61] = ctx->bitlen >> 16;
  ctx->data[60] = ctx->bitlen >> 24;
  ctx->data[59] = ctx->bitlen >> 32;
  ctx->data[58] = ctx->bitlen >> 40;
  ctx->data[57] = ctx->bitlen >> 48;
  ctx->data[56] = ctx->bitlen >> 56;
  sha256_transform(ctx, ctx->data);
  for (i = 0; i < 4; ++i) {
    hash[i]      = (ctx->state[0] >> (24 - i * 8)) & 0xff;
    hash[i + 4]  = (ctx->state[1] >> (24 - i * 8)) & 0xff;
    hash[i + 8]  = (ctx->state[2] >> (24 - i * 8)) & 0xff;
    hash[i + 12] = (ctx->state[3] >> (24 - i * 8)) & 0xff;
    hash[i + 16] = (ctx->state[4] >> (24 - i * 8)) & 0xff;
    hash[i + 20] = (ctx->state[5] >> (24 - i * 8)) & 0xff;
    hash[i + 24] = (ctx->state[6] >> (24 - i * 8)) & 0xff;
    hash[i + 28] = (ctx->state[7] >> (24 - i * 8)) & 0xff;
  }
}

typedef struct {
  uint8_t prefix[64];
  size_t prefix_len;
  int difficulty;
  int workers;
  uint64_t start_nonce;
  uint64_t stride;
  uint64_t cutoff_ms;
  atomic_uint_fast64_t *hashes;
  atomic_uint_fast64_t *nonces;
  atomic_int *done;
  atomic_int *expired;
  atomic_uint_fast64_t *solution;
  uint8_t *solution_hash;
} worker_arg;

static int trailing_zero_bits(const uint8_t hash[32]) {
  int bits = 0;
  for (int i = 31; i >= 0; --i) {
    uint8_t b = hash[i];
    if (b == 0) { bits += 8; continue; }
    for (int j = 0; j < 8; ++j) {
      if ((b & (1u << j)) == 0) bits++;
      else return bits;
    }
  }
  return bits;
}

static void nonce_le(uint64_t nonce, uint8_t out[8]) {
  for (int i = 0; i < 8; ++i) {
    out[i] = (uint8_t)(nonce & 0xffu);
    nonce >>= 8;
  }
}

static void *mine_thread(void *ptr) {
  worker_arg *a = (worker_arg *)ptr;
  uint8_t input[80], hash[32], nonce_bytes[8];
  memcpy(input, a->prefix, a->prefix_len);
  uint64_t nonce = a->start_nonce;
  uint64_t local_hashes = 0;
  while (!atomic_load(a->done)) {
    if (a->cutoff_ms && now_ms() >= a->cutoff_ms) {
      atomic_store(a->expired, 1);
      atomic_store(a->done, 1);
      break;
    }
    nonce_le(nonce, nonce_bytes);
    memcpy(input + a->prefix_len, nonce_bytes, 8);
    sha256_ctx ctx;
    sha256_init(&ctx);
    sha256_update(&ctx, input, a->prefix_len + 8);
    sha256_final(&ctx, hash);
    if (trailing_zero_bits(hash) >= a->difficulty) {
      if (!atomic_exchange(a->done, 1)) {
        atomic_store(a->solution, nonce);
        memcpy(a->solution_hash, hash, 32);
      }
      break;
    }
    nonce += a->stride;
    local_hashes++;
    if ((local_hashes & 0xffffu) == 0) {
      atomic_fetch_add(a->hashes, 0x10000u);
      atomic_store(a->nonces, nonce);
    }
  }
  atomic_fetch_add(a->hashes, local_hashes & 0xffffu);
  atomic_store(a->nonces, nonce);
  return NULL;
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
    int hi = hexval(hex[i * 2]), lo = hexval(hex[i * 2 + 1]);
    if (hi < 0 || lo < 0) return -1;
    out[i] = (uint8_t)((hi << 4) | lo);
  }
  *out_len = n / 2;
  return 0;
}

static uint64_t parse_u64(const char *s) {
  errno = 0;
  uint64_t v = strtoull(s, NULL, 10);
  if (errno) { fprintf(stderr, "bad integer: %s\n", s); exit(2); }
  return v;
}

int main(int argc, char **argv) {
  uint8_t prefix[64], solution_hash[32];
  size_t prefix_len = 0;
  const char *prefix_hex = NULL;
  int difficulty = 0, workers = 1;
  uint64_t start_nonce = 0, cutoff_ms = 0, progress_ms = 5000;

  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--prefix") && i + 1 < argc) prefix_hex = argv[++i];
    else if (!strcmp(argv[i], "--difficulty") && i + 1 < argc) difficulty = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--workers") && i + 1 < argc) workers = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--start") && i + 1 < argc) start_nonce = parse_u64(argv[++i]);
    else if (!strcmp(argv[i], "--cutoff-ms") && i + 1 < argc) cutoff_ms = parse_u64(argv[++i]);
    else if (!strcmp(argv[i], "--progress-ms") && i + 1 < argc) progress_ms = parse_u64(argv[++i]);
  }
  if (!prefix_hex || parse_hex(prefix_hex, prefix, &prefix_len) || difficulty <= 0 || workers <= 0 || workers > 2048) {
    fprintf(stderr, "usage: rpow-native-miner --prefix HEX --difficulty N --workers N [--start N] [--cutoff-ms N]\n");
    return 2;
  }

  pthread_t *threads = calloc((size_t)workers, sizeof(*threads));
  worker_arg *args = calloc((size_t)workers, sizeof(*args));
  atomic_uint_fast64_t *hashes = calloc((size_t)workers, sizeof(*hashes));
  atomic_uint_fast64_t *nonces = calloc((size_t)workers, sizeof(*nonces));
  atomic_int done = 0, expired = 0;
  atomic_uint_fast64_t solution = 0;

  uint64_t started = now_ms(), last = started;
  for (int i = 0; i < workers; ++i) {
    memcpy(args[i].prefix, prefix, prefix_len);
    args[i].prefix_len = prefix_len;
    args[i].difficulty = difficulty;
    args[i].workers = workers;
    args[i].start_nonce = start_nonce + (uint64_t)i;
    args[i].stride = (uint64_t)workers;
    args[i].cutoff_ms = cutoff_ms;
    args[i].hashes = &hashes[i];
    args[i].nonces = &nonces[i];
    args[i].done = &done;
    args[i].expired = &expired;
    args[i].solution = &solution;
    args[i].solution_hash = solution_hash;
    atomic_store(&nonces[i], args[i].start_nonce);
    pthread_create(&threads[i], NULL, mine_thread, &args[i]);
  }

  while (!atomic_load(&done)) {
#ifdef _WIN32
    Sleep(100);
#else
    struct timespec ts = {0, 100000000};
    nanosleep(&ts, NULL);
#endif
    uint64_t now = now_ms();
    if (now - last >= progress_ms) {
      uint64_t total = 0, max_nonce = 0;
      for (int i = 0; i < workers; ++i) {
        total += atomic_load(&hashes[i]);
        uint64_t n = atomic_load(&nonces[i]);
        if (n > max_nonce) max_nonce = n;
      }
      printf("{\"type\":\"progress\",\"hashes\":\"%" PRIu64 "\",\"nonce\":\"%" PRIu64 "\"}\n", total, max_nonce);
      fflush(stdout);
      last = now;
    }
  }

  for (int i = 0; i < workers; ++i) pthread_join(threads[i], NULL);
  uint64_t total = 0;
  for (int i = 0; i < workers; ++i) total += atomic_load(&hashes[i]);

  if (atomic_load(&expired)) {
    printf("{\"type\":\"expired\",\"hashes\":\"%" PRIu64 "\"}\n", total);
  } else {
    printf("{\"type\":\"found\",\"solution_nonce\":\"%" PRIu64 "\",\"hashes\":\"%" PRIu64 "\",\"digest\":\"", atomic_load(&solution), total);
    for (int i = 0; i < 32; ++i) printf("%02x", solution_hash[i]);
    printf("\"}\n");
  }
  fflush(stdout);
  free(threads); free(args); free(hashes); free(nonces);
  return 0;
}
