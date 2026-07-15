#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <atomic>
#import <math.h>

static NSString *const K7AudioGatePath=@"/var/mobile/Library/K7Bridge/audio-gate.json";
static NSString *const K7AudioProbeFlagPath=@"/var/mobile/Library/K7Bridge/audio-probe.enabled";
static NSString *const K7AudioProbeSessionPath=@"/var/mobile/Library/K7Bridge/audio-probe-session.json";
static NSString *const K7AudioProbeResultPath=@"/var/mobile/Library/K7Bridge/audio-probe-result.jsonl";
static const unsigned int K7AudioFormatSlotCount=4096;
static const unsigned long long K7AudioProbeMaximumBytes=64*1024;

typedef struct {
    std::atomic<uintptr_t> unit;
    std::atomic<uint32_t> float16KMask;
} K7AudioFormatSlot;

static K7AudioFormatSlot K7AudioFormatSlots[K7AudioFormatSlotCount];
static std::atomic<bool> K7AudioProbeActive;
static std::atomic<uint64_t> K7AudioProbeDeadline;
static std::atomic<uintptr_t> K7ToneUnit;
static std::atomic<uint32_t> K7ToneBus{UINT32_MAX};
static std::atomic<uint32_t> K7ToneBufferCount;
static std::atomic<uint64_t> K7ToneSamples;
static std::atomic<uint32_t> K7ToneNotice;
static dispatch_source_t K7AudioProbeTimer;
static dispatch_queue_t K7AudioProbeQueue;

static unsigned int K7AudioFormatSlotIndex(uintptr_t raw) {
    raw^=raw>>17;
    raw*=0xed5ad4bbU;
    raw^=raw>>11;
    return (unsigned int)(raw&(K7AudioFormatSlotCount-1));
}

static BOOL K7UnitHasFloat16KFormat(AudioUnit unit) {
    uintptr_t raw=(uintptr_t)unit;
    unsigned int start=K7AudioFormatSlotIndex(raw);
    for (unsigned int offset=0;offset<K7AudioFormatSlotCount;offset++) {
        unsigned int index=(start+offset)&(K7AudioFormatSlotCount-1);
        uintptr_t current=K7AudioFormatSlots[index].unit.load(std::memory_order_relaxed);
        if (current==raw)
            return K7AudioFormatSlots[index].float16KMask.load(std::memory_order_relaxed)!=0;
        if (!current) return NO;
    }
    return NO;
}

static void K7RememberStreamFormat(AudioUnit unit,AudioUnitScope scope,AudioUnitElement element,
    const AudioStreamBasicDescription &format) {
    if (!K7AudioProbeActive.load(std::memory_order_relaxed) || scope>=4 || element>=8) return;
    BOOL matches=format.mFormatID==kAudioFormatLinearPCM &&
        (format.mFormatFlags&kAudioFormatFlagIsFloat)!=0 &&
        llround(format.mSampleRate)==16000 && format.mChannelsPerFrame>=1 &&
        format.mChannelsPerFrame<=2 && format.mBitsPerChannel==32 &&
        format.mBytesPerFrame==sizeof(float);
    uintptr_t raw=(uintptr_t)unit;
    unsigned int start=K7AudioFormatSlotIndex(raw);
    K7AudioFormatSlot *slot=NULL;
    for (unsigned int offset=0;offset<K7AudioFormatSlotCount;offset++) {
        unsigned int index=(start+offset)&(K7AudioFormatSlotCount-1);
        uintptr_t current=K7AudioFormatSlots[index].unit.load(std::memory_order_relaxed);
        if (current==raw) { slot=&K7AudioFormatSlots[index]; break; }
        if (!current) {
            if (!matches) return;
            uintptr_t expected=0;
            if (K7AudioFormatSlots[index].unit.compare_exchange_strong(expected,raw,
                std::memory_order_relaxed)) { slot=&K7AudioFormatSlots[index]; break; }
            if (expected==raw) { slot=&K7AudioFormatSlots[index]; break; }
        }
    }
    if (!slot) return;
    uint32_t bit=1u<<((uint32_t)scope*8u+(uint32_t)element);
    if (matches) slot->float16KMask.fetch_or(bit,std::memory_order_relaxed);
    else slot->float16KMask.fetch_and(~bit,std::memory_order_relaxed);
}

