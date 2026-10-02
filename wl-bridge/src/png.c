/* Headless test output only: frames as PNG, from premultiplied BGRA. */
#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>
#include "ishwl.h"

static void write_chunk(FILE *f, const char *type, const uint8_t *data, uint32_t len) {
    uint32_t be = htonl(len);
    fwrite(&be, 4, 1, f);
    fwrite(type, 1, 4, f);
    if (len) fwrite(data, 1, len, f);
    uint32_t crc = crc32(0, (const uint8_t *) type, 4);
    if (len) crc = crc32(crc, data, len);
    be = htonl(crc);
    fwrite(&be, 4, 1, f);
}

int png_write(const char *path, const void *pixels, int32_t width, int32_t height, int32_t stride, bool has_alpha) {
    int channels = has_alpha ? 4 : 3;
    size_t row_bytes = (size_t) width * channels + 1;
    size_t raw_size = row_bytes * height;
    uint8_t *raw = malloc(raw_size);
    uLongf packed_size = compressBound(raw_size);
    uint8_t *packed = malloc(packed_size);
    if (!raw || !packed) {
        free(raw);
        free(packed);
        return -1;
    }
    for (int32_t y = 0; y < height; y++) {
        const uint8_t *src = (const uint8_t *) pixels + (size_t) y * stride;
        uint8_t *dst = raw + y * row_bytes;
        *dst++ = 0;
        for (int32_t x = 0; x < width; x++, src += 4) {
            uint8_t b = src[0], g = src[1], r = src[2], a = src[3];
            if (has_alpha && a && a != 255) {
                r = r * 255 / a;
                g = g * 255 / a;
                b = b * 255 / a;
            }
            *dst++ = r;
            *dst++ = g;
            *dst++ = b;
            if (has_alpha) *dst++ = a;
        }
    }
    int err = compress2(packed, &packed_size, raw, raw_size, 1);
    free(raw);
    if (err != Z_OK) {
        free(packed);
        return -1;
    }

    char tmp[512];
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    FILE *f = fopen(tmp, "wb");
    if (!f) {
        free(packed);
        return -1;
    }
    static const uint8_t signature[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
    fwrite(signature, 1, 8, f);
    uint8_t ihdr[13];
    uint32_t be = htonl(width);
    memcpy(ihdr, &be, 4);
    be = htonl(height);
    memcpy(ihdr + 4, &be, 4);
    ihdr[8] = 8;
    ihdr[9] = has_alpha ? 6 : 2;
    ihdr[10] = ihdr[11] = ihdr[12] = 0;
    write_chunk(f, "IHDR", ihdr, sizeof(ihdr));
    write_chunk(f, "IDAT", packed, packed_size);
    write_chunk(f, "IEND", NULL, 0);
    free(packed);
    if (fclose(f) != 0)
        return -1;
    return rename(tmp, path);
}
