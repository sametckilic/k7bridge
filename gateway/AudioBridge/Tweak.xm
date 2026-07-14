#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <atomic>
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
} K7AudioProbeSlot;

static K7AudioProbeSlot K7AudioProbeSlots[K7AudioProbeSlotCount];
static BOOL K7AudioProbeEnabled=NO;
static dispatch_source_t K7AudioProbeTimer;

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
                for (UInt32 item=0;item<data->mNumberBuffers;item++) bytes+=data->mBuffers[item].mDataByteSize;
                K7AudioProbeSlots[index].bytes.store(bytes,std::memory_order_relaxed);
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
        NSDictionary *fields=@{
            @"slot":@(index).stringValue,
            @"unit":[NSString stringWithFormat:@"0x%llx",(unsigned long long)unit],
            @"bus":@(K7AudioProbeSlots[index].bus.load(std::memory_order_relaxed)).stringValue,
            @"calls":@(calls).stringValue,
            @"frames":@(K7AudioProbeSlots[index].frames.load(std::memory_order_relaxed)).stringValue,
            @"buffers":@(K7AudioProbeSlots[index].buffers.load(std::memory_order_relaxed)).stringValue,
            @"bytes":@(K7AudioProbeSlots[index].bytes.load(std::memory_order_relaxed)).stringValue
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
%end

%ctor { @autoreleasepool {
    K7AudioProbeEnabled=[[NSFileManager defaultManager] fileExistsAtPath:K7AudioProbeFlagPath];
    NSData *data=[NSData dataWithContentsOfFile:K7AudioGatePath];
    NSDictionary *gate=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;

    if (K7AudioProbeEnabled) {
        %init(K7AudioDiscovery);
        dispatch_queue_t queue=dispatch_queue_create("com.k7bridge.audio-probe",DISPATCH_QUEUE_SERIAL);
        K7AudioProbeTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);
        dispatch_source_set_timer(K7AudioProbeTimer,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),
            2*NSEC_PER_SEC,200*NSEC_PER_MSEC);
        dispatch_source_set_event_handler(K7AudioProbeTimer,^{ K7EmitProbeSnapshot(); });
        dispatch_resume(K7AudioProbeTimer);
        [K7BridgeIPC send:@{@"type":@"diagnostic",@"component":@"audio-probe",
            @"event":@"probe_loaded",@"level":@"info",@"fields":@{@"bufferAccess":@"0"}}
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
