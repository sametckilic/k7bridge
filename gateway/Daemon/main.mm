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

static NSString *K7LocalHost(void) {
    char name[256]={0};
    if (gethostname(name,sizeof(name)-1)!=0) return @"iphone.local";
    NSString *host=@(name);
    return [host hasSuffix:@".local"]?host:[host stringByAppendingString:@".local"];
}

static NSDictionary *K7Response(NSString *type, NSDictionary *payload) {
    return @{@"type":type?:@"error",@"payload":payload?:@{}};
}

static NSDictionary *K7Error(NSString *code, NSString *message) {
    return K7Response(@"error",@{@"code":code?:@"unknown",@"message":message?:@"Unknown gateway error"});
}

static NSError *K7CommandError(NSString *message) {
    return [NSError errorWithDomain:@"K7Command" code:1
        userInfo:@{NSLocalizedDescriptionKey:message?:@"Command failed"}];
}

static NSUUID *K7UUID(id value) {
    return [value isKindOfClass:NSString.class]?[[NSUUID alloc] initWithUUIDString:value]:nil;
}

static BOOL K7ValidHandle(NSString *value) {
    if (![value isKindOfClass:NSString.class] || ![value hasPrefix:@"+"] || value.length<8 || value.length>16) return NO;
    NSCharacterSet *nonDigits=[[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return [[value substringFromIndex:1] rangeOfCharacterFromSet:nonDigits].location==NSNotFound;
}

int main(int argc,char **argv) { @autoreleasepool {
    [[NSFileManager defaultManager] createDirectoryAtPath:K7DataDirectory
        withIntermediateDirectories:YES attributes:nil error:nil];

    K7StateMachine *state=[K7StateMachine new];
    K7SMSStore *sms=[K7SMSStore new];
    K7Pairing *pairing=[K7Pairing new];
    K7DeviceStatus *deviceStatus=[K7DeviceStatus new];
    NSData *identity=[NSData dataWithContentsOfFile:[K7DataDirectory stringByAppendingPathComponent:@"identity.p12"]];
    NSString *password=[NSString stringWithContentsOfFile:[K7DataDirectory stringByAppendingPathComponent:@"identity.password"]
        encoding:NSUTF8StringEncoding error:nil];
    if (!identity || !password) {
        NSLog(@"K7Bridge fail-closed: identity.p12/password missing; run provision-device.sh");
        return 78;
    }

    __block uint64_t lastIncomingSequence=0;
    __block K7ControlServer *server;
    __block NSData *sharedKey=pairing.pairedSharedKey;
    NSDictionary *(^statusSnapshot)(void)=^NSDictionary *{
        NSMutableDictionary *snapshot=[[deviceStatus snapshot] mutableCopy];
        snapshot[@"clientConnected"]=@YES;
        return snapshot;
    };

    server=[[K7ControlServer alloc] initWithPort:7443 PKCS12:identity
        password:[password stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        handler:^NSDictionary *(NSDictionary *message) {
        NSString *type=[message[@"type"] isKindOfClass:NSString.class]?message[@"type"]:nil;
        NSDictionary *payload=[message[@"payload"] isKindOfClass:NSDictionary.class]?message[@"payload"]:@{};
        if (!type.length) return K7Error(@"invalid_message",@"Message type is missing");

        if ([type isEqual:@"pair"]) {
            NSString *encodedKey=[payload[@"clientPublicKey"] isKindOfClass:NSString.class]?payload[@"clientPublicKey"]:nil;
            NSData *clientKey=encodedKey?[[NSData alloc] initWithBase64EncodedString:encodedKey options:0]:nil;
            BOOL ok=[pairing consumeCode:payload[@"oneTimeCode"] clientPublicKey:clientKey sharedKey:&sharedKey];
            if (!ok) return K7Error(@"pair_failed",@"Pairing code or client key is invalid");
            lastIncomingSequence=0;
            return K7Response(@"pairResult",@{@"gatewayId":pairing.gatewayID});
        }

        uint64_t incoming=[message[@"sequence"] unsignedLongLongValue];
        NSString *messageID=[message[@"messageId"] isKindOfClass:NSString.class]?message[@"messageId"]:nil;
        NSString *encodedAuth=[message[@"auth"] isKindOfClass:NSString.class]?message[@"auth"]:nil;
        NSError *jsonError=nil;
        NSData *canonical=[NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingSortedKeys error:&jsonError];
        if (!canonical || !messageID.length || incoming==0) return K7Error(@"invalid_message",@"Invalid command envelope");

        unsigned char digest[crypto_hash_sha256_BYTES];
        crypto_hash_sha256(digest,(const unsigned char *)canonical.bytes,canonical.length);
        NSMutableString *hex=[NSMutableString stringWithCapacity:sizeof(digest)*2];
        for (size_t i=0;i<sizeof(digest);i++) [hex appendFormat:@"%02x",digest[i]];
        NSString *signing=[NSString stringWithFormat:@"%@|%@|%llu|%@",type,messageID,incoming,hex];
        NSData *signData=[signing dataUsingEncoding:NSUTF8StringEncoding];
        unsigned char tag[crypto_auth_hmacsha256_BYTES]={0};
        if (sharedKey.length==32) {
            crypto_auth_hmacsha256_state h;
            crypto_auth_hmacsha256_init(&h,(const unsigned char *)sharedKey.bytes,sharedKey.length);
            crypto_auth_hmacsha256_update(&h,(const unsigned char *)signData.bytes,signData.length);
            crypto_auth_hmacsha256_final(&h,tag);
        }
        NSData *provided=encodedAuth?[[NSData alloc] initWithBase64EncodedString:encodedAuth options:0]:nil;
        BOOL authOK=sharedKey.length==32 && provided.length==sizeof(tag) && sodium_memcmp(provided.bytes,tag,sizeof(tag))==0;
        if (!authOK || incoming<=lastIncomingSequence) {
            NSLog(@"K7Bridge rejected command %@ sequence %llu",type,incoming);
            return K7Error(@"unauthorized",@"Authentication or sequence check failed");
        }
        lastIncomingSequence=incoming;

        NSError *error=nil;
        if ([type isEqual:@"snapshotRequest"]) {
            BOOL hasCall=state.state!=K7CallStateIdle && state.state!=K7CallStateEnded && state.state!=K7CallStateFailed;
            return K7Response(@"snapshot",@{@"call":hasCall?[state snapshot]:[NSNull null],
                @"device":statusSnapshot(),@"smsCursor":[NSNull null]});
        }

        if ([type isEqual:@"dial"]) {
            NSString *handle=[payload[@"handle"] isKindOfClass:NSString.class]?payload[@"handle"]:nil;
            NSUUID *callID=K7UUID(payload[@"callId"]);
            if (!callID || !K7ValidHandle(handle)) error=K7CommandError(@"Invalid call id or E.164 phone number");
            else if ([state beginDialing:callID handle:handle error:&error]) {
                NSDictionary *result=[K7BridgeIPC send:@{@"type":@"dial",@"callId":callID.UUIDString,@"handle":handle}
                    toPort:@"com.k7bridge.telephony" timeout:2];
                if (![result[@"ok"] boolValue]) {
                    error=K7CommandError(result[@"error"]?:@"Telephony bridge is unavailable");
                    [state transition:K7CallStateFailed error:nil];
                }
            }
        } else if ([@[@"answer",@"reject",@"end",@"dtmf"] containsObject:type]) {
            NSUUID *callID=K7UUID(payload[@"callId"]);
            if (!callID || ![callID isEqual:state.callID]) error=K7CommandError(@"Call id does not match the active call");
            else if ([type isEqual:@"dtmf"] &&
                     (![payload[@"digit"] isKindOfClass:NSString.class] || [payload[@"digit"] length]!=1 ||
                      [@"0123456789*#" rangeOfString:payload[@"digit"]].location==NSNotFound)) {
                error=K7CommandError(@"Invalid DTMF digit");
            } else {
                NSDictionary *result=[K7BridgeIPC send:@{@"type":type,@"payload":payload}
                    toPort:@"com.k7bridge.telephony" timeout:2];
                if (![result[@"ok"] boolValue]) error=K7CommandError(result[@"error"]?:@"Telephony bridge is unavailable");
            }
        } else if ([type isEqual:@"smsList"]) {
            NSUInteger limit=[payload[@"limit"] unsignedIntegerValue];
            NSArray *items=[sms messagesBeforeRowID:[payload[@"cursor"] longLongValue] limit:limit error:&error];
            if (!error) {
                id cursor=[items.lastObject objectForKey:@"cursor"];
                return K7Response(@"smsPage",@{@"items":items,
                    @"nextCursor":cursor?[cursor stringValue]:[NSNull null]});
            }
        } else if ([type isEqual:@"smsSend"]) {
            NSString *text=[payload[@"text"] isKindOfClass:NSString.class]?payload[@"text"]:nil;
            NSString *handle=[payload[@"handle"] isKindOfClass:NSString.class]?payload[@"handle"]:nil;
            BOOL valid=text.length>0 && text.length<=1600 && K7ValidHandle(handle);
            if (!valid) error=K7CommandError(@"Invalid SMS recipient or text length");
            BOOL sent=valid && [sms sendText:text toAddress:handle error:&error];
            return K7Response(@"smsUpdate",@{@"smsId":payload[@"smsId"]?:@"",
                @"state":sent?@"sent":@"failed",@"error":error.localizedDescription?:[NSNull null]});
        } else if ([type isEqual:@"heartbeat"]) {
            return K7Response(@"heartbeat",@{});
        } else {
            return K7Error(@"unknown_command",[NSString stringWithFormat:@"Unsupported command: %@",type]);
        }

        if (error) return K7Error(@"command_failed",error.localizedDescription);
        return K7Response(@"heartbeat",@{});
    }];

    NSError *serverError=nil;
    if (![server start:&serverError]) {
        NSLog(@"K7Bridge control server failed: %@",serverError);
        return 70;
    }

    NSString *certificateHash=[NSString stringWithContentsOfFile:[K7DataDirectory stringByAppendingPathComponent:@"certificate.sha256"]
        encoding:NSUTF8StringEncoding error:nil];
    NSString *relayString=[NSString stringWithContentsOfFile:[K7DataDirectory stringByAppendingPathComponent:@"relay.url"]
        encoding:NSUTF8StringEncoding error:nil];
    if (!relayString) {
        NSLog(@"K7Bridge fail-closed: relay.url missing");
        return 78;
    }
    relayString=[relayString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSURL *relayURL=[NSURL URLWithString:relayString];
    if (!relayURL) {
        NSLog(@"K7Bridge fail-closed: relay.url is invalid");
        return 78;
    }
    NSDictionary *pairDoc=[pairing pairingDocumentWithHost:K7LocalHost() port:7443
        certificateHash:[certificateHash stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]?:@""
        relayURL:relayURL];
    NSData *pairJSON=[NSJSONSerialization dataWithJSONObject:pairDoc options:NSJSONWritingSortedKeys error:nil];
    NSString *encoded=[[pairJSON base64EncodedStringWithOptions:0] stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    encoded=[encoded stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    encoded=[encoded stringByReplacingOccurrencesOfString:@"=" withString:@""];
    [[NSString stringWithFormat:@"k7bridge://pair?d=%@",encoded]
        writeToFile:[K7DataDirectory stringByAppendingPathComponent:@"pairing-url.txt"]
        atomically:YES encoding:NSUTF8StringEncoding error:nil];

    BOOL relayEnabled=relayURL && ![relayURL.host isEqual:@"example.invalid"];
    K7RelayClient *relay=relayEnabled?[[K7RelayClient alloc] initWithBaseURL:relayURL
        gatewayID:pairing.gatewayID relaySecret:pairing.relaySecret]:nil;
    __unused K7BridgeIPC *events=[[K7BridgeIPC alloc] initLocalPort:@"com.k7bridge.gateway"
        handler:^NSDictionary *(NSDictionary *event) {
        NSString *kind=[event[@"type"] isKindOfClass:NSString.class]?event[@"type"]:nil;
        NSUUID *identifier=K7UUID(event[@"callId"]);
        if ([kind isEqual:@"incomingCall"]) {
            NSString *handle=[event[@"handle"] isKindOfClass:NSString.class]?event[@"handle"]:@"";
            if (!identifier || ![state beginIncoming:identifier handle:handle error:nil]) return @{@"ok":@NO,@"error":@"invalid incoming call"};
            if (relay) {
                [relay sendIncomingCall:@{@"callId":identifier.UUIDString,@"handle":handle,
                    @"displayName":event[@"displayName"]?:@""} sharedKey:sharedKey completion:^(NSError *issue) {
                    if (issue) NSLog(@"K7Bridge push failed: %@",issue);
                }];
            }
        } else if ([kind isEqual:@"callUpdate"]) {
            if (!identifier || ![identifier isEqual:state.callID]) return @{@"ok":@NO,@"error":@"unknown call"};
            NSString *next=event[@"state"];
            if ([next isEqual:@"active"]) {
                if (state.state==K7CallStateIncoming || state.state==K7CallStateDialing)
                    [state transition:K7CallStateConnecting error:nil];
                [state transition:K7CallStateActive error:nil];
            } else if ([next isEqual:@"ended"]) {
                [state transition:K7CallStateEnded error:nil];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
                    [state transition:K7CallStateIdle error:nil];
                });
            } else return @{@"ok":@NO,@"error":@"unsupported call state"};
        } else return @{@"ok":@NO,@"error":@"unsupported event"};

        NSMutableDictionary *payload=[event mutableCopy];
        [payload removeObjectForKey:@"type"];
        [server broadcastType:kind payload:payload];
        return @{@"ok":@YES};
    }];

    [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *timer) {
        [server broadcastType:@"deviceStatus" payload:statusSnapshot()];
    }];
    NSLog(@"K7Bridge started on WSS port 7443; gateway id %@",pairing.gatewayID);
    [[NSRunLoop currentRunLoop] run];
} return 0; }
