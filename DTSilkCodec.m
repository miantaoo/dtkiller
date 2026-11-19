//
//  DTSilkCodec.m
//

#import "DTSilkCodec.h"
#import "DTLog.h"

#if __has_include("SKP_Silk_SDK_API.h")
#  define DT_HAVE_SILK 1
#  include "SKP_Silk_SDK_API.h"
#elif __has_include(<silk/SKP_Silk_SDK_API.h>)
#  define DT_HAVE_SILK 1
#  include <silk/SKP_Silk_SDK_API.h>
#else
#  define DT_HAVE_SILK 0
#endif

static const uint8_t kTencentPrefix[] = {0x02};
static const char    kSilkMagic[]     = "#!SILK_V3";
static const NSUInteger kMagicLen      = 9;
static const NSUInteger kHeaderLen     = 1 + 9;      // 0x02 + magic
static const int kSampleRate           = 24000;
static const int kFrameSamples         = 480;        // 20ms @24k

BOOL DTSilkAvailable(void) { return DT_HAVE_SILK ? YES : NO; }

#pragma mark - 头处理

NSData *DTSilkWrapTencent(NSData *rawFrames) {
    if (!rawFrames) return nil;
    NSMutableData *d = [NSMutableData dataWithCapacity:rawFrames.length + kHeaderLen];
    [d appendBytes:kTencentPrefix length:1];
    [d appendBytes:kSilkMagic length:kMagicLen];
    [d appendData:rawFrames];
    return d;
}

NSData *DTSilkStripHeader(NSData *any) {
    if (any.length < kHeaderLen) return any;
    const uint8_t *b = any.bytes;

    // 0x02 + "#!SILK_V3"
    if (b[0] == 0x02 && any.length > kHeaderLen &&
        memcmp(b + 1, kSilkMagic, kMagicLen) == 0) {
        return [any subdataWithRange:NSMakeRange(kHeaderLen, any.length - kHeaderLen)];
    }
    // "#!SILK_V3"
    if (any.length > kMagicLen && memcmp(b, kSilkMagic, kMagicLen) == 0) {
        return [any subdataWithRange:NSMakeRange(kMagicLen, any.length - kMagicLen)];
    }
    // "#!SILK\n" (v1)
    if (any.length > 7 && memcmp(b, "#!SILK\n", 7) == 0) {
        return [any subdataWithRange:NSMakeRange(7, any.length - 7)];
    }
    // "#!AMR\n" + 0x02 + "#!SILK_V3"
    if (any.length > 6 + kHeaderLen && memcmp(b, "#!AMR\n", 6) == 0 &&
        b[6] == 0x02 && memcmp(b + 7, kSilkMagic, kMagicLen) == 0) {
        return [any subdataWithRange:NSMakeRange(7 + kMagicLen, any.length - 7 - kMagicLen)];
    }
    return any;
}

BOOL DTSilkInspect(NSData *silk, NSUInteger *outFrames, NSUInteger *outBytes) {
    NSData *raw = DTSilkStripHeader(silk);
    if (raw.length < 2) return NO;
    const uint8_t *b = raw.bytes;
    NSUInteger off = 0, frames = 0;
    while (off + 2 <= raw.length) {
        uint16_t len = (uint16_t)(b[off] | (b[off + 1] << 8));   // 小端
        if (len == 0 || len > 250) break;                        // MAX_BYTES_PER_FRAME
        off += 2 + len;
        frames++;
        if (off > raw.length) return NO;
    }
    if (outFrames) *outFrames = frames;
    if (outBytes)  *outBytes  = raw.length;
    return frames > 0;
}

#pragma mark - 编解码

NSData *DTSilkEncodePCM(NSData *pcm, int bitrate) {
    if (!DT_HAVE_SILK) { DTLog(@"silkcodec: SDK not compiled in"); return nil; }
#if DT_HAVE_SILK
    if (pcm.length < kFrameSamples * 2) return nil;
    if (bitrate <= 0) bitrate = 25000;

    SKP_int32 encSize = 0;
    if (SKP_Silk_SDK_Get_Encoder_Size(&encSize) != 0 || encSize <= 0) {
        DTLog(@"silkcodec: Get_Encoder_Size failed");
        return nil;
    }
    void *enc = calloc(1, (size_t)encSize);
    if (!enc) return nil;

    SKP_SILK_SDK_EncControlStruct ctl;
    memset(&ctl, 0, sizeof(ctl));
    ctl.API_sampleRate        = kSampleRate;
    ctl.maxInternalSampleRate = kSampleRate;
    ctl.packetSize            = kFrameSamples;
    ctl.bitRate               = bitrate;
    ctl.complexity            = 2;
    ctl.useInBandFEC          = 0;
    ctl.useDTX                = 0;

    if (SKP_Silk_SDK_InitEncoder(enc, &ctl) != 0) {
        DTLog(@"silkcodec: InitEncoder failed");
        free(enc);
        return nil;
    }

    NSMutableData *frames = [NSMutableData data];
    const int16_t *p = pcm.bytes;
    NSUInteger total = pcm.length / 2;          // 样本数
    NSUInteger i = 0;
    uint8_t outBuf[250 * 5];
    while (i + kFrameSamples <= total) {
        SKP_int16 nBytes = 0;
        SKP_Silk_SDK_Encode(enc, &ctl, p + i, kFrameSamples, outBuf, &nBytes);
        if (nBytes > 0) {
            uint16_t le = (uint16_t)nBytes;
            uint8_t hdr[2] = { (uint8_t)(le & 0xFF), (uint8_t)(le >> 8) };
            [frames appendBytes:hdr length:2];
            [frames appendBytes:outBuf length:(NSUInteger)nBytes];
        }
        i += kFrameSamples;
    }
    free(enc);
    DTLog(@"silkcodec: encoded %lu frames", (unsigned long)(frames.length ? frames.length : 0));
    return frames.length ? DTSilkWrapTencent(frames) : nil;
#else
    return nil;
#endif
}

NSData *DTSilkDecode(NSData *silk) {
    if (!DT_HAVE_SILK) { DTLog(@"silkcodec: SDK not compiled in"); return nil; }
#if DT_HAVE_SILK
    NSData *raw = DTSilkStripHeader(silk);
    if (raw.length < 3) return nil;

    SKP_int32 decSize = 0;
    if (SKP_Silk_SDK_Get_Decoder_Size(&decSize) != 0 || decSize <= 0) return nil;
    void *dec = calloc(1, (size_t)decSize);
    if (!dec) return nil;
    if (SKP_Silk_SDK_InitDecoder(dec) != 0) { free(dec); return nil; }

    SKP_SILK_SDK_DecControlStruct dctl;
    memset(&dctl, 0, sizeof(dctl));
    dctl.API_sampleRate = kSampleRate;

    NSMutableData *pcm = [NSMutableData data];
    const uint8_t *b = raw.bytes;
    NSUInteger off = 0;
    int16_t out[480 * 5];

    while (off + 2 <= raw.length) {
        uint16_t len = (uint16_t)(b[off] | (b[off + 1] << 8));
        off += 2;
        if (len == 0 || off + len > raw.length) break;

        SKP_int16 nSamples = 0;
        SKP_Silk_SDK_Decode(dec, &dctl, 0, b + off, len, out, &nSamples);
        if (nSamples > 0) [pcm appendBytes:out length:(NSUInteger)nSamples * 2];
        off += len;
    }
    free(dec);
    DTLog(@"silkcodec: decoded %lu bytes pcm", (unsigned long)pcm.length);
    return pcm.length ? pcm : nil;
#else
    return nil;
#endif
}
