//
//  VideoDecoderRenderer.m
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "VideoDecoderRenderer.h"
#import "MetalVideoPresenter.h"
#include "VideoBitstream.h"

#import <os/lock.h>
#import <simd/simd.h>
#include <stdatomic.h>

// FFmpeg's private CBS headers aren't written for -Wdocumentation
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include <libavcodec/avcodec.h>
#include <libavcodec/cbs.h>
#include <libavcodec/cbs_av1.h>
#include <libavformat/avio.h>
#include <libavutil/mem.h>
#pragma clang diagnostic pop

@import VideoToolbox;

// Private libavformat API for writing the AV1 Codec Configuration Box
extern int ff_isom_write_av1c(AVIOContext *pb, const uint8_t *buf, int size,
                              int write_seq_header);

// Frames in flight inside VideoToolbox are far fewer than this
#define TIMING_SLOTS 64
#define NAL_LENGTH_PREFIX_SIZE ARTEMIS_NAL_LENGTH_PREFIX_SIZE

static void DecompressionOutputCallback(void *decompressionOutputRefCon,
                                        void *sourceFrameRefCon,
                                        OSStatus status,
                                        VTDecodeInfoFlags infoFlags,
                                        CVImageBufferRef imageBuffer,
                                        CMTime presentationTimeStamp,
                                        CMTime presentationDuration);

@implementation VideoDecoderRenderer {
    MetalVideoPresenter *_presenter;
    BOOL _vsync;

    int _videoFormat;
    int _width;
    int _height;
    int _frameRate;

    // Only touched on moonlight-common-c's receive thread (and in cleanup, after it has exited)
    NSMutableArray<NSData *> *_parameterSets;
    CMVideoFormatDescriptionRef _formatDesc;
    VTDecompressionSessionRef _session;
    ArtemisFrameTiming _timings[TIMING_SLOTS];

    // HDR metadata comes from the control stream thread
    os_unfair_lock _hdrLock;
    NSData *_masteringDisplayColorVolume;
    NSData *_contentLightLevelInfo;

    atomic_bool _stopped;
}

- (instancetype)initWithView:(OSView *)view vsync:(BOOL)vsync {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _stats = [[VideoStats alloc] init];
    _presenter = [[MetalVideoPresenter alloc] initWithContainerView:view stats:_stats];
    if (_presenter == nil) {
        return nil;
    }
    _vsync = vsync;
    _parameterSets = [[NSMutableArray alloc] init];
    _hdrLock = OS_UNFAIR_LOCK_INIT;
    return self;
}

- (void)dealloc {
    [self cleanup];
}

- (void)setupWithVideoFormat:(int)videoFormat width:(int)width height:(int)height frameRate:(int)frameRate {
    _videoFormat = videoFormat;
    _width = width;
    _height = height;
    _frameRate = frameRate;
    [_stats reset];

    NSString *codec = (videoFormat & VIDEO_FORMAT_MASK_AV1) ? @"AV1" : ((videoFormat & VIDEO_FORMAT_MASK_H265) ? @"HEVC" : @"H.264");
    _stats.streamDescription = [NSString stringWithFormat:@"%@%@ %dx%d %d FPS", codec, (videoFormat & VIDEO_FORMAT_MASK_10BIT) ? @" 10-bit" : @"", width, height, frameRate];
    Log(LOG_I, @"Decoder setup: %@", _stats.streamDescription);

    // Debugging aid: `defaults write com.sforkoak.artemis.mac ArtemisFrameTraceDirectory <dir>`
    // writes a per-frame CSV for each stream into that directory
    NSString *traceDirectory = [NSUserDefaults.standardUserDefaults stringForKey:@"ArtemisFrameTraceDirectory"];
    if (traceDirectory.length > 0) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"yyyyMMdd-HHmmss";
        NSString *name = [NSString stringWithFormat:@"frames-%@-%dfps.csv", [formatter stringFromDate:[NSDate date]], frameRate];
        [_stats startTraceAtPath:[traceDirectory.stringByExpandingTildeInPath stringByAppendingPathComponent:name]];
    }
}