static void K7ApplyTestTone(AudioUnit unit,UInt32 bus,UInt32 frames,AudioBufferList *data) {
    if (!K7AudioProbeActive.load(std::memory_order_relaxed) ||
        !K7UnitHasFloat16KFormat(unit) || !data || data->mNumberBuffers<1 ||
        data->mNumberBuffers>2) return;
    uintptr_t selected=K7ToneUnit.load(std::memory_order_relaxed);
    uint32_t selectedBus=K7ToneBus.load(std::memory_order_relaxed);
    uintptr_t raw=(uintptr_t)unit;
    if ((selected && selected!=raw) || (selectedBus!=UINT32_MAX && selectedBus!=bus)) return;

    float peak=0.0f;
    for (UInt32 item=0;item<data->mNumberBuffers;item++) {
        AudioBuffer buffer=data->mBuffers[item];
        if (!buffer.mData || buffer.mDataByteSize!=frames*sizeof(float)) return;
        const float *samples=(const float *)buffer.mData;
        for (UInt32 index=0;index<frames;index++) {
            float absolute=fabsf(samples[index]);
            if (!isfinite(absolute) || absolute>16.0f) return;
            peak=MAX(peak,absolute);
        }
    }
    if (!selected && peak<0.00001f) return;

    uintptr_t expected=0;
    if (K7ToneUnit.compare_exchange_strong(expected,raw,std::memory_order_relaxed))
        K7ToneNotice.store(1,std::memory_order_relaxed);
    if (K7ToneUnit.load(std::memory_order_relaxed)!=raw) return;
    uint32_t expectedBus=UINT32_MAX;
    K7ToneBus.compare_exchange_strong(expectedBus,bus,std::memory_order_relaxed);
    if (K7ToneBus.load(std::memory_order_relaxed)!=bus) return;
    K7ToneBufferCount.store(data->mNumberBuffers,std::memory_order_relaxed);

    uint64_t firstSample=K7ToneSamples.fetch_add(frames,std::memory_order_relaxed);
    const uint64_t toneStart=16000,toneEnd=32000;
    if (firstSample>=toneEnd || firstSample+(uint64_t)frames<=toneStart) return;
    UInt32 begin=firstSample<toneStart?(UInt32)(toneStart-firstSample):0;
    UInt32 end=(UInt32)MIN((uint64_t)frames,toneEnd-firstSample);
    for (UInt32 item=0;item<data->mNumberBuffers;item++) {
        float *samples=(float *)data->mBuffers[item].mData;
        for (UInt32 index=begin;index<end;index++) {
            uint64_t toneSample=firstSample+(uint64_t)index-toneStart;
            samples[index]=0.08f*sinf(2.0f*(float)M_PI*440.0f*(float)toneSample/16000.0f);
        }
    }
    if (firstSample<=toneStart && firstSample+(uint64_t)frames>toneStart)
        K7ToneNotice.store(2,std::memory_order_relaxed);
    if (firstSample<toneEnd && firstSample+(uint64_t)frames>=toneEnd)
        K7ToneNotice.store(3,std::memory_order_relaxed);
}

static void K7WriteAudioEvent(NSString *event) { @autoreleasepool {
    if (!event.length) return;
    NSNumber *size=[[[NSFileManager defaultManager] attributesOfItemAtPath:K7AudioProbeResultPath
        error:nil] objectForKey:NSFileSize];
    if (size.unsignedLongLongValue>K7AudioProbeMaximumBytes)
        [[NSData data] writeToFile:K7AudioProbeResultPath atomically:YES];
    NSDictionary *entry=@{
        @"timestamp":@([[NSDate date] timeIntervalSince1970]),
        @"event":event,
        @"unit":[NSString stringWithFormat:@"0x%llx",(unsigned long long)K7ToneUnit.load()],
        @"bus":@(K7ToneBus.load()),
        @"buffers":@(K7ToneBufferCount.load()),
        @"samples":@(K7ToneSamples.load())
    };
    NSData *json=[NSJSONSerialization dataWithJSONObject:entry options:NSJSONWritingSortedKeys error:nil];
    if (!json) return;
    NSMutableData *line=[json mutableCopy];
    [line appendBytes:"\n" length:1];
    NSFileHandle *handle=[NSFileHandle fileHandleForWritingAtPath:K7AudioProbeResultPath];
    [handle seekToEndOfFile];
    [handle writeData:line];
    [handle closeFile];
} }

