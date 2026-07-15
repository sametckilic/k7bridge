#import <Foundation/Foundation.h>
#import "ControlServer.h"
#import "Pairing.h"
#import "SMSStore.h"
#import "StateMachine.h"
#import "RelayClient.h"
#import "DeviceStatus.h"
#import "Diagnostics.h"
#import "MediaServer.h"
#import "../Shared/BridgeIPC.h"
#import <sodium.h>
#import <unistd.h>
#import <fcntl.h>
#import <sys/file.h>
#import <signal.h>

static NSString *const K7DataDirectory=@"/var/mobile/Library/K7Bridge";
static dispatch_source_t K7TerminationSource;

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
    K7Diagnostics *diagnostics=[K7Diagnostics shared];
    [diagnostics recordComponent:@"daemon" level:@"info" event:@"process_start"
        fields:@{@"version":@"diagnostics-v1"}];
    [[NSFileManager defaultManager] createDirectoryAtPath:K7DataDirectory
        withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *lockPath=[K7DataDirectory stringByAppendingPathComponent:@"k7bridged.lock"];
    int lockFD=open(lockPath.fileSystemRepresentation,O_CREAT|O_RDWR,0644);
    if (lockFD<0 || flock(lockFD,LOCK_EX|LOCK_NB)!=0) {
        [diagnostics recordComponent:@"daemon" level:@"error" event:@"duplicate_process_rejected" fields:@{}];
        return 75;
    }

    K7StateMachine *state=[K7StateMachine new];
    K7SMSStore *sms=[K7SMSStore new];
    K7Pairing *pairing=[K7Pairing new];
    K7DeviceStatus *deviceStatus=[K7DeviceStatus new];
    K7MediaServer *media=[K7MediaServer new];
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
    __block NSDate *lastTelephonyHeartbeat;
    __block NSDate *lastClientHeartbeat;
    __block NSDate *callBecameUnattendedAt;
    __block NSDictionary *lastTelephonyStatus=@{};
    __block NSDictionary *lastDeviceSnapshot;
    NSError *mediaError=nil;
    if (![media start:&mediaError]) {
        [diagnostics recordComponent:@"media" level:@"error" event:@"server_failed"
            fields:@{@"error":mediaError.localizedDescription?:@"unknown"}];
    }
    NSDictionary *(^statusSnapshot)(void)=^NSDictionary *{
        NSMutableDictionary *snapshot=[[deviceStatus snapshot] mutableCopy];
        BOOL clientAlive=server.hasAuthenticatedClient && lastClientHeartbeat &&
            [[NSDate date] timeIntervalSinceDate:lastClientHeartbeat]<15;
        snapshot[@"clientConnected"]=@(clientAlive);
        BOOL telephonyAlive=lastTelephonyHeartbeat && [[NSDate date] timeIntervalSinceDate:lastTelephonyHeartbeat]<5;
        snapshot[@"telephonyBridgeReady"]=@(telephonyAlive);
        snapshot[@"callObservationReady"]=telephonyAlive?(lastTelephonyStatus[@"callObservationReady"]?:@NO):@NO;
        snapshot[@"audioGatePassed"]=@(media.isReady);
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
            lastClientHeartbeat=[NSDate date];
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
        lastClientHeartbeat=[NSDate date];

        NSError *error=nil;
        if ([type isEqual:@"diagnosticsRequest"]) {
            NSUInteger limit=MAX(1,MIN([payload[@"limit"] unsignedIntegerValue]?:200,500));
            [diagnostics recordComponent:@"daemon" level:@"info" event:@"diagnostics_requested"
                fields:@{@"limit":@(limit)}];
            return K7Response(@"diagnosticsPage",@{@"entries":[diagnostics recentEntries:limit],
                @"telephonyStatus":lastTelephonyStatus?:@{}});
        }

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
                } else [media setActiveCall:callID sharedKey:sharedKey];
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
                else if ([type isEqual:@"answer"]) [media setActiveCall:callID sharedKey:sharedKey];
                else if ([type isEqual:@"reject"] || [type isEqual:@"end"]) [media setActiveCall:nil sharedKey:nil];
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
        [diagnostics recordComponent:@"daemon" level:@"error" event:@"control_server_failed"
            fields:@{@"error":serverError.localizedDescription?:@"unknown"}];
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
        if ([kind isEqual:@"diagnostic"]) {
            NSString *component=[event[@"component"] isKindOfClass:NSString.class]?event[@"component"]:@"unknown";
            NSString *name=[event[@"event"] isKindOfClass:NSString.class]?event[@"event"]:@"unspecified";
            NSString *level=[event[@"level"] isKindOfClass:NSString.class]?event[@"level"]:@"info";
            NSDictionary *fields=[event[@"fields"] isKindOfClass:NSDictionary.class]?event[@"fields"]:@{};
            [diagnostics recordComponent:component level:level event:name fields:fields];
            return @{@"ok":@YES};
        }
        if ([kind isEqual:@"telephonyStatus"]) {
            NSDictionary *status=[event[@"status"] isKindOfClass:NSDictionary.class]?event[@"status"]:@{};
            BOOL changed=![status isEqual:lastTelephonyStatus];
            lastTelephonyHeartbeat=[NSDate date];
            lastTelephonyStatus=[status copy];
            if (changed) {
                [diagnostics recordComponent:@"telephony" level:[status[@"callObservationReady"] boolValue]?@"info":@"warning"
                    event:@"health_changed" fields:status];
                [server broadcastType:@"deviceStatus" payload:statusSnapshot()];
            }
            return @{@"ok":@YES};
        }
        NSUUID *identifier=K7UUID(event[@"callId"]);
        if ([kind isEqual:@"incomingCall"]) {
            NSString *handle=[event[@"handle"] isKindOfClass:NSString.class]?event[@"handle"]:@"";
            if (!identifier || ![state beginIncoming:identifier handle:handle error:nil]) return @{@"ok":@NO,@"error":@"invalid incoming call"};
            NSLog(@"K7Bridge registered incoming call %@",identifier.UUIDString);
            [diagnostics recordComponent:@"call" level:@"info" event:@"incoming_registered"
                fields:@{@"callId":identifier.UUIDString}];
            if (relay) {
                [relay sendIncomingCall:@{@"callId":identifier.UUIDString,@"handle":handle,
                    @"displayName":event[@"displayName"]?:@""} sharedKey:sharedKey completion:^(NSError *issue) {
                    if (issue) NSLog(@"K7Bridge push failed: %@",issue);
                }];
            }
        } else if ([kind isEqual:@"callUpdate"]) {
            if (!identifier || ![identifier isEqual:state.callID]) return @{@"ok":@NO,@"error":@"unknown call"};
            NSString *next=event[@"state"];
            if ([next isEqual:@"connecting"]) {
                if (state.state==K7CallStateIncoming || state.state==K7CallStateDialing)
                    [state transition:K7CallStateConnecting error:nil];
                else if (state.state!=K7CallStateConnecting)
                    return @{@"ok":@NO,@"error":@"invalid connecting transition"};
            } else if ([next isEqual:@"active"]) {
                if (state.state==K7CallStateIncoming || state.state==K7CallStateDialing)
                    [state transition:K7CallStateConnecting error:nil];
                if (state.state==K7CallStateConnecting) [state transition:K7CallStateActive error:nil];
                else if (state.state!=K7CallStateActive)
                    return @{@"ok":@NO,@"error":@"invalid active transition"};
                [media setActiveCall:identifier sharedKey:sharedKey];
            } else if ([next isEqual:@"ended"]) {
                if (state.state!=K7CallStateEnded && ![state transition:K7CallStateEnded error:nil])
                    return @{@"ok":@NO,@"error":@"invalid ended transition"};
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
                    [state transition:K7CallStateIdle error:nil];
                });
                [media setActiveCall:nil sharedKey:nil];
            } else return @{@"ok":@NO,@"error":@"unsupported call state"};
            NSLog(@"K7Bridge call %@ -> %@",identifier.UUIDString,next);
            [diagnostics recordComponent:@"call" level:@"info" event:@"state_changed"
                fields:@{@"callId":identifier.UUIDString,@"state":next?:@"unknown"}];
        } else return @{@"ok":@NO,@"error":@"unsupported event"};

        NSMutableDictionary *payload=[event mutableCopy];
        [payload removeObjectForKey:@"type"];
        [server broadcastType:kind payload:payload];
        return @{@"ok":@YES};
    }];

    [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *timer) {
        NSDictionary *snapshot=statusSnapshot();
        [server broadcastType:@"deviceStatus" payload:snapshot];
        if (!lastDeviceSnapshot || ![lastDeviceSnapshot isEqual:snapshot]) {
            lastDeviceSnapshot=[snapshot copy];
            [diagnostics recordComponent:@"device" level:@"info" event:@"status_changed" fields:snapshot];
        }
    }];
    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        // Ringing is allowed to continue while PushKit/CallKit wakes the client.
        // The safety timeout only applies after a call has been answered.
        BOOL hasActiveCall=state.state==K7CallStateConnecting || state.state==K7CallStateActive;
        if (!hasActiveCall) {
            callBecameUnattendedAt=nil;
            return;
        }
        if ([statusSnapshot()[@"clientConnected"] boolValue]) {
            callBecameUnattendedAt=nil;
            return;
        }
        if (!callBecameUnattendedAt) {
            callBecameUnattendedAt=[NSDate date];
            return;
        }
        if ([[NSDate date] timeIntervalSinceDate:callBecameUnattendedAt]<20) return;
        NSUUID *callID=state.callID;
        callBecameUnattendedAt=[NSDate date];
        if (!callID) return;
        [diagnostics recordComponent:@"call" level:@"warning" event:@"client_timeout_end_requested"
            fields:@{@"callId":callID.UUIDString}];
        [K7BridgeIPC send:@{@"type":@"end",@"payload":@{@"callId":callID.UUIDString}}
            toPort:@"com.k7bridge.telephony" timeout:2];
    }];
    signal(SIGTERM,SIG_IGN);
    K7TerminationSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGTERM,0,
        dispatch_get_main_queue());
    dispatch_source_set_event_handler(K7TerminationSource,^{
        [diagnostics recordComponent:@"daemon" level:@"info" event:@"graceful_shutdown" fields:@{}];
        [media stop];
        [server stop];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{ exit(0); });
    });
    dispatch_resume(K7TerminationSource);
    NSLog(@"K7Bridge started on WSS port 7443; gateway id %@",pairing.gatewayID);
    [diagnostics recordComponent:@"daemon" level:@"info" event:@"gateway_ready"
        fields:@{@"port":@7443,@"gatewayId":pairing.gatewayID?:@"unknown"}];
    [[NSRunLoop currentRunLoop] run];
} return 0; }