- (void)start {
    [_presenter startWithVideoSize:CGSizeMake(_width, _height)
                         frameRate:_frameRate
                             vsync:_vsync
                 defaultColorspace:COLORSPACE_REC_709];
}

- (void)stop {
    atomic_store(&_stopped, true);
    [_presenter stop];
}

- (void)cleanup {
    atomic_store(&_stopped, true);
    [self destroySession];
    if (_formatDesc != NULL) {
        CFRelease(_formatDesc);
        _formatDesc = NULL;
    }
    [_parameterSets removeAllObjects];
}


#pragma mark - Decoding

- (int)submitDecodeUnit:(PDECODE_UNIT)du {
    if (atomic_load(&_stopped)) {
        return DR_OK;
    }

    [_stats recordReceivedFrame:du->frameNumber];

    // Gather the picture data into one buffer, keeping parameter sets aside
    uint8_t *picData = malloc(du->fullLength);
    if (picData == NULL) {
        return DR_NEED_IDR;
    }
    size_t picLength = 0;
    for (PLENTRY entry = du->bufferList; entry != NULL; entry = entry->next) {
        if (entry->bufferType != BUFFER_TYPE_PICDATA) {
            if (du->frameType == FRAME_TYPE_IDR) {
                int startLength = entry->data[2] == 0x01 ? 3 : 4;
                [_parameterSets addObject:[NSData dataWithBytes:&entry->data[startLength] length:entry->length - startLength]];
            }
        } else {
            memcpy(&picData[picLength], entry->data, entry->length);
            picLength += entry->length;
        }
    }

    // Each IDR frame brings the parameter sets for a new format description
    if (du->frameType == FRAME_TYPE_IDR) {
        if (_formatDesc != NULL) {
            CFRelease(_formatDesc);
            _formatDesc = NULL;
        }
        _formatDesc = [self createFormatDescriptionWithIDRFrame:picData length:picLength];
        [_parameterSets removeAllObjects];
    }

    if (_formatDesc == NULL || ![self ensureDecompressionSession]) {
        free(picData);
        return DR_NEED_IDR;
    }

    // Wrap the frame for VideoToolbox. H.264/HEVC need length prefixes instead of start codes.
    uint8_t *sampleData = picData;
    size_t sampleLength = picLength;
    if (_videoFormat & (VIDEO_FORMAT_MASK_H264 | VIDEO_FORMAT_MASK_H265)) {
        sampleData = ArtemisAnnexBToLengthPrefixed(picData, picLength, &sampleLength);
        free(picData);
        if (sampleData == NULL) {
            return DR_NEED_IDR;
        }
    }

    CMBlockBufferRef blockBuffer = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, sampleData, sampleLength, kCFAllocatorMalloc,
                                                         NULL, 0, sampleLength, 0, &blockBuffer);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferCreateWithMemoryBlock failed: %d", (int)status);
        free(sampleData);
        return DR_NEED_IDR;
    }

    CMSampleBufferRef sampleBuffer = NULL;
    CMSampleTimingInfo sampleTiming = { kCMTimeInvalid, CMTimeMake(du->presentationTimeUs, 1000000), kCMTimeInvalid };
    status = CMSampleBufferCreateReady(kCFAllocatorDefault, blockBuffer, _formatDesc, 1, 1, &sampleTiming, 1, &sampleLength, &sampleBuffer);
    CFRelease(blockBuffer);
    if (status != noErr) {
        Log(LOG_E, @"CMSampleBufferCreateReady failed: %d", (int)status);
        return DR_NEED_IDR;
    }

    ArtemisFrameTiming *timing = &_timings[du->frameNumber % TIMING_SLOTS];
    timing->frameNumber = du->frameNumber;
    timing->hostProcessingLatency = du->frameHostProcessingLatency;
    timing->receiveTimeUs = du->receiveTimeUs;
    timing->enqueueTimeUs = du->enqueueTimeUs;
    timing->submitTimeUs = [VideoStats nowUs];
    timing->decodedTimeUs = 0;

    VTDecodeInfoFlags infoFlags = 0;
    status = VTDecompressionSessionDecodeFrame(_session, sampleBuffer, kVTDecodeFrame_EnableAsynchronousDecompression,
                                               (void *)(intptr_t)du->frameNumber, &infoFlags);
    CFRelease(sampleBuffer);

    if (status == kVTInvalidSessionErr) {
        // Happens after sleep/wake or GPU changes. Start over with a new session.
        Log(LOG_W, @"Decompression session became invalid; recreating it");
        [self destroySession];
        return DR_NEED_IDR;
    } else if (status != noErr) {
        Log(LOG_E, @"VTDecompressionSessionDecodeFrame failed: %d", (int)status);
        return DR_NEED_IDR;
    }

    return DR_OK;
}