static void K7AudioProbeTick(void) {
    uint32_t notice=K7ToneNotice.exchange(0,std::memory_order_relaxed);
    if (notice==1) K7WriteAudioEvent(@"candidate_selected");
    else if (notice==2) K7WriteAudioEvent(@"tone_started");
    else if (notice==3) K7WriteAudioEvent(@"tone_completed");
    uint64_t now=(uint64_t)[[NSDate date] timeIntervalSince1970];
    if (K7AudioProbeActive.load(std::memory_order_relaxed) &&
        now>=K7AudioProbeDeadline.load(std::memory_order_relaxed)) {
        K7AudioProbeActive.store(false,std::memory_order_relaxed);
        K7WriteAudioEvent(@"session_expired");
        dispatch_source_cancel(K7AudioProbeTimer);
    }
}

%group K7BoundedAudioDiscovery
%hookf(OSStatus,AudioUnitRender,AudioUnit unit,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *timestamp,UInt32 bus,UInt32 frames,AudioBufferList *data) {
    OSStatus status=%orig;
    if (status==noErr) K7ApplyTestTone(unit,bus,frames,data);
    return status;
}

%hookf(OSStatus,AudioUnitSetProperty,AudioUnit unit,AudioUnitPropertyID property,AudioUnitScope scope,AudioUnitElement element,const void *data,UInt32 size) {
    OSStatus status=%orig;
    if (status==noErr && property==kAudioUnitProperty_StreamFormat && data &&
        size>=sizeof(AudioStreamBasicDescription))
        K7RememberStreamFormat(unit,scope,element,*(const AudioStreamBasicDescription *)data);
    return status;
}
%end

%ctor { @autoreleasepool {
    NSData *sessionData=[NSData dataWithContentsOfFile:K7AudioProbeSessionPath];
    NSDictionary *session=sessionData?[NSJSONSerialization JSONObjectWithData:sessionData
        options:0 error:nil]:nil;
    uint64_t now=(uint64_t)[[NSDate date] timeIntervalSince1970];
    uint64_t expires=[session[@"expiresAt"] unsignedLongLongValue];
    BOOL baseEnabled=[[NSFileManager defaultManager] fileExistsAtPath:K7AudioProbeFlagPath];
    BOOL sessionValid=expires>now && expires<=now+60;
    if (baseEnabled && sessionValid) {
        K7AudioProbeDeadline.store(expires,std::memory_order_relaxed);
        K7AudioProbeActive.store(true,std::memory_order_relaxed);
        K7AudioProbeQueue=dispatch_queue_create("com.k7bridge.audio-probe.bounded",DISPATCH_QUEUE_SERIAL);
        %init(K7BoundedAudioDiscovery);
        K7WriteAudioEvent(@"session_started");
        K7AudioProbeTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,K7AudioProbeQueue);
        dispatch_source_set_timer(K7AudioProbeTimer,dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),
            100*NSEC_PER_MSEC,20*NSEC_PER_MSEC);
        dispatch_source_set_event_handler(K7AudioProbeTimer,^{ K7AudioProbeTick(); });
        dispatch_resume(K7AudioProbeTimer);
    }

    NSData *gateData=[NSData dataWithContentsOfFile:K7AudioGatePath];
    NSDictionary *gate=gateData?[NSJSONSerialization JSONObjectWithData:gateData options:0 error:nil]:nil;
    if (![gate[@"passed"] boolValue]) {
        NSLog(@"K7AudioBridge fail-closed: verified audio gate is absent");
        return;
    }
    NSLog(@"K7AudioBridge gate present, but the verified PCM hook artifact is absent");
} }
