#import "MediaServer.h"
#import "Diagnostics.h"
#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/message.h>
#import <sodium.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <unistd.h>
#import <atomic>
#import <math.h>

static const uint16_t K7MediaPort=7444;
static const UInt32 K7FramesPerPacket=320;
static const UInt32 K7UplinkChunkFrames=1600;
static const AudioQueuePropertyID K7AudioQueueTapProperty='qtob';
static const int K7AudioTapPIDSpeaker=-2;

typedef struct __attribute__((packed)) {
    uint8_t magic[4];
    uint8_t version;
    uint8_t direction;
    uint16_t framesBE;
    uint64_t sequenceBE;
    uuid_t callID;
} K7MediaHeader;

static uint64_t K7HostToBig64(uint64_t value) {
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    return __builtin_bswap64(value);
#else
    return value;
#endif
}

static uint64_t K7BigToHost64(uint64_t value) { return K7HostToBig64(value); }

static NSData *K7WAVData(const int16_t *samples,UInt32 frames) {
    uint32_t payloadBytes=frames*sizeof(int16_t);
    uint32_t riffBytes=36+payloadBytes;
    uint32_t formatBytes=16;
    uint16_t format=1,channels=1,bits=16,blockAlign=2;
    uint32_t sampleRate=16000,byteRate=32000;
    NSMutableData *data=[NSMutableData dataWithCapacity:44+payloadBytes];
    [data appendBytes:"RIFF" length:4]; [data appendBytes:&riffBytes length:4];
    [data appendBytes:"WAVEfmt " length:8]; [data appendBytes:&formatBytes length:4];
    [data appendBytes:&format length:2]; [data appendBytes:&channels length:2];
    [data appendBytes:&sampleRate length:4]; [data appendBytes:&byteRate length:4];
    [data appendBytes:&blockAlign length:2]; [data appendBytes:&bits length:2];
    [data appendBytes:"data" length:4]; [data appendBytes:&payloadBytes length:4];
    [data appendBytes:samples length:payloadBytes];
    return data;
}

@interface K7MediaServer ()
- (void)consumeTapBytes:(NSData *)data;
- (void)consumeDatagram:(NSData *)packet address:(const struct sockaddr_storage *)address length:(socklen_t)length;
@end

static void K7TapInput(void *context,AudioQueueRef queue,AudioQueueBufferRef buffer,
    const AudioTimeStamp *timestamp,UInt32 packets,const AudioStreamPacketDescription *descriptions) {
    K7MediaServer *server=(__bridge K7MediaServer *)context;
    if (buffer && buffer->mAudioData && buffer->mAudioDataByteSize)
        [server consumeTapBytes:[NSData dataWithBytes:buffer->mAudioData length:buffer->mAudioDataByteSize]];
    AudioQueueEnqueueBuffer(queue,buffer,0,NULL);
}

@implementation K7MediaServer {
    dispatch_queue_t _queue;
    int _socket;
    dispatch_source_t _readSource;
    AudioQueueRef _tapQueue;
    NSUUID *_activeCallID;
    NSData *_mediaKey;
    NSMutableData *_downlinkPCM;
    NSMutableData *_uplinkPCM;
    NSMutableArray<AVAudioPlayer *> *_players;
    struct sockaddr_storage _clientAddress;
    socklen_t _clientAddressLength;
    BOOL _hasClientAddress;
    uint64_t _downlinkSequence;
    uint64_t _lastUplinkSequence;
    NSTimeInterval _nextUplinkTime;
    uint64_t _capturedFrames;
    uint64_t _sentPackets;
    uint64_t _receivedPackets;
    std::atomic<bool> _sessionActive;
}

- (instancetype)init {
    if ((self=[super init])) {
        _queue=dispatch_queue_create("com.example.K7Bridge.media",DISPATCH_QUEUE_SERIAL);
        _socket=-1;
        _downlinkPCM=[NSMutableData data];
        _uplinkPCM=[NSMutableData data];
        _players=[NSMutableArray array];
    }
    return self;
}

