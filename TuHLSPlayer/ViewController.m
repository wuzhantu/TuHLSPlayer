//
//  ViewController.m
//  TuHLSPlayer
//
//  Created by zhantu wu on 2026/9/21.
//
//  ============================================================
//  学习目标：搞清「本地 TS → 能在屏幕上画出的一帧视频」整条链路
//  ============================================================
//
//  一层套一层的封装（从外到里）：
//
//    TS 包 (188 字节)
//      └─ PES 包（可跨多个 TS 包）
//           └─ ES 字节流（H.264 Annex-B：起始码 + NAL + 起始码 + NAL ...）
//                └─ 若干 NAL 组成一帧（Access Unit）
//                     └─ 转成 AVCC，做成 CMSampleBuffer
//                          └─ 交给 AVSampleBufferDisplayLayer 显示
//
//  本文件故意拆成三步，先全部收齐再播，方便对照原理：
//    1) collectPesPackets —— TS → 一个个完整 PES（payload + 可选 PTS）
//    2) buildFrames       —— 按 HLSPlayer：有 PTS 就更新 _pesPts，再切 NAL 组帧
//    3) playFrames        —— 按 PTS 把帧送进显示层
//
//  PTS 规则（和 HLSPlayer 一样）：
//    遇到带 PTS 的 PES → 更新 _pesPts
//    新 Access Unit 开始 → 把当前 _pesPts 记到这一帧上
//

#import "ViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

static const NSUInteger kTSPacketSize = 188;

/// 已经准备好、可以直接送显的一帧
@interface TuFrame : NSObject
@property (nonatomic, copy) NSData *avcc;   // AVCC：每个 NAL 前面带 4 字节大端长度
@property (nonatomic, assign) int64_t ptsUs; // 这一帧该在什么时候显示（微秒）
@property (nonatomic, assign) BOOL isIDR;    // 是否关键帧（解码可从这里重新开始）
@end

@implementation TuFrame
@end

/// 一个完整 PES（对应 HLSPlayer 的 HLSPacket）
/// PTS 跟着这个包走，不再用「ES 偏移 → PTS」回查
@interface TuPesPacket : NSObject
@property (nonatomic, copy) NSData *payload; // 剥掉 PES 头之后的 ES 片段
@property (nonatomic, assign) BOOL hasPts;
@property (nonatomic, assign) int64_t ptsUs;
@end

@implementation TuPesPacket
@end

/// H.264 NAL 第一个字节的低 5 位是 type：
/// 1=普通片, 5=IDR, 7=SPS, 8=PPS, 9=AUD（一帧的边界标记）
static uint8_t HLSNALType(NSData *nal) {
    if (nal.length == 0) {
        return 0;
    }
    return ((const uint8_t *)nal.bytes)[0] & 0x1F;
}

/// Annex-B 用起始码分隔 NAL；iOS 硬解/显示层要的是 AVCC：
/// [4 字节大端 length][NAL 本体][4 字节 length][NAL 本体]...
static void HLSAppendAVCC(NSMutableData *avcc, NSData *nal) {
    uint32_t nlen = CFSwapInt32HostToBig((uint32_t)nal.length);
    [avcc appendBytes:&nlen length:4];
    [avcc appendData:nal];
}

@implementation ViewController {
    AVSampleBufferDisplayLayer *_displayLayer; // 专门显示 CMSampleBuffer 的图层
    CMVideoFormatDescriptionRef _formatDesc;   // 用 SPS/PPS 建好的 H.264 格式描述
    CMTimebaseRef _timebase;                   // 显示时钟：告诉图层「现在播到哪了」

    NSMutableArray<TuPesPacket *> *_pesPackets; // ① 收齐的视频 PES 列表
    NSMutableData *_esBuffer;                   // ② 组帧时临时拼接的 ES（和 HLSPlayer 一样边推边切）

    NSData *_sps;                              // 序列参数集
    NSData *_pps;                              // 图像参数集
    NSMutableArray<NSData *> *_currentAU;      // 正在组装的一帧（若干 NAL）
    NSMutableArray<TuFrame *> *_frames;        // 全部收齐后的帧列表

    int64_t _currentAUPts;                     // 当前这帧的 PTS
    int64_t _pesPts;                           // sticky：最近一次 PES 带来的 PTS
    BOOL _currentAUHasVCL;                     // 当前帧是否已有图像数据（type 1/5）
    BOOL _currentAUIsIDR;
    BOOL _started;
}

