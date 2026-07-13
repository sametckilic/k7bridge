#import <Foundation/Foundation.h>
#import "ControlServer.h"
#import "Pairing.h"
#import "SMSStore.h"
#import "StateMachine.h"
#import "RelayClient.h"
#import "DeviceStatus.h"
#import "../Shared/BridgeIPC.h"
#import <sodium.h>
#import <unistd.h>

static NSString *const K7DataDirectory=@"/var/mobile/Library/K7Bridge";
static NSString *K7LocalHost(void){char name[256]={0};if(gethostname(name,sizeof(name)-1)!=0)return@"iphone.local";NSString *host=@(name);return[host hasSuffix:@".local"]?host:[host stringByAppendingString:@".local"];}

int main(int argc,char **argv){ @autoreleasepool {
    [[NSFileManager defaultManager] createDirectoryAtPath:K7DataDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    K7StateMachine *state=[K7StateMachine new]; K7SMSStore *sms=[K7SMSStore new]; K7Pairing *pairing=[K7Pairing new]; K7DeviceStatus *deviceStatus=[K7DeviceStatus new];
    NSData *identity=[NSData dataWithContentsOfFile:[K7DataDirectory stringByAppendingPathComponent:@"identity.p12"]];
    NSString *password=[NSString stringWithContentsOfFile:[K7DataDirectory stringByAppendingPathComponent:@"identity.password"] encoding:NSUTF8StringEncoding error:nil];
    if(!identity||!password){NSLog(@"K7Bridge fail-closed: identity.p12/password missing; run provision-device.sh");return 78;}
    __block uint64_t outgoingSequence=0,lastIncomingSequence=0; __block K7ControlServer *server; __block NSData *sharedKey=pairing.pairedSharedKey;
    NSDictionary *(^envelope)(NSString *,NSDictionary *)=^NSDictionary *(NSString *type,NSDictionary *payload){NSISO8601DateFormatter *formatter=[NSISO8601DateFormatter new];formatter.formatOptions=NSISO8601DateFormatWithInternetDateTime;return@{@"v":@1,@"type":type,@"messageId":[NSUUID UUID].UUIDString,@"sequence":@(++outgoingSequence),@"sentAt":[formatter stringFromDate:[NSDate date]],@"payload":payload?:@{}};};
    server=[[K7ControlServer alloc]initWithPort:7443 PKCS12:identity password:[password stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] handler:^NSDictionary *(NSDictionary *message){
        NSString *type=message[@"type"];NSDictionary *payload=message[@"payload"]?:@{};NSError *error=nil;
        if([type isEqual:@"pair"]){NSData *clientKey=[[NSData alloc]initWithBase64EncodedString:payload[@"clientPublicKey"] options:0];BOOL ok=[pairing consumeCode:payload[@"oneTimeCode"] clientPublicKey:clientKey sharedKey:&sharedKey];return envelope(ok?@"pairResult":@"error",ok?@{@"gatewayId":pairing.gatewayID}:@{@"code":@"pair_failed",@"message":@"Pairing code is invalid or already consumed"});}
        uint64_t incoming=[message[@"sequence"]unsignedLongLongValue];NSString *auth=message[@"auth"];
        NSData *canonical=[NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingSortedKeys error:nil];
        unsigned char digest[crypto_hash_sha256_BYTES];crypto_hash_sha256(digest,(const unsigned char *)canonical.bytes,canonical.length);
        NSMutableString *hex=[NSMutableString string];for(size_t i=0;i<sizeof(digest);i++)[hex appendFormat:@"%02x",digest[i]];
        NSString *signing=[NSString stringWithFormat:@"%@|%@|%llu|%@",type,message[@"messageId"],incoming,hex];unsigned char tag[crypto_auth_hmacsha256_BYTES];
        if(sharedKey){crypto_auth_hmacsha256_state h;crypto_auth_hmacsha256_init(&h,(const unsigned char *)sharedKey.bytes,sharedKey.length);NSData *signData=[signing dataUsingEncoding:NSUTF8StringEncoding];crypto_auth_hmacsha256_update(&h,(const unsigned char *)signData.bytes,signData.length);crypto_auth_hmacsha256_final(&h,tag);}
        NSString *expected=sharedKey?[[NSData dataWithBytes:tag length:sizeof(tag)]base64EncodedStringWithOptions:0]:nil;
        if(!sharedKey||incoming<=lastIncomingSequence||![auth isEqual:expected]){NSLog(@"K7Bridge rejected command %@ sequence %llu",type,incoming);return envelope(@"error",@{@"code":@"unauthorized",@"message":@"Authentication or sequence check failed"});}lastIncomingSequence=incoming;
        if([type isEqual:@"snapshotRequest"]){NSDictionary *device=[deviceStatus snapshot];NSLog(@"K7Bridge snapshot requested: %@",device);return envelope(@"snapshot",@{@"call":state.callID?[state snapshot]:[NSNull null],@"device":device,@"smsCursor":[NSNull null]});}
        if([type isEqual:@"dial"]){NSUUID *callID=[[NSUUID alloc]initWithUUIDString:payload[@"callId"]];if([state beginDialing:callID handle:payload[@"handle"] error:&error])[K7BridgeIPC send:@{@"type":@"dial",@"callId":callID.UUIDString,@"handle":payload[@"handle"]} toPort:@"com.k7bridge.telephony" timeout:2];}
        else if([@[@"answer",@"reject",@"end",@"dtmf"]containsObject:type])[K7BridgeIPC send:payload?@{@"type":type,@"payload":payload}:@{} toPort:@"com.k7bridge.telephony" timeout:2];
        else if([type isEqual:@"smsList"]){NSArray *items=[sms messagesBeforeRowID:[payload[@"cursor"]longLongValue] limit:[payload[@"limit"]unsignedIntegerValue] error:&error];return envelope(@"smsPage",@{@"items":items,@"nextCursor":[items.lastObject objectForKey:@"cursor"]?:[NSNull null]});}
        else if([type isEqual:@"smsSend"]){BOOL sent=[sms sendText:payload[@"text"] toAddress:payload[@"handle"] error:&error];return envelope(@"smsUpdate",@{@"smsId":payload[@"smsId"]?:@"",@"state":sent?@"sent":@"failed",@"error":error.localizedDescription?:[NSNull null]});}
        if(error)return envelope(@"error",@{@"code":@"command_failed",@"message":error.localizedDescription});return envelope(@"heartbeat",@{});
    }];
    NSError *serverError=nil;if(![server start:&serverError]){NSLog(@"K7Bridge control server failed: %@",serverError);return 70;}
    NSString *certificateHash=[NSString stringWithContentsOfFile:[K7DataDirectory stringByAppendingPathComponent:@"certificate.sha256"] encoding:NSUTF8StringEncoding error:nil];
    NSString *relayString=[NSString stringWithContentsOfFile:[K7DataDirectory stringByAppendingPathComponent:@"relay.url"] encoding:NSUTF8StringEncoding error:nil];if(!relayString){NSLog(@"K7Bridge fail-closed: relay.url missing");return 78;}
    NSDictionary *pairDoc=[pairing pairingDocumentWithHost:K7LocalHost() port:7443 certificateHash:[certificateHash stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]?:@"" relayURL:[NSURL URLWithString:[relayString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]]];
    NSData *pairJSON=[NSJSONSerialization dataWithJSONObject:pairDoc options:NSJSONWritingSortedKeys error:nil];NSString *encoded=[[pairJSON base64EncodedStringWithOptions:0]stringByReplacingOccurrencesOfString:@"+" withString:@"-"];encoded=[encoded stringByReplacingOccurrencesOfString:@"/" withString:@"_"];encoded=[encoded stringByReplacingOccurrencesOfString:@"=" withString:@""];
    [[NSString stringWithFormat:@"k7bridge://pair?d=%@",encoded]writeToFile:[K7DataDirectory stringByAppendingPathComponent:@"pairing-url.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    K7RelayClient *relay=[[K7RelayClient alloc]initWithBaseURL:[NSURL URLWithString:[relayString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]] gatewayID:pairing.gatewayID relaySecret:pairing.relaySecret];
    __unused K7BridgeIPC *events=[[K7BridgeIPC alloc]initLocalPort:@"com.k7bridge.gateway" handler:^NSDictionary *(NSDictionary *event){NSString *kind=event[@"type"];if([kind isEqual:@"incomingCall"]){NSUUID *identifier=[[NSUUID alloc]initWithUUIDString:event[@"callId"]];[state beginIncoming:identifier handle:event[@"handle"] error:nil];[relay sendIncomingCall:@{@"callId":identifier.UUIDString,@"handle":event[@"handle"]?:@"",@"displayName":event[@"displayName"]?:@""} sharedKey:sharedKey completion:^(NSError *issue){if(issue)NSLog(@"K7Bridge push failed: %@",issue);}];}else if([kind isEqual:@"callUpdate"]){NSString *next=event[@"state"];if([next isEqual:@"active"]){[state transition:K7CallStateConnecting error:nil];[state transition:K7CallStateActive error:nil];}else [state transition:K7CallStateEnded error:nil];}[server broadcast:envelope(kind,event)];return@{@"ok":@YES};}];
    [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *timer){[server broadcast:envelope(@"deviceStatus",[deviceStatus snapshot])];}];
    NSLog(@"K7Bridge started on WSS port 7443; gateway id %@",pairing.gatewayID);[[NSRunLoop currentRunLoop]run];
 } return 0; }
