#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <string.h>
#import "../Shared/BridgeIPC.h"

static BOOL K7CommandPortReady=NO;
static NSDictionary *K7LastHealth;
static K7BridgeIPC *K7IPC;
static void *K7TelephonyUtilitiesHandle;

static void K7Diagnostic(NSString *event,NSString *level,NSDictionary *fields) {
    [K7BridgeIPC send:@{ @"type":@"diagnostic", @"component":@"telephony",
        @"event":event?:@"unspecified", @"level":level?:@"info", @"fields":fields?:@{} }
        toPort:@"com.k7bridge.gateway" timeout:0.5];
}

static id K7CallCenter(void) {
    Class cls=NSClassFromString(@"TUCallCenter");
    SEL shared=NSSelectorFromString(@"sharedInstance");
    return cls&&[cls respondsToSelector:shared]?((id(*)(id,SEL))objc_msgSend)(cls,shared):nil;
}

static id K7FirstCall(void) {
    id center=K7CallCenter();
    SEL calls=NSSelectorFromString(@"currentCalls");
    NSArray *values=center&&[center respondsToSelector:calls]?((id(*)(id,SEL))objc_msgSend)(center,calls):nil;
    return values.firstObject;
}

static id K7ObjectValue(id value,NSString *selectorName) {
    SEL selector=NSSelectorFromString(selectorName);
    if (!value || ![value respondsToSelector:selector]) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(value,selector);
}

static BOOL K7BoolValue(id value,NSString *selectorName) {
    SEL selector=NSSelectorFromString(selectorName);
    return value&&[value respondsToSelector:selector]?
        ((BOOL(*)(id,SEL))objc_msgSend)(value,selector):NO;
}

static NSInteger K7IntegerValue(id value,NSString *selectorName) {
    SEL selector=NSSelectorFromString(selectorName);
    return value&&[value respondsToSelector:selector]?
        ((NSInteger(*)(id,SEL))objc_msgSend)(value,selector):0;
}

static NSUUID *K7CallIdentifier(id call) {
    id value=K7ObjectValue(call,@"callUUID");
    if ([value isKindOfClass:NSUUID.class]) return value;
    for (NSString *candidate in @[[value description]?:@"",
            [K7ObjectValue(call,@"uniqueProxyIdentifier") description]?:@""]) {
        NSUUID *identifier=[[NSUUID alloc] initWithUUIDString:candidate];
        if (identifier) return identifier;
    }
    return [NSUUID UUID];
}

static BOOL K7Emit(NSDictionary *event) {
    NSDictionary *reply=[K7BridgeIPC send:event toPort:@"com.k7bridge.gateway" timeout:1];
    BOOL accepted=[reply[@"ok"] boolValue];
    if (!accepted) NSLog(@"K7TelephonyBridge event rejected: %@",reply[@"error"]?:@"gateway unavailable");
    return accepted;
}

@interface K7CallObserver:NSObject
@property(nonatomic,strong) NSUUID *lastCallID;
@property(nonatomic,strong) id observedCall;
@property(nonatomic,copy) NSString *lastEmittedState;
@property(nonatomic,strong) NSDate *pendingDialDeadline;
- (void)refresh;
- (void)beginDial:(NSUUID *)callID;
- (void)reportHealth;
@end

static K7CallObserver *K7Observer;

@implementation K7CallObserver
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
    change:(NSDictionary *)change context:(void *)context {
    [self refresh];
}

- (void)emitState:(NSString *)state {
    if (!self.lastCallID || !state.length || [self.lastEmittedState isEqual:state]) return;
    if (K7Emit(@{ @"type":@"callUpdate", @"callId":self.lastCallID.UUIDString, @"state":state })) {
        self.lastEmittedState=state;
        NSLog(@"K7TelephonyBridge call %@ -> %@",self.lastCallID.UUIDString,state);
        K7Diagnostic(@"state_forwarded",@"info",@{@"callId":self.lastCallID.UUIDString,@"state":state});
    }
}

- (void)beginDial:(NSUUID *)callID {
    self.lastCallID=callID;
    self.lastEmittedState=@"dialing";
    self.pendingDialDeadline=[NSDate dateWithTimeIntervalSinceNow:5];
    NSLog(@"K7TelephonyBridge dial requested for call %@",callID.UUIDString);
    K7Diagnostic(@"dial_requested",@"info",@{@"callId":callID.UUIDString});
}