- (void)dealloc {
    if (_formatDesc) {
        CFRelease(_formatDesc);
    }
    if (_timebase) {
        CFRelease(_timebase);
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    _pesPackets = [NSMutableArray array];
    _esBuffer = [NSMutableData data];
    _currentAU = [NSMutableArray array];
    _frames = [NSMutableArray array];
    _currentAUPts = -1;
    _pesPts = -1;

    // 显示层本身不会解码文件，只负责按时间把我们已经做好的 CMSampleBuffer 画出来
    _displayLayer = [AVSampleBufferDisplayLayer layer];
    _displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    _displayLayer.frame = self.view.bounds;
    _displayLayer.backgroundColor = UIColor.blackColor.CGColor;
    [self.view.layer addSublayer:_displayLayer];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _displayLayer.frame = self.view.bounds;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_started) {
        return;
    }
    _started = YES;

    // ---------- 总流程：先收齐，再播放 ----------
    [self collectPesPackets]; // ① TS → 完整 PES 列表（每个可带 PTS）
    [self buildFrames];       // ② 逐个 PES：更新 _pesPts → 切 NAL → 组帧
    NSLog(@"[HLS] collected %lu frames", (unsigned long)_frames.count);

    // 显示层内部队列大约只能先吞 ~1 秒数据。
    // 若在主线程里硬塞满再 sleep，主线程画不了画面，看起来就像卡死。
    // 所以「按顺序往里送」放到后台，满了就等，主线程继续刷新 UI。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self playFrames]; // ③ _frames → CMSampleBuffer → 屏幕
    });
}

#pragma mark - ① collectPesPackets：TS → 完整 PES（payload 带着 PTS）

/*
 一个 TS 包固定 188 字节：

   [0]     sync = 0x47
   [1..2]  标志位 + PID（本样例里 257=视频, 258=音频）
   [3]     adaptation_field_control 等
   [4..]   可选 adaptation field，然后才是 payload

 视频 payload 里装的是 PES 碎片：
   - pusi=1：payload 开头是新的 PES 头（含 PTS），后面才是 ES
   - pusi=0：整段 payload 都是上一个 PES 的 ES 续传

 这一步只做「拆外壳、按 PES 收齐」。每个 TuPesPacket 自带 PTS，
 不切 NAL、不组帧、不送显。
 */
- (void)collectPesPackets {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"fileSequence5" ofType:@"ts"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSUInteger length = data.length;
    const uint8_t *bytes = data.bytes;
    if (!bytes) {
        return;
    }

    NSMutableData *current = nil;
    BOOL hasPts = NO;
    int64_t ptsUs = 0;

    int offset = 0;
    while (offset + kTSPacketSize <= length) {
        const uint8_t *pkt = bytes + offset;
        offset += kTSPacketSize;

        // 同步字节：不是 0x47 就跳过（正常文件里每 188 字节一个）
        if (pkt[0] != 0x47) {
            continue;
        }

        // PUSI=1 表示「这里开始一个新的 PES」
        BOOL pusi = (pkt[1] & 0x40) != 0;
        // PID 区分音视频等流；学习样例写死 257
        int pid = ((pkt[1] & 0x1F) << 8) | pkt[2];
        if (pid != 257) {
            continue;
        }

        // adaptation_field_control:
        //   01 = 只有 payload
        //   10 = 只有 AF（无 payload，跳过）
        //   11 = AF + payload
        int afc = (pkt[3] >> 4) & 0x03;
        int payloadOffset = 4;
        if (afc == 2 || afc == 3) {
            // AF 第一个字节是后面还有多少字节；总 AF 长度 = 1 + 该值
            payloadOffset = 5 + pkt[4];
        }
        if (!(afc & 0x01) || payloadOffset >= kTSPacketSize) {
            continue; // 没有 payload
        }

        const uint8_t *payload = pkt + payloadOffset;
        NSUInteger payloadSize = kTSPacketSize - payloadOffset;

        if (!pusi) {
            // 续传：整段 payload 都接到当前 PES 上
            if (current) {
                [current appendBytes:payload length:payloadSize];
            }
            continue;
        }

        // 新 PES 开始：先把上一个收口
        [self finishPes:current hasPts:hasPts ptsUs:ptsUs];
        current = nil;
        hasPts = NO;
        ptsUs = 0;

        // PES 头最小形态：00 00 01 | stream_id | packet_len(2) | flags...(3) | header_data_len
        // 真正的 ES 从 9 + header_data_len 开始
        if (payloadSize < 9 || payload[0] != 0x00 || payload[1] != 0x00 || payload[2] != 0x01) {
            continue;
        }
        uint8_t headerDataLength = payload[8];
        NSUInteger headerSize = 9 + headerDataLength;
        if (headerSize > payloadSize) {
            continue;
        }

        // PTS 在可选字段里：时钟 90kHz，跟着这个 PES 走
        int ptsDtsFlags = (payload[7] >> 6) & 0x03;
        if ((ptsDtsFlags & 0x02) && payload[8] >= 5) {
            const uint8_t *p = payload + 9;
            int64_t pts = ((int64_t)(p[0] & 0x0E) << 29)
                | ((int64_t)p[1] << 22)
                | ((int64_t)(p[2] & 0xFE) << 14)
                | ((int64_t)p[3] << 7)
                | ((int64_t)(p[4] & 0xFE) >> 1);
            hasPts = YES;
            ptsUs = pts * 1000000LL / 90000LL; // 90kHz → 微秒，和 CMTime 一致
        }

        current = [NSMutableData data];
        if (headerSize < payloadSize) {
            [current appendBytes:payload + headerSize length:payloadSize - headerSize];
        }
    }
    [self finishPes:current hasPts:hasPts ptsUs:ptsUs];
}