// Runs on VideoToolbox's output thread
- (void)handleDecodedFrame:(int)frameNumber status:(OSStatus)status flags:(VTDecodeInfoFlags)infoFlags image:(CVImageBufferRef)image {
    if (status != noErr || image == NULL || (infoFlags & kVTDecodeInfo_FrameDropped)) {
        [_stats recordDecoderDrop];
        if (status != noErr) {
            Log(LOG_W, @"Decode failed for frame %d: %d", frameNumber, (int)status);
            LiRequestIdrFrame();
        }
        return;
    }

    ArtemisFrameTiming timing = _timings[frameNumber % TIMING_SLOTS];
    timing.decodedTimeUs = [VideoStats nowUs];
    [_stats recordDecodedFrame:&timing];

    if (!atomic_load(&_stopped)) {
        [_presenter submitFrame:image timing:&timing];
    }
}

static void DecompressionOutputCallback(void *decompressionOutputRefCon,
                                        void *sourceFrameRefCon,
                                        OSStatus status,
                                        VTDecodeInfoFlags infoFlags,
                                        CVImageBufferRef imageBuffer,
                                        CMTime presentationTimeStamp,
                                        CMTime presentationDuration) {
    VideoDecoderRenderer *renderer = (__bridge VideoDecoderRenderer *)decompressionOutputRefCon;
    [renderer handleDecodedFrame:(int)(intptr_t)sourceFrameRefCon status:status flags:infoFlags image:imageBuffer];
}

- (BOOL)ensureDecompressionSession {
    if (_session != NULL && VTDecompressionSessionCanAcceptFormatDescription(_session, _formatDesc)) {
        return YES;
    }
    [self destroySession];

    NSDictionary *decoderSpecification = @{
        (id)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @YES,
    };
    OSType pixelFormat = (_videoFormat & VIDEO_FORMAT_MASK_10BIT)
        ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    NSDictionary *imageAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat),
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    VTDecompressionOutputCallbackRecord callback = { DecompressionOutputCallback, (__bridge void *)self };

    OSStatus status = VTDecompressionSessionCreate(kCFAllocatorDefault, _formatDesc,
                                                   (__bridge CFDictionaryRef)decoderSpecification,
                                                   (__bridge CFDictionaryRef)imageAttributes,
                                                   &callback, &_session);
    if (status != noErr) {
        Log(LOG_E, @"VTDecompressionSessionCreate failed: %d", (int)status);
        _session = NULL;
        return NO;
    }

    // Decode each frame as fast as possible rather than just fast enough
    VTSessionSetProperty(_session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(_session, kVTDecompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse);
    return YES;
}