- (void)reportHealth {
    Class cls=NSClassFromString(@"TUCallCenter");
    SEL shared=NSSelectorFromString(@"sharedInstance");
    BOOL classAvailable=cls!=Nil;
    BOOL sharedAvailable=classAvailable&&[cls respondsToSelector:shared];
    id center=sharedAvailable?((id(*)(id,SEL))objc_msgSend)(cls,shared):nil;
    BOOL callsAvailable=center&&[center respondsToSelector:NSSelectorFromString(@"currentCalls")];
    NSArray *calls=callsAvailable?((id(*)(id,SEL))objc_msgSend)(center,NSSelectorFromString(@"currentCalls")):nil;
    NSDictionary *status=@{
        @"process":NSProcessInfo.processInfo.processName?:@"unknown",
        @"commandPortReady":@(K7CommandPortReady),
        @"callCenterClassAvailable":@(classAvailable),
        @"sharedInstanceAvailable":@(center!=nil),
        @"currentCallsAvailable":@(callsAvailable),
        @"callCount":@(calls.count),
        @"callObservationReady":@(K7CommandPortReady&&center&&callsAvailable)
    };
    if (![status isEqual:K7LastHealth]) {
        K7LastHealth=[status copy];
        NSLog(@"K7TelephonyBridge health: %@",status);
    }
    [K7BridgeIPC send:@{@"type":@"telephonyStatus",@"status":status}
        toPort:@"com.k7bridge.gateway" timeout:0.5];
}

- (void)refresh {
    id call=K7FirstCall();
    if (!call) {
        if (self.pendingDialDeadline && [self.pendingDialDeadline timeIntervalSinceNow]>0) return;
        [self emitState:@"ended"];
        if (self.observedCall) {
            @try { [self.observedCall removeObserver:self forKeyPath:@"status"]; }
            @catch(NSException *exception) {}
        }
        self.observedCall=nil;
        self.lastCallID=nil;
        self.lastEmittedState=nil;
        self.pendingDialDeadline=nil;
        return;
    }

    self.pendingDialDeadline=nil;

    if (self.observedCall!=call) {
        if (self.observedCall) {
            @try { [self.observedCall removeObserver:self forKeyPath:@"status"]; }
            @catch(NSException *exception) {}
        }
        self.observedCall=call;
        K7Diagnostic(@"call_object_observed",@"info",@{
            @"class":NSStringFromClass([call class])?:@"unknown",
            @"status":@(K7IntegerValue(call,@"status")),
            @"isIncoming":@(K7BoolValue(call,@"isIncoming")),
            @"isConnected":@(K7BoolValue(call,@"isConnected"))
        });
        @try { [call addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:NULL]; }
        @catch(NSException *exception) { NSLog(@"K7TelephonyBridge call status observation unavailable: %@",exception); }
    }

    BOOL incoming=K7BoolValue(call,@"isIncoming");
    if (incoming) {
        if (!self.lastCallID) {
            self.lastCallID=K7CallIdentifier(call);
            NSLog(@"K7TelephonyBridge discovered incoming call %@",self.lastCallID.UUIDString);
            K7Diagnostic(@"incoming_discovered",@"info",@{@"callId":self.lastCallID.UUIDString});
        }
        if (![self.lastEmittedState isEqual:@"incoming"]) {
            NSString *handle=[K7ObjectValue(call,@"destinationID") description]?:
                [K7ObjectValue(call,@"displayName") description]?:@"";
            if ([handle isEqual:@"(null)"]) handle=@"";
            if (K7Emit(@{ @"type":@"incomingCall", @"callId":self.lastCallID.UUIDString,
                @"handle":handle, @"displayName":@"" })) {
                self.lastEmittedState=@"incoming";
                K7Diagnostic(@"incoming_forwarded",@"info",@{@"callId":self.lastCallID.UUIDString,
                    @"handlePresent":@(handle.length>0)});
            }
        }
    }

    BOOL connected=K7BoolValue(call,@"isConnected");
    BOOL disconnected=K7ObjectValue(call,@"dateEnded")!=nil;
    if (disconnected) {
        [self emitState:@"ended"];
        return;
    }
    if (connected && self.lastCallID) {
        [self emitState:@"active"];
        return;
    }

    if (self.lastCallID && !incoming) [self emitState:@"connecting"];
}
@end

