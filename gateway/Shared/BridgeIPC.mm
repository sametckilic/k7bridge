#import "BridgeIPC.h"
#import <CoreFoundation/CoreFoundation.h>

@interface K7BridgeIPC () @property(nonatomic,copy) K7MessageHandler handler; @end

static CFDataRef K7PortCallback(CFMessagePortRef local, SInt32 messageID, CFDataRef data, void *info) {
    K7BridgeIPC *bridge = (__bridge K7BridgeIPC *)info;
    NSDictionary *message = [NSJSONSerialization JSONObjectWithData:(__bridge NSData *)data options:0 error:nil];
    NSDictionary *reply = bridge.handler(message ?: @{}) ?: @{};
    return (__bridge_retained CFDataRef)[NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
}

@implementation K7BridgeIPC { CFMessagePortRef _port; CFRunLoopSourceRef _source; }
- (instancetype)initLocalPort:(NSString *)name handler:(K7MessageHandler)handler {
    if ((self=[super init])) { _handler=[handler copy]; CFMessagePortContext context={0,(__bridge void *)self,NULL,NULL,NULL};
        _port=CFMessagePortCreateLocal(kCFAllocatorDefault,(__bridge CFStringRef)name,K7PortCallback,&context,NULL);
        if (!_port) return nil; _source=CFMessagePortCreateRunLoopSource(kCFAllocatorDefault,_port,0);
        CFRunLoopAddSource(CFRunLoopGetMain(),_source,kCFRunLoopCommonModes); } return self;
}
- (void)dealloc { if (_source) { CFRunLoopRemoveSource(CFRunLoopGetMain(),_source,kCFRunLoopCommonModes); CFRelease(_source); } if (_port) CFRelease(_port); }
+ (NSDictionary *)send:(NSDictionary *)message toPort:(NSString *)name timeout:(NSTimeInterval)timeout {
    CFMessagePortRef remote=CFMessagePortCreateRemote(kCFAllocatorDefault,(__bridge CFStringRef)name); if (!remote) return nil;
    NSData *data=[NSJSONSerialization dataWithJSONObject:message options:0 error:nil]; CFDataRef response=NULL;
    SInt32 result=CFMessagePortSendRequest(remote,1,(__bridge CFDataRef)data,timeout,timeout,kCFRunLoopDefaultMode,&response); CFRelease(remote);
    if (result != kCFMessagePortSuccess || !response) return nil;
    NSDictionary *object=[NSJSONSerialization JSONObjectWithData:(__bridge NSData *)response options:0 error:nil]; CFRelease(response); return object;
}
@end
