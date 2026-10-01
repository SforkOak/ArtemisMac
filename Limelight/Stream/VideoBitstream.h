//
//  VideoBitstream.h
//  Artemis
//
//  Bitstream helpers for the video decoder, kept free of Objective-C so they can be
//  unit tested (see Tests/run-tests.sh).
//

#ifndef ArtemisVideoBitstream_h
#define ArtemisVideoBitstream_h

#include <stddef.h>
#include <stdint.h>

#define ARTEMIS_NAL_LENGTH_PREFIX_SIZE 4

// Converts Annex B NAL units (00 00 01 / 00 00 00 01 start codes) to 4-byte big-endian
// length-prefixed NAL units, as VideoToolbox expects for H.264 and HEVC. A 4-byte start
// code's leading zero ends up as a trailing zero of the previous NAL, which decoders
// ignore. Bytes before the first start code are dropped. Returns a malloc'd buffer the
// caller frees, or NULL on allocation failure.
uint8_t *ArtemisAnnexBToLengthPrefixed(const uint8_t *data, size_t length, size_t *outLength);

#endif
