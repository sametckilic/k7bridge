#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <atomic>
#import <math.h>
#import "../Shared/BridgeIPC.h"

static NSString *const K7AudioGatePath=@"/var/mobile/Library/K7Bridge/audio-gate.json";
static NSString *const K7AudioProbeFlagPath=@"/var/mobile/Library/K7Bridge/audio-probe.enabled";
static const unsigned int K7AudioProbeSlotCount=32;

typedef struct {
    std::atomic<uintptr_t> unit;
    std::atomic<uint32_t> bus;
    std::atomic<uint64_t> calls;
    std::atomic<uint32_t> frames;
    std::atomic<uint32_t> buffers;
    std::atomic<uint32_t> bytes;
    std::atomic<uint32_t> floatPeakPPM;
    std::atomic<uint32_t> int16PeakPPM;
} K7AudioProbeSlot;

static K7AudioProbeSlot K7AudioProbeSlots[K7AudioProbeSlotCount];
static BOOL K7AudioProbeEnabled=NO;
static dispatch_source_t K7AudioProbeTimer;
static dispatch_queue_t K7AudioProbeQueue;

static void K7AtomicMaximum(std::atomic<uint32_t> &target,uint32_t value) {
    uint32_t current=target.load(std::memory_order_relaxed);
    while (current<value && !target.compare_exchange_weak(current,value,std::memory_order_relaxed)) {}
}

static void K7RecordRender(AudioUnit unit,UInt32 bus,UInt32 frames,AudioBufferList *data) {
    uintptr_t raw=(uintptr_t)unit;
    unsigned int empty=K7AudioProbeSlotCount;
    for (unsigned int index=0;index<K7AudioProbeSlotCount;index++) {
        uintptr_t current=K7AudioProbeSlots[index].unit.load(std::memory_order_relaxed);
        if (current==raw && K7AudioProbeSlots[index].bus.load(std::memory_order_relaxed)==bus) {
            K7AudioProbeSlots[index].calls.fetch_add(1,std::memory_order_relaxed);
            K7AudioProbeSlots[index].frames.store(frames,std::memory_order_relaxed);
            if (data) {
                K7AudioProbeSlots[index].buffers.store(data->mNumberBuffers,std::memory_order_relaxed);
                uint32_t bytes=0;
                uint32_t floatPeak=0,int16Peak=0;
                for (UInt32 item=0;item<data->mNumberBuffers;item++) {
                    AudioBuffer buffer=data->mBuffers[item];
                    bytes+=buffer.mDataByteSize;
                    if (!buffer.mData) continue;
                    const float *floats=(const float *)buffer.mData;
                    size_t floatCount=buffer.mDataByteSize/sizeof(float);
                    BOOL floatValid=floatCount>0;
                    for (size_t sample=0;sample<floatCount;sample++) {
                        float absolute=fabsf(floats[sample]);
                        if (!isfinite(absolute) || absolute>16.0f) { floatValid=NO; break; }
                        floatPeak=MAX(floatPeak,(uint32_t)MIN(1000000.0f,absolute*1000000.0f));
                    }
                    if (!floatValid) floatPeak=0;
                    const int16_t *integers=(const int16_t *)buffer.mData;
                    size_t integerCount=buffer.mDataByteSize/sizeof(int16_t);
                    for (size_t sample=0;sample<integerCount;sample++) {
                        uint32_t absolute=integers[sample]==INT16_MIN?32768:(uint32_t)abs(integers[sample]);
                        int16Peak=MAX(int16Peak,(uint32_t)MIN(1000000ULL,(uint64_t)absolute*1000000ULL/32768ULL));
                    }
                }
                K7AudioProbeSlots[index].bytes.store(bytes,std::memory_order_relaxed);
                K7AtomicMaximum(K7AudioProbeSlots[index].floatPeakPPM,floatPeak);
                K7AtomicMaximum(K7AudioProbeSlots[index].int16PeakPPM,int16Peak);
            }
            return;
        }
        if (!current && empty==K7AudioProbeSlotCount) empty=index;
    }
    if (empty<K7AudioProbeSlotCount) {
        uintptr_t expected=0;
        if (K7AudioProbeSlots[empty].unit.compare_exchange_strong(expected,raw,std::memory_order_relaxed)) {
            K7AudioProbeSlots[empty].bus.store(bus,std::memory_order_relaxed);
            K7AudioProbeSlots[empty].calls.store(1,std::memory_order_relaxed);
            K7AudioProbeSlots[empty].frames.store(frames,std::memory_order_relaxed);
        }
    }
}