- (void)destroySession {
    if (_session != NULL) {
        VTDecompressionSessionWaitForAsynchronousFrames(_session);
        VTDecompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
}

#pragma mark - Format descriptions

- (CMVideoFormatDescriptionRef)createFormatDescriptionWithIDRFrame:(const uint8_t *)frameData length:(size_t)frameLength {
    CMVideoFormatDescriptionRef formatDesc = NULL;
    OSStatus status;

    if (_videoFormat & (VIDEO_FORMAT_MASK_H264 | VIDEO_FORMAT_MASK_H265)) {
        size_t count = _parameterSets.count;
        if (count == 0) {
            Log(LOG_E, @"IDR frame arrived without parameter sets");
            return NULL;
        }
        const uint8_t *pointers[count];
        size_t sizes[count];
        for (size_t i = 0; i < count; i++) {
            pointers[i] = _parameterSets[i].bytes;
            sizes[i] = _parameterSets[i].length;
        }

        if (_videoFormat & VIDEO_FORMAT_MASK_H264) {
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, count, pointers, sizes,
                                                                         NAL_LENGTH_PREFIX_SIZE, &formatDesc);
        } else {
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault, count, pointers, sizes,
                                                                         NAL_LENGTH_PREFIX_SIZE,
                                                                         (__bridge CFDictionaryRef)[self hdrFormatExtensions],
                                                                         &formatDesc);
        }
        if (status != noErr) {
            Log(LOG_E, @"Failed to create format description: %d", (int)status);
            return NULL;
        }
        return formatDesc;
    }

    if (_videoFormat & VIDEO_FORMAT_MASK_AV1) {
        return [self createAV1FormatDescriptionForIDRFrame:[NSData dataWithBytesNoCopy:(void *)frameData length:frameLength freeWhenDone:NO]];
    }

    Log(LOG_E, @"Unsupported video format: %x", _videoFormat);
    return NULL;
}

- (NSDictionary *)hdrFormatExtensions {
    NSMutableDictionary *extensions = [[NSMutableDictionary alloc] init];
    os_unfair_lock_lock(&_hdrLock);
    if (_contentLightLevelInfo != nil) {
        extensions[(__bridge NSString *)kCMFormatDescriptionExtension_ContentLightLevelInfo] = _contentLightLevelInfo;
    }
    if (_masteringDisplayColorVolume != nil) {
        extensions[(__bridge NSString *)kCMFormatDescriptionExtension_MasteringDisplayColorVolume] = _masteringDisplayColorVolume;
    }
    os_unfair_lock_unlock(&_hdrLock);
    return extensions;
}

- (NSData *)av1CodecConfigurationBoxForFrame:(NSData *)frameData {
    AVIOContext *ioctx = NULL;
    int err = avio_open_dyn_buf(&ioctx);
    if (err < 0) {
        Log(LOG_E, @"avio_open_dyn_buf() failed: %d", err);
        return nil;
    }

    // Submit the IDR frame to write the av1C blob
    err = ff_isom_write_av1c(ioctx, (uint8_t *)frameData.bytes, (int)frameData.length, 1);
    if (err < 0) {
        Log(LOG_E, @"ff_isom_write_av1c() failed: %d", err);
    }

    uint8_t *av1cBuf = NULL;
    int av1cBufLen = avio_close_dyn_buf(ioctx, &av1cBuf);
    NSData *data = (err >= 0 && av1cBufLen > 0) ? [NSData dataWithBytes:av1cBuf length:av1cBufLen] : nil;
    av_free(av1cBuf);
    return data;
}