- (BOOL)start:(NSError **)error {
    if (_ready) return YES;
    if (sodium_init()<0) {
        if (error) *error=[NSError errorWithDomain:@"K7Media" code:1 userInfo:@{NSLocalizedDescriptionKey:@"libsodium initialization failed"}];
        return NO;
    }
    Class descriptionClass=NSClassFromString(@"ATAudioTapDescription");
    Class tapClass=NSClassFromString(@"ATAudioTap");
    SEL descriptionSelector=NSSelectorFromString(@"initProcessTapInternalWithFormat:PID:");
    SEL tapSelector=NSSelectorFromString(@"initWithTapDescription:");
    BOOL playerRoute=[AVAudioPlayer instancesRespondToSelector:NSSelectorFromString(@"setMixToUplink:")];
    if (!descriptionClass || !tapClass ||
        ![descriptionClass instancesRespondToSelector:descriptionSelector] ||
        ![tapClass instancesRespondToSelector:tapSelector] || !playerRoute) {
        _lastError=@"Required iOS 15 telephony audio routes are unavailable";
        if (error) *error=[NSError errorWithDomain:@"K7Media" code:2 userInfo:@{NSLocalizedDescriptionKey:_lastError}];
        return NO;
    }

    _socket=socket(AF_INET,SOCK_DGRAM,0);
    int reuse=1;
    setsockopt(_socket,SOL_SOCKET,SO_REUSEADDR,&reuse,sizeof(reuse));
    struct sockaddr_in address={};
    address.sin_len=sizeof(address); address.sin_family=AF_INET;
    address.sin_port=htons(K7MediaPort); address.sin_addr.s_addr=htonl(INADDR_ANY);
    if (_socket<0 || bind(_socket,(struct sockaddr *)&address,sizeof(address))!=0) {
        _lastError=[NSString stringWithFormat:@"UDP bind failed: %d",errno];
        if (_socket>=0) { close(_socket); _socket=-1; }
        if (error) *error=[NSError errorWithDomain:@"K7Media" code:3 userInfo:@{NSLocalizedDescriptionKey:_lastError}];
        return NO;
    }

    _readSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,(uintptr_t)_socket,0,_queue);
    __weak K7MediaServer *weakSelf=self;
    dispatch_source_set_event_handler(_readSource,^{
        K7MediaServer *self=weakSelf;
        if (!self) return;
        for (;;) {
            uint8_t bytes[2048];
            struct sockaddr_storage peer={}; socklen_t peerLength=sizeof(peer);
            ssize_t count=recvfrom(self->_socket,bytes,sizeof(bytes),MSG_DONTWAIT,
                (struct sockaddr *)&peer,&peerLength);
            if (count<=0) break;
            [self consumeDatagram:[NSData dataWithBytes:bytes length:(NSUInteger)count]
                address:&peer length:peerLength];
        }
    });
    dispatch_source_set_cancel_handler(_readSource,^{
        K7MediaServer *self=weakSelf;
        if (self && self->_socket>=0) { close(self->_socket); self->_socket=-1; }
    });
    dispatch_resume(_readSource);
    _ready=YES;
    [[K7Diagnostics shared] recordComponent:@"media" level:@"info" event:@"server_ready"
        fields:@{@"port":@(K7MediaPort),@"capture":@"ATAudioTap",@"uplink":@"AVAudioPlayer.mixToUplink"}];
    return YES;
}

- (void)stop {
    [self setActiveCall:nil sharedKey:nil];
    if (_readSource) { dispatch_source_cancel(_readSource); _readSource=nil; }
    _ready=NO;
}

- (void)setActiveCall:(NSUUID *)callID sharedKey:(NSData *)sharedKey {
    dispatch_async(_queue,^{
        BOOL same=callID && [callID isEqual:self->_activeCallID] && self->_sessionActive.load();
        if (same) return;
        [self stopAudioSession];
        if (!callID || sharedKey.length!=32) return;
        self->_activeCallID=[callID copy];
        NSString *info=[NSString stringWithFormat:@"k7bridge-media-v1|%@",callID.UUIDString];
        unsigned char key[crypto_auth_hmacsha256_BYTES];
        crypto_auth_hmacsha256_state h;
        crypto_auth_hmacsha256_init(&h,(const unsigned char *)sharedKey.bytes,sharedKey.length);
        NSData *infoData=[info dataUsingEncoding:NSUTF8StringEncoding];
        crypto_auth_hmacsha256_update(&h,(const unsigned char *)infoData.bytes,infoData.length);
        crypto_auth_hmacsha256_final(&h,key);
        self->_mediaKey=[NSData dataWithBytes:key length:sizeof(key)];
        sodium_memzero(key,sizeof(key));
        self->_downlinkSequence=0; self->_lastUplinkSequence=0;
        self->_hasClientAddress=NO; self->_nextUplinkTime=0;
        self->_sessionActive.store(true);
        NSError *issue=nil;
        if (![self startTap:&issue]) {
            self->_lastError=issue.localizedDescription;
            self->_sessionActive.store(false);
            [[K7Diagnostics shared] recordComponent:@"media" level:@"error" event:@"session_start_failed"
                fields:@{@"error":issue.localizedDescription?:@"unknown"}];
        } else {
            [[K7Diagnostics shared] recordComponent:@"media" level:@"info" event:@"session_started"
                fields:@{@"callId":callID.UUIDString}];
        }
    });
}