static void K7EmitProbeSnapshot(void) {
    for (unsigned int index=0;index<K7AudioProbeSlotCount;index++) {
        uintptr_t unit=K7AudioProbeSlots[index].unit.load(std::memory_order_relaxed);
        uint64_t calls=K7AudioProbeSlots[index].calls.exchange(0,std::memory_order_relaxed);
        if (!unit || !calls) continue;
        uint32_t floatPeak=K7AudioProbeSlots[index].floatPeakPPM.exchange(0,std::memory_order_relaxed);
        uint32_t int16Peak=K7AudioProbeSlots[index].int16PeakPPM.exchange(0,std::memory_order_relaxed);
        NSDictionary *fields=@{
            @"slot":@(index).stringValue,
            @"unit":[NSString stringWithFormat:@"0x%llx",(unsigned long long)unit],
            @"bus":@(K7AudioProbeSlots[index].bus.load(std::memory_order_relaxed)).stringValue,
            @"calls":@(calls).stringValue,
            @"frames":@(K7AudioProbeSlots[index].frames.load(std::memory_order_relaxed)).stringValue,
            @"buffers":@(K7AudioProbeSlots[index].buffers.load(std::memory_order_relaxed)).stringValue,
            @"bytes":@(K7AudioProbeSlots[index].bytes.load(std::memory_order_relaxed)).stringValue,
            @"floatPeakPPM":@(floatPeak).stringValue,
            @"int16PeakPPM":@(int16Peak).stringValue
        };
        [K7BridgeIPC send:@{@"type":@"diagnostic",@"component":@"audio-probe",
            @"event":@"render_activity",@"level":@"info",@"fields":fields}
            toPort:@"com.k7bridge.gateway" timeout:0.2];
    }
}

%group K7AudioDiscovery
%hookf(OSStatus,AudioUnitRender,AudioUnit unit,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *timestamp,UInt32 bus,UInt32 frames,AudioBufferList *data) {
    OSStatus status=%orig;
    if (status==noErr) K7RecordRender(unit,bus,frames,data);
    return status;
}

%hookf(OSStatus,AudioUnitSetProperty,AudioUnit unit,AudioUnitPropertyID property,AudioUnitScope scope,AudioUnitElement element,const void *data,UInt32 size) {
    OSStatus status=%orig;
    if (status==noErr && property==kAudioUnitProperty_StreamFormat && data && size>=sizeof(AudioStreamBasicDescription)) {
        AudioStreamBasicDescription format=*(const AudioStreamBasicDescription *)data;
        uintptr_t raw=(uintptr_t)unit;
        dispatch_async(K7AudioProbeQueue,^{
            NSDictionary *fields=@{
                @"unit":[NSString stringWithFormat:@"0x%llx",(unsigned long long)raw],
                @"scope":@(scope).stringValue,@"element":@(element).stringValue,
                @"sampleRate":@((NSUInteger)llround(format.mSampleRate)).stringValue,
                @"formatId":@(format.mFormatID).stringValue,@"formatFlags":@(format.mFormatFlags).stringValue,
                @"bytesPerFrame":@(format.mBytesPerFrame).stringValue,
                @"framesPerPacket":@(format.mFramesPerPacket).stringValue,
                @"channels":@(format.mChannelsPerFrame).stringValue,@"bits":@(format.mBitsPerChannel).stringValue
            };
            [K7BridgeIPC send:@{@"type":@"diagnostic",@"component":@"audio-probe",
                @"event":@"stream_format",@"level":@"info",@"fields":fields}
                toPort:@"com.k7bridge.gateway" timeout:0.2];
        });
    }
    return status;
}
%end

%ctor { @autoreleasepool {
    K7AudioProbeEnabled=[[NSFileManager defaultManager] fileExistsAtPath:K7AudioProbeFlagPath];
    NSData *data=[NSData dataWithContentsOfFile:K7AudioGatePath];
    NSDictionary *gate=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;

    if (K7AudioProbeEnabled) {
        K7AudioProbeQueue=dispatch_queue_create("com.k7bridge.audio-probe",DISPATCH_QUEUE_SERIAL);
        %init(K7AudioDiscovery);
        K7AudioProbeTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,K7AudioProbeQueue);
        dispatch_source_set_timer(K7AudioProbeTimer,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),
            2*NSEC_PER_SEC,200*NSEC_PER_MSEC);
        dispatch_source_set_event_handler(K7AudioProbeTimer,^{ K7EmitProbeSnapshot(); });
        dispatch_resume(K7AudioProbeTimer);
        [K7BridgeIPC send:@{@"type":@"diagnostic",@"component":@"audio-probe",
            @"event":@"probe_loaded",@"level":@"info",@"fields":@{@"bufferAccess":@"level-only"}}
            toPort:@"com.k7bridge.gateway" timeout:0.2];
    }

    if (![gate[@"passed"] boolValue]) {
        NSLog(@"K7AudioBridge fail-closed: verified audio gate is absent");
        return;
    }
    // A production PCM hook is installed only after the build-specific discovery
    // report proves both directions and the gate verifies its artifact hash.
    NSLog(@"K7AudioBridge gate present, but the verified PCM hook artifact is absent");
} }