// Ported from moonlight-ios, where much of this logic comes from Chrome
- (CMVideoFormatDescriptionRef)createAV1FormatDescriptionForIDRFrame:(NSData *)frameData {
    NSData *av1c = [self av1CodecConfigurationBoxForFrame:frameData];
    if (av1c == nil) {
        return NULL;
    }

    CodedBitstreamContext *cbsCtx = NULL;
    int err = ff_cbs_init(&cbsCtx, AV_CODEC_ID_AV1, NULL);
    if (err < 0) {
        Log(LOG_E, @"ff_cbs_init() failed: %d", err);
        return NULL;
    }

    AVPacket avPacket = {};
    avPacket.data = (uint8_t *)frameData.bytes;
    avPacket.size = (int)frameData.length;

    CodedBitstreamFragment cbsFrag = {};
    err = ff_cbs_read_packet(cbsCtx, &cbsFrag, &avPacket);
    if (err < 0) {
        Log(LOG_E, @"ff_cbs_read_packet() failed: %d", err);
        ff_cbs_close(&cbsCtx);
        return NULL;
    }

    CodedBitstreamAV1Context *bitstreamCtx = (CodedBitstreamAV1Context *)cbsCtx->priv_data;
    AV1RawSequenceHeader *seqHeader = bitstreamCtx->sequence_header;
    if (seqHeader == NULL) {
        Log(LOG_E, @"AV1 sequence header not found in IDR frame");
        ff_cbs_fragment_free(&cbsFrag);
        ff_cbs_close(&cbsCtx);
        return NULL;
    }

    NSMutableDictionary *extensions = [[self hdrFormatExtensions] mutableCopy];
#define SET_CFSTR_EXTENSION(key, value) extensions[(__bridge NSString *)key] = (__bridge NSString *)(value)
#define SET_EXTENSION(key, value) extensions[(__bridge NSString *)key] = (value)

    SET_EXTENSION(kCMFormatDescriptionExtension_FormatName, @"av01");
    // YUV without alpha, same as Chrome (https://developer.apple.com/library/archive/qa/qa1183/_index.html)
    SET_EXTENSION(kCMFormatDescriptionExtension_Depth, @24);

    switch (seqHeader->color_config.color_primaries) {
        case 1: // CP_BT_709
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2);
            break;
        case 6: // CP_BT_601
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionColorPrimaries_SMPTE_C);
            break;
        case 9: // CP_BT_2020
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionColorPrimaries_ITU_R_2020);
            break;
        default:
            Log(LOG_W, @"Unsupported color_primaries value: %d", seqHeader->color_config.color_primaries);
            break;
    }

    switch (seqHeader->color_config.transfer_characteristics) {
        case 1: // TC_BT_709
        case 6: // TC_BT_601
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionTransferFunction_ITU_R_709_2);
            break;
        case 7: // TC_SMPTE_240
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionTransferFunction_SMPTE_240M_1995);
            break;
        case 8: // TC_LINEAR
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionTransferFunction_Linear);
            break;
        case 14: // TC_BT_2020_10_BIT
        case 15: // TC_BT_2020_12_BIT
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionTransferFunction_ITU_R_2020);
            break;
        case 16: // TC_SMPTE_2084
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ);
            break;
        case 17: // TC_HLG
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG);
            break;
        default:
            Log(LOG_W, @"Unsupported transfer_characteristics value: %d", seqHeader->color_config.transfer_characteristics);
            break;
    }

    switch (seqHeader->color_config.matrix_coefficients) {
        case 1: // MC_BT_709
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2);
            break;
        case 6: // MC_BT_601
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4);
            break;
        case 7: // MC_SMPTE_240
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995);
            break;
        case 9: // MC_BT_2020_NCL
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_2020);
            break;
        default:
            Log(LOG_W, @"Unsupported matrix_coefficients value: %d", seqHeader->color_config.matrix_coefficients);
            break;
    }

    SET_EXTENSION(kCMFormatDescriptionExtension_FullRangeVideo, @(seqHeader->color_config.color_range == 1));
    // Progressive content
    SET_EXTENSION(kCMFormatDescriptionExtension_FieldCount, @(1));

    switch (seqHeader->color_config.chroma_sample_position) {
        case 1: // CSP_VERTICAL
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ChromaLocationTopField, kCMFormatDescriptionChromaLocation_Left);
            break;
        case 2: // CSP_COLOCATED
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ChromaLocationTopField, kCMFormatDescriptionChromaLocation_TopLeft);
            break;
        default:
            Log(LOG_W, @"Unsupported chroma_sample_position value: %d", seqHeader->color_config.chroma_sample_position);
            break;
    }

    // Chrome does the same for VP9:
    // https://source.chromium.org/chromium/chromium/src/+/main:media/gpu/mac/vt_config_util.mm;drc=977dc02c431b4979e34c7792bc3d646f649dacb4;l=155
    extensions[(__bridge NSString *)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = @{ @"av1C": av1c };
    extensions[@"BitsPerComponent"] = @(bitstreamCtx->bit_depth);

#undef SET_EXTENSION
#undef SET_CFSTR_EXTENSION

    CMVideoFormatDescriptionRef formatDesc = NULL;
    OSStatus status = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_AV1,
                                                     bitstreamCtx->frame_width, bitstreamCtx->frame_height,
                                                     (__bridge CFDictionaryRef)extensions, &formatDesc);
    if (status != noErr) {
        Log(LOG_E, @"Failed to create AV1 format description: %d", (int)status);
        formatDesc = NULL;
    }

    ff_cbs_fragment_free(&cbsFrag);
    ff_cbs_close(&cbsCtx);
    return formatDesc;
}


