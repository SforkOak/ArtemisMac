//
//  ColorConversion.c
//  Artemis
//

#include "ColorConversion.h"

ArtemisCscParams ArtemisMakeCscParams(int colorspace, bool fullRange, int bitDepth) {
    double kr, kb;
    switch (colorspace) {
        case ARTEMIS_COLORSPACE_REC_601:
            kr = 0.299;  kb = 0.114;
            break;
        case ARTEMIS_COLORSPACE_REC_2020:
            kr = 0.2627; kb = 0.0593;
            break;
        case ARTEMIS_COLORSPACE_REC_709:
        default:
            kr = 0.2126; kb = 0.0722;
            break;
    }
    double kg = 1.0 - kr - kb;

    // Size of one code value in normalized texture units. 10-bit P010 samples sit in the
    // top bits of 16-bit words.
    double unit = bitDepth > 8 ? 64.0 / 65535.0 : 1.0 / 255.0;
    int shift = bitDepth - 8;
    double yOffset, yRange, cOffset, cRange;
    if (fullRange) {
        yOffset = 0;
        yRange = ((1 << bitDepth) - 1) * unit;
        cOffset = (1 << (bitDepth - 1)) * unit;
        cRange = ((1 << bitDepth) - 1) * unit;
    } else {
        yOffset = (16 << shift) * unit;
        yRange = (219 << shift) * unit;
        cOffset = (128 << shift) * unit;
        cRange = (224 << shift) * unit;
    }
    double ys = 1.0 / yRange;
    double cs = 1.0 / cRange;

    ArtemisCscParams p;
    p.row0 = simd_make_float4(ys, 0.0, 2.0 * (1.0 - kr) * cs, 0.0);
    p.row1 = simd_make_float4(ys, -2.0 * kb * (1.0 - kb) / kg * cs, -2.0 * kr * (1.0 - kr) / kg * cs, 0.0);
    p.row2 = simd_make_float4(ys, 2.0 * (1.0 - kb) * cs, 0.0, 0.0);
    p.offsets = simd_make_float4(yOffset, cOffset, cOffset, 0.0);
    return p;
}