- (void)finishPes:(NSMutableData *)data hasPts:(BOOL)hasPts ptsUs:(int64_t)ptsUs {
    if (data.length == 0) {
        return;
    }
    TuPesPacket *packet = [TuPesPacket new];
    packet.payload = data;
    packet.hasPts = hasPts;
    packet.ptsUs = ptsUs;
    [_pesPackets addObject:packet];
}

#pragma mark - ② buildFrames：逐个 PES 更新 _pesPts，再切 NAL 组帧

/*
 和 HLSPlayer 的 pushPacket 一样：

   if (packet.hasPts) _pesPts = packet.ptsUs;
   把 payload 拼进 _esBuffer，切出完整 NAL，交给 handleNAL

 新 Access Unit 的第一个 NAL 把当前 _pesPts 记到这一帧上。
 不按 ES 偏移回查 PTS。

 一个「帧」(Access Unit) 通常包含多个 NAL，例如：
   AUD(9) + SEI(6) + SPS(7) + PPS(8) + IDR切片(5)

 收口规则（本文件采用的简化版）：
   - 遇到新的 AUD(9)，说明上一帧结束
   - 或者已经有图像数据后，又来了新的 SPS/PPS，也收口上一帧
 */
- (void)buildFrames {
    for (TuPesPacket *packet in _pesPackets) {
        [self pushPacket:packet];
    }
    // 文件结束：把还没切完的尾巴当成最后一个 NAL，再收口最后一帧
    if (_esBuffer.length > 4) {
        const uint8_t *p = _esBuffer.bytes;
        NSInteger codeLen = 0;
        NSInteger start = [self findStartCode:p from:0 length:(NSInteger)_esBuffer.length codeLen:&codeLen];
        if (start >= 0 && start + codeLen < (NSInteger)_esBuffer.length) {
            NSData *tail = [_esBuffer subdataWithRange:NSMakeRange((NSUInteger)(start + codeLen), _esBuffer.length - (NSUInteger)(start + codeLen))];
            [self handleNAL:tail];
        }
        [_esBuffer setLength:0];
    }
    [self emitCurrentAU];
}

/// 对应 HLSPlayer 的 pushPacket：有 PTS 就更新 sticky _pesPts，再切完整 NAL
- (void)pushPacket:(TuPesPacket *)packet {
    if (packet.hasPts) {
        _pesPts = packet.ptsUs;
    }
    [_esBuffer appendData:packet.payload];
    for (NSData *nal in [self popCompleteNALs]) {
        [self handleNAL:nal];
    }
}