static NSDictionary *K7InvokeDTMF(id call,NSString *digit) {
    SEL selector=NSSelectorFromString(@"playDTMFToneForKey:");
    if (!call || ![call respondsToSelector:selector] || digit.length!=1)
        return @{@"ok":@NO,@"error":@"DTMF selector unavailable"};
    @try {
        NSMethodSignature *signature=[call methodSignatureForSelector:selector];
        if (!signature || signature.numberOfArguments<3)
            return @{@"ok":@NO,@"error":@"DTMF signature unavailable"};
        NSInvocation *invocation=[NSInvocation invocationWithMethodSignature:signature];
        invocation.target=call; invocation.selector=selector;
        const char *argument=[signature getArgumentTypeAtIndex:2];
        while (strchr("rnNoORV",argument[0])) argument++;
        if (argument[0]=='@') {
            id value=digit; [invocation setArgument:&value atIndex:2];
        } else {
            uint64_t value=[digit characterAtIndex:0]; [invocation setArgument:&value atIndex:2];
        }
        [invocation invoke];
        return @{@"ok":@YES};
    } @catch(NSException *exception) {
        return @{@"ok":@NO,@"error":exception.reason?:@"DTMF invocation failed"};
    }
}

static NSDictionary *K7Handle(NSDictionary *command) {
    NSString *type=[command[@"type"] isKindOfClass:NSString.class]?command[@"type"]:nil;
    NSDictionary *payload=[command[@"payload"] isKindOfClass:NSDictionary.class]?command[@"payload"]:command;
    id center=K7CallCenter();
    id call=K7FirstCall();
    if (!type.length) return @{@"ok":@NO,@"error":@"command type missing"};

    @try {
        if ([type isEqual:@"dial"]) {
            NSString *handle=[command[@"handle"] isKindOfClass:NSString.class]?command[@"handle"]:nil;
            NSUUID *callID=[command[@"callId"] isKindOfClass:NSString.class]?
                [[NSUUID alloc] initWithUUIDString:command[@"callId"]]:nil;
            Class requestClass=NSClassFromString(@"TUDialRequest");
            SEL initialize=NSSelectorFromString(@"initWithURL:");
            SEL canDial=NSSelectorFromString(@"canDialWithRequest:");
            SEL dial=NSSelectorFromString(@"dialWithRequest:");
            SEL dialAsync=NSSelectorFromString(@"dialWithRequest:completion:");
            NSURL *url=[NSURL URLWithString:[@"tel:" stringByAppendingString:handle?:@""]];
            if (!center || (![center respondsToSelector:dial] && ![center respondsToSelector:dialAsync]) || !requestClass ||
                ![requestClass instancesRespondToSelector:initialize] || !url || !handle.length || !callID)
                return @{@"ok":@NO,@"error":@"dial selector or arguments unavailable"};
            id request=((id(*)(id,SEL,id))objc_msgSend)([requestClass alloc],initialize,url);
            if (!request) return @{@"ok":@NO,@"error":@"dial request creation failed"};
            SEL endpoint=NSSelectorFromString(@"setEndpointOnCurrentDevice:");
            if ([request respondsToSelector:endpoint])
                ((void(*)(id,SEL,BOOL))objc_msgSend)(request,endpoint,YES);
            SEL dialAssist=NSSelectorFromString(@"setPerformDialAssist:");
            if ([request respondsToSelector:dialAssist])
                ((void(*)(id,SEL,BOOL))objc_msgSend)(request,dialAssist,YES);
            if ([center respondsToSelector:canDial] &&
                !((BOOL(*)(id,SEL,id))objc_msgSend)(center,canDial,request))
                return @{@"ok":@NO,@"error":@"system rejected dial request"};
            [K7Observer beginDial:callID];
            NSString *invokedSelector=nil;
            if ([center respondsToSelector:dialAsync]) {
                void (^completion)(void)=^{};
                ((void(*)(id,SEL,id,id))objc_msgSend)(center,dialAsync,request,completion);
                invokedSelector=@"dialWithRequest:completion:";
            } else {
                ((void(*)(id,SEL,id))objc_msgSend)(center,dial,request);
                invokedSelector=@"dialWithRequest:";
            }
            K7Diagnostic(@"dial_invoked",@"info",@{@"callId":callID.UUIDString,
                @"selector":invokedSelector,
                @"endpointOnCurrentDevice":@YES});
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ [K7Observer refresh]; });
            return @{@"ok":@YES};
        }

        if ([type isEqual:@"dtmf"]) return K7InvokeDTMF(call,payload[@"digit"]);
        if (![@[@"answer",@"reject",@"end"] containsObject:type])
            return @{@"ok":@NO,@"error":@"unsupported telephony command"};

        if ([type isEqual:@"answer"]) {
            Class requestClass=NSClassFromString(@"TUAnswerRequest");
            SEL initialize=NSSelectorFromString(@"initWithCall:");
            SEL answer=NSSelectorFromString(@"answerWithRequest:");
            if (!center || !call || !requestClass || ![center respondsToSelector:answer] ||
                ![requestClass instancesRespondToSelector:initialize])
                return @{@"ok":@NO,@"error":@"answer request API unavailable"};
            id request=((id(*)(id,SEL,id))objc_msgSend)([requestClass alloc],initialize,call);
            if (!request) return @{@"ok":@NO,@"error":@"answer request creation failed"};
            ((void(*)(id,SEL,id))objc_msgSend)(center,answer,request);
            K7Diagnostic(@"command_invoked",@"info",@{@"type":type,
                @"selector":@"answerWithRequest:"});
            return @{@"ok":@YES};
        }

        SEL selector=NSSelectorFromString(@"disconnectCall:");
        if (!center || !call || ![center respondsToSelector:selector])
            return @{@"ok":@NO,@"error":@"call selector unavailable"};
        ((void(*)(id,SEL,id))objc_msgSend)(center,selector,call);
        K7Diagnostic(@"command_invoked",@"info",@{@"type":type,
            @"selector":@"disconnectCall:"});
        return @{@"ok":@YES};
    } @catch(NSException *exception) {
        if ([type isEqual:@"dial"]) {
            K7Observer.lastCallID=nil;
            K7Observer.lastEmittedState=nil;
            K7Observer.pendingDialDeadline=nil;
        }
        return @{@"ok":@NO,@"error":exception.reason?:@"telephony invocation failed"};
    }
}

