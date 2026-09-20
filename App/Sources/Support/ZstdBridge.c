#include <stdlib.h>
#include <string.h>

/* Declarations from the amalgamated zstd decoder. Kept here so the Swift
   bridging header does not include the decoder. */
typedef struct ZSTD_DCtx_s ZSTD_DCtx;
typedef struct { const void *src; size_t size; size_t pos; } ZSTD_inBuffer;
typedef struct { void *dst; size_t size; size_t pos; } ZSTD_outBuffer;

ZSTD_DCtx *ZSTD_createDCtx(void);
size_t ZSTD_decompressStream(ZSTD_DCtx *dctx, ZSTD_outBuffer *output, ZSTD_inBuffer *input);
void ZSTD_freeDCtx(ZSTD_DCtx *dctx);
unsigned ZSTD_isError(size_t code);

int AnkiZstdDecompress(const void *src, size_t srcSize, void **outPtr, size_t *outSize) {
    if (!src || !outPtr || !outSize || srcSize == 0) return 1;
    ZSTD_DCtx *ctx = ZSTD_createDCtx();
    if (!ctx) return 1;

    size_t cap = srcSize * 8;
    if (cap < 1 << 16) cap = 1 << 16;
    unsigned char *buf = malloc(cap);
    if (!buf) {
        ZSTD_freeDCtx(ctx);
        return 1;
    }

    ZSTD_inBuffer in = { src, srcSize, 0 };
    size_t produced = 0;
    while (in.pos < in.size) {
        if (cap - produced < 1 << 16) {
            size_t nextCap = cap * 2;
            unsigned char *next = realloc(buf, nextCap);
            if (!next) {
                free(buf);
                ZSTD_freeDCtx(ctx);
                return 1;
            }
            buf = next;
            cap = nextCap;
        }
        ZSTD_outBuffer out = { buf, cap, produced };
        size_t ret = ZSTD_decompressStream(ctx, &out, &in);
        produced = out.pos;
        if (ZSTD_isError(ret)) {
            free(buf);
            ZSTD_freeDCtx(ctx);
            return 2;
        }
        if (ret == 0) break;
    }

    ZSTD_freeDCtx(ctx);
    *outPtr = buf;
    *outSize = produced;
    return 0;
}

void AnkiZstdFree(void *ptr) {
    free(ptr);
}
