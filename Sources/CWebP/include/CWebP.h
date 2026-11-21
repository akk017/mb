#ifndef CWEBP_H
#define CWEBP_H
#include <stddef.h>
#include <stdint.h>

/// Encodes RGBA pixels to WebP (libwebp 1.4.0, vendored).
/// quality 0…100 (lossy) or lossless != 0. Returns the byte count and sets
/// *output (free with mb_webp_free); returns 0 on failure.
size_t mb_webp_encode_rgba(const uint8_t *rgba, int width, int height, int stride,
                           float quality, int lossless, uint8_t **output);
void mb_webp_free(void *pointer);

#endif