#pragma mark - HDR

// Called from the control stream thread when the host toggles HDR
- (void)setHdrMode:(BOOL)enabled {
    SS_HDR_METADATA hdrMetadata;
    BOOL hasMetadata = enabled && LiGetHdrMetadata(&hdrMetadata);
    BOOL metadataChanged = NO;

    NSData *newMdcv = nil;
    if (hasMetadata && hdrMetadata.displayPrimaries[0].x != 0 && hdrMetadata.maxDisplayLuminance != 0) {
        // This data is all in big-endian
        struct {
            vector_ushort2 primaries[3];
            vector_ushort2 white_point;
            uint32_t luminance_max;
            uint32_t luminance_min;
        } __attribute__((packed, aligned(4))) mdcv;

        // mdcv is in GBR order while SS_HDR_METADATA is in RGB order
        mdcv.primaries[0].x = __builtin_bswap16(hdrMetadata.displayPrimaries[1].x);
        mdcv.primaries[0].y = __builtin_bswap16(hdrMetadata.displayPrimaries[1].y);
        mdcv.primaries[1].x = __builtin_bswap16(hdrMetadata.displayPrimaries[2].x);
        mdcv.primaries[1].y = __builtin_bswap16(hdrMetadata.displayPrimaries[2].y);
        mdcv.primaries[2].x = __builtin_bswap16(hdrMetadata.displayPrimaries[0].x);
        mdcv.primaries[2].y = __builtin_bswap16(hdrMetadata.displayPrimaries[0].y);

        mdcv.white_point.x = __builtin_bswap16(hdrMetadata.whitePoint.x);
        mdcv.white_point.y = __builtin_bswap16(hdrMetadata.whitePoint.y);

        // These luminance values are in 10000ths of a nit
        mdcv.luminance_max = __builtin_bswap32((uint32_t)hdrMetadata.maxDisplayLuminance * 10000);
        mdcv.luminance_min = __builtin_bswap32(hdrMetadata.minDisplayLuminance);

        newMdcv = [NSData dataWithBytes:&mdcv length:sizeof(mdcv)];
    }

    NSData *newCll = nil;
    if (hasMetadata && hdrMetadata.maxContentLightLevel != 0 && hdrMetadata.maxFrameAverageLightLevel != 0) {
        // This data is all in big-endian
        struct {
            uint16_t max_content_light_level;
            uint16_t max_frame_average_light_level;
        } __attribute__((packed, aligned(2))) cll;

        cll.max_content_light_level = __builtin_bswap16(hdrMetadata.maxContentLightLevel);
        cll.max_frame_average_light_level = __builtin_bswap16(hdrMetadata.maxFrameAverageLightLevel);

        newCll = [NSData dataWithBytes:&cll length:sizeof(cll)];
    }

    os_unfair_lock_lock(&_hdrLock);
    if ((newMdcv == nil) != (_masteringDisplayColorVolume == nil) || (newMdcv != nil && ![newMdcv isEqualToData:_masteringDisplayColorVolume])) {
        _masteringDisplayColorVolume = newMdcv;
        metadataChanged = YES;
    }
    if ((newCll == nil) != (_contentLightLevelInfo == nil) || (newCll != nil && ![newCll isEqualToData:_contentLightLevelInfo])) {
        _contentLightLevelInfo = newCll;
        metadataChanged = YES;
    }
    os_unfair_lock_unlock(&_hdrLock);

    // Re-create the format description with the new metadata on the next IDR frame
    if (metadataChanged) {
        LiRequestIdrFrame();
    }
}

@end
