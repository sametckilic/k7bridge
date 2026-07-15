#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/message.h>
#import <atomic>
#import <math.h>

// Private AudioToolbox types present on iOS 15. They are resolved dynamically so
// unsupported builds fail closed instead of crashing an audio system process.
static const AudioQueuePropertyID K7AudioQueueTapProperty='qtob';
static const int K7AudioTapPIDSpeaker=-2;
static const int K7AudioTapPIDSystem=-1;

static std::atomic<uint64_t> K7Frames;
static std::atomic<uint64_t> K7Callbacks;
static std::atomic<double> K7Energy;
static std::atomic<float> K7Peak;
static std::atomic<bool> K7Running;

static void K7Input(void *context,AudioQueueRef queue,AudioQueueBufferRef buffer,
    const AudioTimeStamp *timestamp,UInt32 packets,const AudioStreamPacketDescription *descriptions) {
    if (buffer && buffer->mAudioData && buffer->mAudioDataByteSize>=sizeof(float)) {
        UInt32 samples=buffer->mAudioDataByteSize/sizeof(float);
        const float *values=(const float *)buffer->mAudioData;
        double energy=0;
        float peak=0;
        for (UInt32 index=0;index<samples;index++) {
            float sample=values[index];
            if (!isfinite(sample)) continue;
            energy+=(double)sample*(double)sample;
            peak=MAX(peak,fabsf(sample));
        }
        K7Frames.fetch_add(samples,std::memory_order_relaxed);
        K7Callbacks.fetch_add(1,std::memory_order_relaxed);
        double current=K7Energy.load(std::memory_order_relaxed);
        while (!K7Energy.compare_exchange_weak(current,current+energy,std::memory_order_relaxed)) {}
        float existing=K7Peak.load(std::memory_order_relaxed);
        while (peak>existing && !K7Peak.compare_exchange_weak(existing,peak,std::memory_order_relaxed)) {}
    }
    if (K7Running.load(std::memory_order_relaxed)) AudioQueueEnqueueBuffer(queue,buffer,0,NULL);
}

static void K7Print(NSDictionary *value) {
    NSData *json=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    if (json) fprintf(stdout,"%s\n",[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
}

static void K7Output(void *context,AudioQueueRef queue,AudioQueueBufferRef buffer) {}

int main(int argc,char **argv) { @autoreleasepool {
    NSTimeInterval duration=argc>1?MAX(1,MIN(30,atof(argv[1]))):5;
    BOOL systemSource=argc>2 && strcmp(argv[2],"system")==0;
    BOOL playTone=(argc>2 && strcmp(argv[2],"tone")==0) ||
        (argc>3 && strcmp(argv[3],"tone")==0);
    int sourcePID=systemSource?K7AudioTapPIDSystem:K7AudioTapPIDSpeaker;
    NSString *sourceName=systemSource?@"system":@"speaker";
    Class descriptionClass=NSClassFromString(@"ATAudioTapDescription");
    Class tapClass=NSClassFromString(@"ATAudioTap");
    SEL descriptionSelector=NSSelectorFromString(@"initProcessTapInternalWithFormat:PID:");
    SEL tapSelector=NSSelectorFromString(@"initWithTapDescription:");
    if (!descriptionClass || !tapClass ||
        ![descriptionClass instancesRespondToSelector:descriptionSelector] ||
        ![tapClass instancesRespondToSelector:tapSelector]) {
        K7Print(@{@"ok":@NO,@"stage":@"private_api",@"error":@"ATAudioTap is unavailable"});
        return 69;
    }

    AVAudioFormat *format=[[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
        sampleRate:16000 channels:1 interleaved:YES];
    id description=((id(*)(id,SEL,id,int))objc_msgSend)([descriptionClass alloc],descriptionSelector,
        format,sourcePID);
    id tap=description?((id(*)(id,SEL,id))objc_msgSend)([tapClass alloc],tapSelector,description):nil;
    if (!tap) {
        K7Print(@{@"ok":@NO,@"stage":@"tap_create",@"error":@"Speaker tap could not be created"});
        return 70;
    }

    AudioStreamBasicDescription stream=*format.streamDescription;
    AudioQueueRef queue=NULL;
    OSStatus status=AudioQueueNewInput(&stream,K7Input,NULL,NULL,NULL,0x800,&queue);
    if (status==noErr)
        status=AudioQueueSetProperty(queue,K7AudioQueueTapProperty,(__bridge const void *)tap,sizeof(void *));
    AudioQueueBufferRef buffers[3]={NULL,NULL,NULL};
    for (int index=0;status==noErr&&index<3;index++) {
        status=AudioQueueAllocateBuffer(queue,320*sizeof(float),&buffers[index]);
        if (status==noErr) status=AudioQueueEnqueueBuffer(queue,buffers[index],0,NULL);
    }
    if (status==noErr) {
        K7Running.store(true,std::memory_order_relaxed);
        status=AudioQueueStart(queue,NULL);
    }
    if (status!=noErr) {
        if (queue) AudioQueueDispose(queue,true);
        K7Print(@{@"ok":@NO,@"stage":@"audio_queue",@"status":@(status)});
        return 71;
    }

    AudioQueueRef outputQueue=NULL;
    AudioQueueBufferRef outputBuffer=NULL;
    if (playTone) {
        NSError *sessionError=nil;
        AVAudioSession *session=[AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&sessionError];
        [session setActive:YES error:&sessionError];
        if (!sessionError && AudioQueueNewOutput(&stream,K7Output,NULL,NULL,NULL,0,&outputQueue)==noErr &&
            AudioQueueAllocateBuffer(outputQueue,16000*sizeof(float),&outputBuffer)==noErr) {
            float *samples=(float *)outputBuffer->mAudioData;
            for (UInt32 index=0;index<16000;index++)
                samples[index]=0.04f*sinf(2.0f*(float)M_PI*440.0f*(float)index/16000.0f);
            outputBuffer->mAudioDataByteSize=16000*sizeof(float);
            AudioQueueEnqueueBuffer(outputQueue,outputBuffer,0,NULL);
            AudioQueueStart(outputQueue,NULL);
        }
    }

    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:duration];
    while ([deadline timeIntervalSinceNow]>0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    K7Running.store(false,std::memory_order_relaxed);
    if (outputQueue) {
        AudioQueueStop(outputQueue,true);
        AudioQueueDispose(outputQueue,true);
    }
    AudioQueueStop(queue,true);
    AudioQueueDispose(queue,true);

    uint64_t frames=K7Frames.load(std::memory_order_relaxed);
    double rms=frames?sqrt(K7Energy.load(std::memory_order_relaxed)/(double)frames):0;
    K7Print(@{@"ok":@(frames>0),@"stage":@"complete",@"source":sourceName,
        @"sampleRate":@16000,@"frames":@(frames),@"callbacks":@(K7Callbacks.load()),
        @"rms":@(rms),@"peak":@(K7Peak.load()),@"duration":@(duration),@"tone":@(playTone)});
    return frames>0?0:72;
} }
