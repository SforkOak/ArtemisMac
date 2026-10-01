//
//  ColorConversion.h
//  Artemis
//
//  Y'CbCr -> RGB conversion parameters for the video shader, kept free of Objective-C
//  so they can be unit tested (see Tests/run-tests.sh).
//

#ifndef ArtemisColorConversion_h
#define ArtemisColorConversion_h

#include <stdbool.h>
#include <simd/simd.h>

// Same values as moonlight-common-c's COLORSPACE_* constants
#define ARTEMIS_COLORSPACE_REC_601  0
#define ARTEMIS_COLORSPACE_REC_709  1
#define ARTEMIS_COLORSPACE_REC_2020 2

// Must match CscParams in MetalVideoPresenter's shader source
typedef struct {
    simd_float4 row0;     // R = dot(row0.xyz, yuv - offsets)
    simd_float4 row1;     // G
    simd_float4 row2;     // B
    simd_float4 offsets;  // xyz: Y, Cb, Cr offsets in normalized texture units
} ArtemisCscParams;

// Parameters for a colorspace, range and bit depth, as sampled from an R8/RG8 texture
// (8-bit) or an MSB-aligned R16/RG16 texture (10-bit P010)
ArtemisCscParams ArtemisMakeCscParams(int colorspace, bool fullRange, int bitDepth);

#endif
