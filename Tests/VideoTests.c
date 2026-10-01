//
//  VideoTests.c
//  Artemis
//
//  Unit tests for the plain-C parts of the video path. Run Tests/run-tests.sh.
//

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "VideoBitstream.h"
#include "ColorConversion.h"

static int failures;

#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void expectConversion(const char *name, const uint8_t *input, size_t inputLength, const uint8_t *expected, size_t expectedLength) {
    size_t outLength = 0;
    uint8_t *out = ArtemisAnnexBToLengthPrefixed(input, inputLength, &outLength);
    CHECK(out != NULL, "%s: allocation failed", name);
    CHECK(outLength == expectedLength, "%s: length %zu, expected %zu", name, outLength, expectedLength);
    if (out != NULL && outLength == expectedLength) {
        CHECK(memcmp(out, expected, expectedLength) == 0, "%s: bytes differ", name);
    }
    free(out);
}

static void testAnnexB(void) {
    {
        const uint8_t in[] = {0, 0, 1, 0xAA, 0xBB, 0, 0, 1, 0xCC};
        const uint8_t want[] = {0, 0, 0, 2, 0xAA, 0xBB, 0, 0, 0, 1, 0xCC};
        expectConversion("two 3-byte start codes", in, sizeof(in), want, sizeof(want));
    }
    {
        // The leading zero of a 4-byte start code stays as a trailing zero of the previous NAL
        const uint8_t in[] = {0, 0, 0, 1, 0xAA, 0, 0, 0, 1, 0xBB};
        const uint8_t want[] = {0, 0, 0, 2, 0xAA, 0, 0, 0, 0, 1, 0xBB};
        expectConversion("4-byte start codes", in, sizeof(in), want, sizeof(want));
    }
    {
        // A start code in the last four bytes must not lose the final NAL
        const uint8_t in[] = {0, 0, 1, 0xAA, 0, 0, 1, 0xBB};
        const uint8_t want[] = {0, 0, 0, 1, 0xAA, 0, 0, 0, 1, 0xBB};
        expectConversion("start code near the end", in, sizeof(in), want, sizeof(want));
    }
    {
        const uint8_t in[] = {0x12, 0x34, 0x56};
        expectConversion("no start code", in, sizeof(in), (const uint8_t *)"", 0);
    }
    {
        const uint8_t in[] = {0, 0, 1};
        expectConversion("start code only", in, sizeof(in), (const uint8_t *)"", 0);
    }
}

static simd_float3 convert(ArtemisCscParams p, float y, float cb, float cr) {
    simd_float3 yuv = simd_make_float3(y, cb, cr) - p.offsets.xyz;
    return simd_make_float3(simd_dot(yuv, p.row0.xyz), simd_dot(yuv, p.row1.xyz), simd_dot(yuv, p.row2.xyz));
}

static void expectRgb(const char *name, simd_float3 rgb, float r, float g, float b) {
    const float tolerance = 0.01f;
    CHECK(fabsf(rgb.x - r) < tolerance && fabsf(rgb.y - g) < tolerance && fabsf(rgb.z - b) < tolerance,
          "%s: got (%.3f, %.3f, %.3f), expected (%.3f, %.3f, %.3f)", name, rgb.x, rgb.y, rgb.z, r, g, b);
}

static void testColorConversion(void) {
    ArtemisCscParams rec709 = ArtemisMakeCscParams(ARTEMIS_COLORSPACE_REC_709, false, 8);
    expectRgb("709 limited black", convert(rec709, 16 / 255.0f, 128 / 255.0f, 128 / 255.0f), 0, 0, 0);
    expectRgb("709 limited white", convert(rec709, 235 / 255.0f, 128 / 255.0f, 128 / 255.0f), 1, 1, 1);
    // BT.709 limited-range code values for the primaries
    expectRgb("709 limited red", convert(rec709, 63 / 255.0f, 102 / 255.0f, 240 / 255.0f), 1, 0, 0);
    expectRgb("709 limited green", convert(rec709, 173 / 255.0f, 42 / 255.0f, 26 / 255.0f), 0, 1, 0);
    expectRgb("709 limited blue", convert(rec709, 32 / 255.0f, 240 / 255.0f, 118 / 255.0f), 0, 0, 1);

    ArtemisCscParams full709 = ArtemisMakeCscParams(ARTEMIS_COLORSPACE_REC_709, true, 8);
    expectRgb("709 full white", convert(full709, 1, 128 / 255.0f, 128 / 255.0f), 1, 1, 1);
    expectRgb("709 full black", convert(full709, 0, 128 / 255.0f, 128 / 255.0f), 0, 0, 0);

    // P010: 10-bit code values in the top bits of 16-bit samples
    ArtemisCscParams p010 = ArtemisMakeCscParams(ARTEMIS_COLORSPACE_REC_2020, false, 10);
    float unit = 64.0f / 65535.0f;
    expectRgb("2020 10-bit black", convert(p010, 64 * unit, 512 * unit, 512 * unit), 0, 0, 0);
    expectRgb("2020 10-bit white", convert(p010, 940 * unit, 512 * unit, 512 * unit), 1, 1, 1);
}

int main(void) {
    testAnnexB();
    testColorConversion();
    if (failures == 0) {
        printf("All video tests passed\n");
    }
    return failures == 0 ? 0 : 1;
}
