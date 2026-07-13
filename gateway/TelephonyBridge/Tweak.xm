#import <Foundation/Foundation.h>
#import <objc/message.h>
#import "../Shared/BridgeIPC.h"

static id K7CallCenter(void){Class cls=NSClassFromString(@"TUCallCenter");SEL shared=NSSelectorFromString(@"sharedInstance");return cls&&[cls respondsToSelector:shared]?((id(*)(id,SEL))objc_msgSend)(cls,shared):nil;}
static id K7FirstCall(void){id center=K7CallCenter();SEL calls=NSSelectorFromString(@"currentCalls");NSArray *values=center&&[center respondsToSelector:calls]?((id(*)(id,SEL))objc_msgSend)(center,calls):nil;return values.firstObject;}
static id K7Value(id value,NSString *key){@try{return[value valueForKey:key];}@catch(NSException *exception){return nil;}}

@interface K7CallObserver:NSObject @property(nonatomic,strong)NSUUID *lastCallID;@property(nonatomic,strong)id observedCall;@end
@implementation K7CallObserver
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    id call=K7FirstCall();if(!call){if(self.observedCall){@try{[self.observedCall removeObserver:self forKeyPath:@"status"];}@catch(NSException *exception){}}self.observedCall=nil;self.lastCallID=nil;return;}
    if(self.observedCall!=call){if(self.observedCall){@try{[self.observedCall removeObserver:self forKeyPath:@"status"];}@catch(NSException *exception){}}self.observedCall=call;@try{[call addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:NULL];}@catch(NSException *exception){}}
    BOOL connected=[K7Value(call,@"connected")boolValue]||[K7Value(call,@"isConnected")boolValue];BOOL disconnected=[K7Value(call,@"disconnected")boolValue]||[K7Value(call,@"isDisconnected")boolValue];
    if(self.lastCallID&&(connected||disconnected)){[K7BridgeIPC send:@{@"type":@"callUpdate",@"callId":self.lastCallID.UUIDString,@"state":connected?@"active":@"ended"} toPort:@"com.k7bridge.gateway" timeout:1];if(disconnected)self.lastCallID=nil;return;}
    BOOL incoming=[K7Value(call,@"incoming")boolValue]||[K7Value(call,@"isIncoming")boolValue];if(!incoming)return;
    NSString *identifier=[K7Value(call,@"uniqueProxyIdentifier")description];NSUUID *callID=[[NSUUID alloc]initWithUUIDString:identifier];if(!callID)callID=[NSUUID UUID];if([self.lastCallID isEqual:callID])return;self.lastCallID=callID;
    NSString *handle=[K7Value(call,@"destinationID")description]?:[K7Value(call,@"displayName")description]?:@"";
    [K7BridgeIPC send:@{@"type":@"incomingCall",@"callId":callID.UUIDString,@"handle":handle,@"displayName":@""} toPort:@"com.k7bridge.gateway" timeout:1];
}
@end
static NSDictionary *K7Handle(NSDictionary *command){NSString *type=command[@"type"];NSDictionary *payload=command[@"payload"]?:command;id center=K7CallCenter();id call=K7FirstCall();
    if([type isEqual:@"dial"]){SEL dial=NSSelectorFromString(@"dialWithRequest:");Class requestClass=NSClassFromString(@"TUDialRequest");id request=[requestClass new];[request setValue:command[@"handle"] forKey:@"dialString"];if(center&&[center respondsToSelector:dial])((void(*)(id,SEL,id))objc_msgSend)(center,dial,request);else return@{@"ok":@NO,@"error":@"dial selector unavailable"};}
    else{SEL selector=NSSelectorFromString([type isEqual:@"answer"]?@"answer":([type isEqual:@"dtmf"]?@"playDTMFToneForKey:":@"disconnect"));if(!call||![call respondsToSelector:selector])return@{@"ok":@NO,@"error":@"call selector unavailable"};if([type isEqual:@"dtmf"])((void(*)(id,SEL,id))objc_msgSend)(call,selector,payload[@"digit"]);else((void(*)(id,SEL))objc_msgSend)(call,selector);}return@{@"ok":@YES};}

%ctor { @autoreleasepool { static K7BridgeIPC *ipc;static K7CallObserver *observer;ipc=[[K7BridgeIPC alloc]initLocalPort:@"com.k7bridge.telephony" handler:^NSDictionary *(NSDictionary *message){return K7Handle(message);}];observer=[K7CallObserver new];id center=K7CallCenter();@try{[center addObserver:observer forKeyPath:@"currentCalls" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:NULL];}@catch(NSException *exception){NSLog(@"K7TelephonyBridge currentCalls observation unavailable: %@",exception);};NSLog(@"K7TelephonyBridge loaded; runtime selectors will be device-verified before use"); } }