- (BOOL)startTap:(NSError **)error {
    AVAudioFormat *format=[[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
        sampleRate:16000 channels:1 interleaved:YES];
    Class descriptionClass=NSClassFromString(@"ATAudioTapDescription");
    Class tapClass=NSClassFromString(@"ATAudioTap");
    id description=((id(*)(id,SEL,id,int))objc_msgSend)([descriptionClass alloc],
        NSSelectorFromString(@"initProcessTapInternalWithFormat:PID:"),format,K7AudioTapPIDSpeaker);
    id tap=description?((id(*)(id,SEL,id))objc_msgSend)([tapClass alloc],
        NSSelectorFromString(@"initWithTapDescription:"),description):nil;
    if (!tap) {
        if (error) *error=[NSError errorWithDomain:@"K7Media" code:4 userInfo:@{NSLocalizedDescriptionKey:@"Telephony speaker tap creation failed"}];
        return NO;
    }
    AudioStreamBasicDescription stream=*format.streamDescription;
    OSStatus status=AudioQueueNewInput(&stream,K7TapInput,(__bridge void *)self,NULL,NULL,0x800,&_tapQueue);
    if (status==noErr) status=AudioQueueSetProperty(_tapQueue,K7AudioQueueTapProperty,(__bridge const void *)tap,sizeof(void *));
    for (int index=0;status==noErr&&index<3;index++) {
        AudioQueueBufferRef buffer=NULL;
        status=AudioQueueAllocateBuffer(_tapQueue,K7FramesPerPacket*sizeof(float),&buffer);
        if (status==noErr) status=AudioQueueEnqueueBuffer(_tapQueue,buffer,0,NULL);
    }
    if (status==noErr) status=AudioQueueStart(_tapQueue,NULL);
    if (status!=noErr) {
        if (_tapQueue) { AudioQueueDispose(_tapQueue,true); _tapQueue=NULL; }
        if (error) *error=[NSError errorWithDomain:@"K7Media" code:status userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Telephony tap failed (%d)",(int)status]}];
        return NO;
    }
    return YES;
}

- (void)stopAudioSession {
    _sessionActive.store(false);
    if (_tapQueue) { AudioQueueStop(_tapQueue,true); AudioQueueDispose(_tapQueue,true); _tapQueue=NULL; }
    [_players makeObjectsPerformSelector:@selector(stop)];
    [_players removeAllObjects];
    [_downlinkPCM setLength:0]; [_uplinkPCM setLength:0];
    _activeCallID=nil; _mediaKey=nil; _hasClientAddress=NO;
    _nextUplinkTime=0;
}

- (void)consumeTapBytes:(NSData *)data {
    if (!_sessionActive.load() || !data.length) return;
    dispatch_async(_queue,^{
        if (!self->_sessionActive.load() || !self->_activeCallID) return;
        const float *input=(const float *)data.bytes; NSUInteger count=data.length/sizeof(float);
        NSMutableData *pcm=[NSMutableData dataWithLength:count*sizeof(int16_t)];
        int16_t *output=(int16_t *)pcm.mutableBytes;
        for (NSUInteger index=0;index<count;index++) {
            float sample=isfinite(input[index])?MAX(-1.0f,MIN(1.0f,input[index])):0;
            output[index]=(int16_t)lrintf(sample*32767.0f);
        }
        [self->_downlinkPCM appendData:pcm]; self->_capturedFrames+=count;
        while (self->_downlinkPCM.length>=K7FramesPerPacket*sizeof(int16_t)) {
            NSData *chunk=[self->_downlinkPCM subdataWithRange:NSMakeRange(0,K7FramesPerPacket*sizeof(int16_t))];
            [self->_downlinkPCM replaceBytesInRange:NSMakeRange(0,chunk.length) withBytes:NULL length:0];
            [self sendDownlink:chunk frames:K7FramesPerPacket];
        }
    });
}

- (void)sendDownlink:(NSData *)pcm frames:(UInt16)frames {
    if (!_hasClientAddress || !_mediaKey || !_activeCallID || _socket<0) return;
    K7MediaHeader header={}; memcpy(header.magic,"K7M1",4); header.version=1; header.direction=2;
    header.framesBE=htons(frames); header.sequenceBE=K7HostToBig64(++_downlinkSequence);
    [_activeCallID getUUIDBytes:header.callID];
    unsigned char nonce[crypto_aead_chacha20poly1305_ietf_NPUBBYTES]={0};
    nonce[0]=2; memcpy(nonce+4,&header.sequenceBE,sizeof(header.sequenceBE));
    NSMutableData *packet=[NSMutableData dataWithBytes:&header length:sizeof(header)];
    NSMutableData *sealed=[NSMutableData dataWithLength:pcm.length+crypto_aead_chacha20poly1305_ietf_ABYTES];
    unsigned long long sealedLength=0;
    if (crypto_aead_chacha20poly1305_ietf_encrypt((unsigned char *)sealed.mutableBytes,&sealedLength,
        (const unsigned char *)pcm.bytes,pcm.length,
        (const unsigned char *)&header,sizeof(header),NULL,nonce,(const unsigned char *)_mediaKey.bytes)!=0) return;
    sealed.length=(NSUInteger)sealedLength; [packet appendData:sealed];
    if (sendto(_socket,packet.bytes,packet.length,0,(struct sockaddr *)&_clientAddress,_clientAddressLength)>0)
        _sentPackets++;
}

- (void)consumeDatagram:(NSData *)packet address:(const struct sockaddr_storage *)address length:(socklen_t)length {
    if (!_sessionActive.load() || packet.length<sizeof(K7MediaHeader)+crypto_aead_chacha20poly1305_ietf_ABYTES) return;
    K7MediaHeader header={}; memcpy(&header,packet.bytes,sizeof(header));
    if (memcmp(header.magic,"K7M1",4)!=0 || header.version!=1 || header.direction!=1) return;
    uint64_t sequence=K7BigToHost64(header.sequenceBE);
    UInt16 frames=ntohs(header.framesBE);
    NSUUID *callID=[[NSUUID alloc] initWithUUIDBytes:header.callID];
    if (![_activeCallID isEqual:callID] || sequence<=_lastUplinkSequence || frames>K7FramesPerPacket) return;
    NSUInteger encryptedLength=packet.length-sizeof(header);
    if (encryptedLength!=frames*sizeof(int16_t)+crypto_aead_chacha20poly1305_ietf_ABYTES) return;
    unsigned char nonce[crypto_aead_chacha20poly1305_ietf_NPUBBYTES]={0};
    nonce[0]=1; memcpy(nonce+4,&header.sequenceBE,sizeof(header.sequenceBE));
    NSMutableData *clear=[NSMutableData dataWithLength:encryptedLength]; unsigned long long clearLength=0;
    if (crypto_aead_chacha20poly1305_ietf_decrypt((unsigned char *)clear.mutableBytes,&clearLength,NULL,
        (const unsigned char *)packet.bytes+sizeof(header),encryptedLength,
        (const unsigned char *)&header,sizeof(header),nonce,(const unsigned char *)_mediaKey.bytes)!=0) return;
    clear.length=(NSUInteger)clearLength;
    _lastUplinkSequence=sequence; _clientAddress=*address; _clientAddressLength=length; _hasClientAddress=YES;
    _receivedPackets++; [_uplinkPCM appendData:clear];
    while (_uplinkPCM.length>=K7UplinkChunkFrames*sizeof(int16_t)) {
        NSData *chunk=[_uplinkPCM subdataWithRange:NSMakeRange(0,K7UplinkChunkFrames*sizeof(int16_t))];
        [_uplinkPCM replaceBytesInRange:NSMakeRange(0,chunk.length) withBytes:NULL length:0];
        [self playUplink:chunk];
    }
    if ((_receivedPackets%250)==1) {
        [[K7Diagnostics shared] recordComponent:@"media" level:@"info" event:@"flow"
            fields:@{@"uplinkPackets":@(_receivedPackets),@"downlinkPackets":@(_sentPackets),
                     @"capturedFrames":@(_capturedFrames)}];
    }
}

- (void)playUplink:(NSData *)pcm {
    NSError *error=nil;
    AVAudioPlayer *player=[[AVAudioPlayer alloc] initWithData:K7WAVData((const int16_t *)pcm.bytes,K7UplinkChunkFrames) error:&error];
    SEL selector=NSSelectorFromString(@"setMixToUplink:");
    if (!player || ![player respondsToSelector:selector]) return;
    ((void(*)(id,SEL,BOOL))objc_msgSend)(player,selector,YES);
    player.volume=1.0; [player prepareToPlay];
    NSTimeInterval now=player.deviceCurrentTime;
    if (_nextUplinkTime<now+0.04) _nextUplinkTime=now+0.12;
    [player playAtTime:_nextUplinkTime];
    _nextUplinkTime+=((NSTimeInterval)K7UplinkChunkFrames/16000.0);
    [_players addObject:player];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),_queue,^{
        [self->_players removeObjectIdenticalTo:player];
    });
}

@end
