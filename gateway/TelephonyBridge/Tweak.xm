#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <string.h>
#import "../Shared/BridgeIPC.h"

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

static id K7Value(id value,NSString *key) {
    @try { return [value valueForKey:key]; }
    @catch(NSException *exception) { return nil; }
}

static void K7Emit(NSDictionary *event) {
    NSDictionary *reply=[K7BridgeIPC send:event toPort:@"com.k7bridge.gateway" timeout:1];
    if (![reply[@"ok"] boolValue]) NSLog(@"K7TelephonyBridge event rejected: %@",reply[@"error"]?:@"gateway unavailable");
}

@interface K7CallObserver:NSObject
@property(nonatomic,strong) NSUUID *lastCallID;
@property(nonatomic,strong) id observedCall;
- (void)refresh;
@end

static K7CallObserver *K7Observer;

@implementation K7CallObserver
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
    change:(NSDictionary *)change context:(void *)context {
    [self refresh];
}

- (void)refresh {
    id call=K7FirstCall();
    if (!call) {
        if (self.lastCallID) K7Emit(@{@"type":@"callUpdate",@"callId":self.lastCallID.UUIDString,@"state":@"ended"});
        if (self.observedCall) {
            @try { [self.observedCall removeObserver:self forKeyPath:@"status"]; }
            @catch(NSException *exception) {}
        }
        self.observedCall=nil;
        self.lastCallID=nil;
        return;
    }

    if (self.observedCall!=call) {
        if (self.observedCall) {
            @try { [self.observedCall removeObserver:self forKeyPath:@"status"]; }
            @catch(NSException *exception) {}
        }
        self.observedCall=call;
        @try { [call addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:NULL]; }
        @catch(NSException *exception) { NSLog(@"K7TelephonyBridge call status observation unavailable: %@",exception); }
    }

    BOOL connected=[K7Value(call,@"connected") boolValue]||[K7Value(call,@"isConnected") boolValue];
    BOOL disconnected=[K7Value(call,@"disconnected") boolValue]||[K7Value(call,@"isDisconnected") boolValue];
    if (self.lastCallID && (connected||disconnected)) {
        K7Emit(@{@"type":@"callUpdate",@"callId":self.lastCallID.UUIDString,
            @"state":connected?@"active":@"ended"});
        if (disconnected) self.lastCallID=nil;
        return;
    }

    BOOL incoming=[K7Value(call,@"incoming") boolValue]||[K7Value(call,@"isIncoming") boolValue];
    if (!incoming || self.lastCallID) return;
    NSString *identifier=[K7Value(call,@"uniqueProxyIdentifier") description];
    NSUUID *callID=[[NSUUID alloc] initWithUUIDString:identifier];
    if (!callID) callID=[NSUUID UUID];
    self.lastCallID=callID;
    NSString *handle=[K7Value(call,@"destinationID") description]?:[K7Value(call,@"displayName") description]?:@"";
    K7Emit(@{@"type":@"incomingCall",@"callId":callID.UUIDString,@"handle":handle,@"displayName":@""});
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
            SEL dial=NSSelectorFromString(@"dialWithRequest:");
            if (!center || ![center respondsToSelector:dial] || !requestClass || !handle.length || !callID)
                return @{@"ok":@NO,@"error":@"dial selector or arguments unavailable"};
            id request=[requestClass new];
            [request setValue:handle forKey:@"dialString"];
            K7Observer.lastCallID=callID;
            ((void(*)(id,SEL,id))objc_msgSend)(center,dial,request);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ [K7Observer refresh]; });
            return @{@"ok":@YES};
        }

        if ([type isEqual:@"dtmf"]) return K7InvokeDTMF(call,payload[@"digit"]);
        if (![@[@"answer",@"reject",@"end"] containsObject:type])
            return @{@"ok":@NO,@"error":@"unsupported telephony command"};
        SEL selector=NSSelectorFromString([type isEqual:@"answer"]?@"answer":@"disconnect");
        if (!call || ![call respondsToSelector:selector])
            return @{@"ok":@NO,@"error":@"call selector unavailable"};
        ((void(*)(id,SEL))objc_msgSend)(call,selector);
        return @{@"ok":@YES};
    } @catch(NSException *exception) {
        return @{@"ok":@NO,@"error":exception.reason?:@"telephony invocation failed"};
    }
}

%ctor { @autoreleasepool {
    static K7BridgeIPC *ipc;
    ipc=[[K7BridgeIPC alloc] initLocalPort:@"com.k7bridge.telephony"
        handler:^NSDictionary *(NSDictionary *message) { return K7Handle(message); }];
    (void)ipc;
    K7Observer=[K7CallObserver new];
    id center=K7CallCenter();
    @try {
        [center addObserver:K7Observer forKeyPath:@"currentCalls"
            options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:NULL];
    } @catch(NSException *exception) {
        NSLog(@"K7TelephonyBridge currentCalls observation unavailable: %@",exception);
    }
    NSLog(@"K7TelephonyBridge loaded; runtime selectors will be device-verified before use");
} }
