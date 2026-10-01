//
//  VideoBitstream.c
//  Artemis
//

#include "VideoBitstream.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static size_t AppendLengthPrefixedNal(uint8_t *out, size_t outPos, const uint8_t *nal, size_t nalLength) {
    out[outPos++] = (uint8_t)(nalLength >> 24);
    out[outPos++] = (uint8_t)(nalLength >> 16);
    out[outPos++] = (uint8_t)(nalLength >> 8);
    out[outPos++] = (uint8_t)nalLength;
    memcpy(&out[outPos], nal, nalLength);
    return outPos + nalLength;
}

uint8_t *ArtemisAnnexBToLengthPrefixed(const uint8_t *data, size_t length, size_t *outLength) {
    // Every 3-byte start code becomes a 4-byte length, so the output grows by at most one byte per NAL
    size_t nalCount = 0;
    for (size_t i = 0; i + 2 < length; i++) {
        if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
            nalCount++;
            i += 2;
        }
    }

    uint8_t *out = malloc(length + nalCount + ARTEMIS_NAL_LENGTH_PREFIX_SIZE);
    if (out == NULL) {
        return NULL;
    }

    // A 4-byte start code's leading zero ends up as a trailing zero of the previous NAL,
    // which decoders ignore (moonlight-ios does the same)
    size_t outPos = 0;
    size_t nalStart = SIZE_MAX;
    size_t i = 0;
    while (i + 2 < length) {
        if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
            if (nalStart != SIZE_MAX) {
                outPos = AppendLengthPrefixedNal(out, outPos, &data[nalStart], i - nalStart);
            }
            nalStart = i + 3;
            i += 3;
        } else {
            i++;
        }
    }
    if (nalStart != SIZE_MAX && nalStart < length) {
        outPos = AppendLengthPrefixedNal(out, outPos, &data[nalStart], length - nalStart);
    }

    *outLength = outPos;
    return out;
}