/// 从 _esBuffer 里弹出「已经被下一个起始码封口」的 NAL；最后一个不完整的留在 buffer 里
- (NSArray<NSData *> *)popCompleteNALs {
    NSMutableArray<NSData *> *nals = [NSMutableArray array];
    const uint8_t *p = _esBuffer.bytes;
    NSInteger length = (NSInteger)_esBuffer.length;
    NSInteger codeLen = 0;
    NSInteger start = [self findStartCode:p from:0 length:length codeLen:&codeLen];
    if (start < 0) {
        return nals;
    }

    NSInteger pos = start;
    NSInteger posCodeLen = codeLen;
    while (1) {
        NSInteger nalStart = pos + posCodeLen;
        NSInteger nextCodeLen = 0;
        NSInteger next = [self findStartCode:p from:nalStart length:length codeLen:&nextCodeLen];
        if (next < 0) {
            // 还没看到下一个起始码，这段先留着；丢掉前面已经弹出的部分
            if (pos > 0) {
                [_esBuffer replaceBytesInRange:NSMakeRange(0, (NSUInteger)pos) withBytes:NULL length:0];
            }
            return nals;
        }
        if (next > nalStart) {
            [nals addObject:[NSData dataWithBytes:p + nalStart length:(NSUInteger)(next - nalStart)]];
        }
        pos = next;
        posCodeLen = nextCodeLen;
    }
}

- (void)handleNAL:(NSData *)nal {
    uint8_t type = HLSNALType(nal);
    if (type == 0) {
        return;
    }

    // SPS/PPS 用来建立解码器格式（分辨率、profile 等）；没有它们无法创建 formatDesc
    if (type == 7) {
        _sps = [nal copy];
        [self ensureFormat];
    } else if (type == 8) {
        _pps = [nal copy];
        [self ensureFormat];
    }

    // 边界到了 → 先把上一帧封好放进 _frames
    BOOL startNewAU = (type == 9 && _currentAU.count > 0)
        || ((type == 7 || type == 8) && _currentAUHasVCL);
    if (startNewAU) {
        [self emitCurrentAU];
    }

    // 新帧的第一个 NAL：把当前 PES 的 PTS 记到这一帧上
    if (_currentAU.count == 0) {
        _currentAUPts = _pesPts;
    }
    [_currentAU addObject:nal];

    // type 1/5 才是真正的图像切片；只有 AUD/SEI 的“空帧”后面会被丢掉
    if (type == 1 || type == 5) {
        _currentAUHasVCL = YES;
        _currentAUIsIDR = _currentAUIsIDR || (type == 5);
    }
}

/// 把 _currentAU 里的 NAL 收成一帧：转 AVCC，推入 _frames（还不送显）
- (void)emitCurrentAU {
    if (!_currentAUHasVCL || _currentAU.count == 0 || ![self ensureFormat]) {
        [self resetCurrentAU];
        return;
    }

    NSArray<NSData *> *nals = [_currentAU copy];
    int64_t ptsUs = _currentAUPts >= 0 ? _currentAUPts : MAX(_pesPts, 0);
    BOOL isIDR = _currentAUIsIDR;
    [self resetCurrentAU];

    BOOL hasSPS = NO;
    BOOL hasPPS = NO;
    for (NSData *nal in nals) {
        uint8_t type = HLSNALType(nal);
        hasSPS = hasSPS || type == 7;
        hasPPS = hasPPS || type == 8;
    }

    NSMutableData *avcc = [NSMutableData data];
    // 关键帧前确保带上 SPS/PPS，解码器才能从这一帧独立起解
    if (isIDR) {
        if (!hasSPS && _sps) {
            HLSAppendAVCC(avcc, _sps);
        }
        if (!hasPPS && _pps) {
            HLSAppendAVCC(avcc, _pps);
        }
    }
    for (NSData *nal in nals) {
        // AUD 只用于分帧边界，不送进解码器
        if (HLSNALType(nal) != 9) {
            HLSAppendAVCC(avcc, nal);
        }
    }
    if (avcc.length == 0) {
        return;
    }

    TuFrame *frame = [TuFrame new];
    frame.avcc = avcc;
    frame.ptsUs = ptsUs;
    frame.isIDR = isIDR;
    [_frames addObject:frame];
}

#pragma mark - ③ playFrames：把收齐的帧按顺序送进显示层

- (void)playFrames {
    if (_frames.count == 0 || !_formatDesc) {
        return;
    }
    for (TuFrame *frame in _frames) {
        [self enqueueFrame:frame];
    }
}