static void K7StartBridge(void) {
    if (K7Observer) return;
    if (!NSClassFromString(@"TUCallCenter")) {
        K7TelephonyUtilitiesHandle=dlopen(
            "/System/Library/PrivateFrameworks/TelephonyUtilities.framework/TelephonyUtilities",
            RTLD_LAZY|RTLD_LOCAL);
        if (!K7TelephonyUtilitiesHandle)
            NSLog(@"K7TelephonyBridge could not load TelephonyUtilities: %s",dlerror());
    }
    K7IPC=[[K7BridgeIPC alloc] initLocalPort:@"com.k7bridge.telephony"
        handler:^NSDictionary *(NSDictionary *message) { return K7Handle(message); }];
    K7CommandPortReady=K7IPC!=nil;
    K7Observer=[K7CallObserver new];
    id center=K7CallCenter();
    @try {
        [center addObserver:K7Observer forKeyPath:@"currentCalls"
            options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:NULL];
    } @catch(NSException *exception) {
        NSLog(@"K7TelephonyBridge currentCalls observation unavailable: %@",exception);
    }
    [NSTimer scheduledTimerWithTimeInterval:0.5 target:K7Observer selector:@selector(refresh)
        userInfo:nil repeats:YES];
    [K7Observer reportHealth];
    [NSTimer scheduledTimerWithTimeInterval:2 target:K7Observer selector:@selector(reportHealth)
        userInfo:nil repeats:YES];
    NSLog(@"K7TelephonyBridge loaded with KVO and 500 ms polling fallback");
    K7Diagnostic(@"tweak_loaded",@"info",@{@"process":NSProcessInfo.processInfo.processName?:@"unknown",
        @"commandPortReady":@(K7CommandPortReady)});
}

%ctor { @autoreleasepool {
    // Do not touch TelephonyUtilities while dyld is still constructing SpringBoard.
    // Initializing synchronously here can deadlock the process before its run loop starts.
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{ K7StartBridge(); });
    });
} }
