#include "CWebP.h"
#include "src/webp/encode.h"

size_t mb_webp_encode_rgba(const uint8_t *rgba, int width, int height, int stride,
                           float quality, int lossless, uint8_t **output) {
    if (lossless) return WebPEncodeLosslessRGBA(rgba, width, height, stride, output);
    return WebPEncodeRGBA(rgba, width, height, stride, quality, output);
}

void mb_webp_free(void *pointer) { WebPFree(pointer); }