- (void)enqueueFrame:(TuFrame *)frame {
    // 1) 把 AVCC 字节放进 CMBlockBuffer（CoreMedia 的数据容器）
    NSData *avcc = frame.avcc;
    CMBlockBufferRef block = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, avcc.length, kCFAllocatorDefault, NULL, 0, avcc.length, kCMBlockBufferAssureMemoryNowFlag, &block);
    if (status != noErr || !block) {
        return;
    }
    CMBlockBufferReplaceDataBytes(avcc.bytes, block, 0, avcc.length);

    // 2) 时间信息：PTS 决定「何时显示」；DTS 设 invalid 表示按送入顺序解码
    //    （这个样例有 B 帧，PTS 会来回跳，但入队顺序就是解码顺序）
    CMSampleTimingInfo timing;
    timing.duration = CMTimeMake(1, 30);
    timing.presentationTimeStamp = CMTimeMake(MAX(frame.ptsUs, 0), 1000000);
    timing.decodeTimeStamp = kCMTimeInvalid;

    // 3) 拼成 CMSampleBuffer = 数据 + 格式 + 时间
    size_t sampleSize = avcc.length;
    CMSampleBufferRef sample = NULL;
    status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, _formatDesc, 1, 1, &timing, 1, &sampleSize, &sample);
    CFRelease(block);
    if (status != noErr || !sample) {
        return;
    }

    // 4) 标记是否关键帧，方便显示层/解码器做丢帧策略
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, YES);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_NotSync, frame.isIDR ? kCFBooleanFalse : kCFBooleanTrue);
    }

    // 5) 第一帧时启动显示时钟，从这一帧的 PTS 开始走
    if (![self ensureTimebase:frame.ptsUs]) {
        CFRelease(sample);
        return;
    }

    // 6) 显示层满了就等它播掉一些，再继续送（这就是前面放到后台的原因）
    while (!_displayLayer.isReadyForMoreMediaData) {
        if (_displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
            [_displayLayer flush];
            break;
        }
        [NSThread sleepForTimeInterval:0.005];
    }
    [_displayLayer enqueueSampleBuffer:sample];
    CFRelease(sample);
}

#pragma mark - 公共辅助

/// 第一次送帧时创建并启动 controlTimebase：图层拿它和 sample 的 PTS 对比，决定何时画
- (BOOL)ensureTimebase:(int64_t)ptsUs {
    if (_timebase) {
        return YES;
    }
    OSStatus status = CMTimebaseCreateWithSourceClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &_timebase);
    if (status != noErr || !_timebase) {
        return NO;
    }
    CMTimebaseSetTime(_timebase, CMTimeMake(MAX(ptsUs, 0), 1000000));
    CMTimebaseSetRate(_timebase, 1.0);
    _displayLayer.controlTimebase = _timebase;
    return YES;
}

/// 用 SPS + PPS 创建 CMVideoFormatDescription；显示层靠它知道怎么解 H.264
- (BOOL)ensureFormat {
    if (_formatDesc) {
        return YES;
    }
    if (!_sps || !_pps) {
        return NO;
    }
    const uint8_t *sets[2] = {_sps.bytes, _pps.bytes};
    size_t sizes[2] = {_sps.length, _pps.length};
    // 最后一个 4：NAL Length Size = 4，和我们 AVCC 前缀一致
    return CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, sets, sizes, 4, &_formatDesc) == noErr;
}

- (void)resetCurrentAU {
    [_currentAU removeAllObjects];
    _currentAUPts = -1;
    _currentAUHasVCL = NO;
    _currentAUIsIDR = NO;
}

/// 扫描 00 00 01（3 字节）或 00 00 00 01（4 字节）起始码
- (NSInteger)findStartCode:(const uint8_t *)p from:(NSInteger)from length:(NSInteger)length codeLen:(NSInteger *)codeLen {
    for (NSInteger i = from; i + 2 < length; i++) {
        if (p[i] == 0 && p[i + 1] == 0) {
            if (p[i + 2] == 1) {
                *codeLen = 3;
                return i;
            }
            if (i + 3 < length && p[i + 2] == 0 && p[i + 3] == 1) {
                *codeLen = 4;
                return i;
            }
        }
    }
    return -1;
}

@end
