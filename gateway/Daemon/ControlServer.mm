#import "ControlServer.h"
#import <Network/Network.h>
#import <Security/Security.h>

@interface K7ControlServer () @property(nonatomic,copy) K7ControlHandler handler; @end
@implementation K7ControlServer {
    uint16_t _port;
    uint64_t _outgoingSequence;
    NSData *_pkcs12;
    NSString *_password;
    nw_listener_t _listener;
    NSMutableSet *_connections;
    NSMutableSet *_authenticatedConnections;
    dispatch_queue_t _queue;
}
- (instancetype)initWithPort:(uint16_t)port PKCS12:(NSData *)pkcs12 password:(NSString *)password handler:(K7ControlHandler)handler {
    if ((self=[super init])) {
        _port=port; _pkcs12=pkcs12; _password=[password copy]; _handler=[handler copy];
        _connections=[NSMutableSet set]; _authenticatedConnections=[NSMutableSet set];
        _queue=dispatch_queue_create("com.k7bridge.control",DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (BOOL)start:(NSError **)error {
    SecIdentityRef identity=[self identity:error]; if (!identity) return NO;
    nw_parameters_t parameters=nw_parameters_create_secure_tcp(^(nw_protocol_options_t options) {
        sec_protocol_options_t tls=nw_tls_copy_sec_protocol_options(options); sec_identity_t value=sec_identity_create(identity);
        sec_protocol_options_set_local_identity(tls,value);
    },NW_PARAMETERS_DEFAULT_CONFIGURATION);
    CFRelease(identity);
    nw_protocol_stack_t stack=nw_parameters_copy_default_protocol_stack(parameters);
    nw_protocol_options_t websocket=nw_ws_create_options(nw_ws_version_13);
    nw_protocol_stack_prepend_application_protocol(stack,websocket);
    NSString *portString=[@(_port) stringValue]; _listener=nw_listener_create_with_port(portString.UTF8String,parameters);
    if (!_listener) { if(error)*error=[NSError errorWithDomain:@"K7Network" code:1 userInfo:@{NSLocalizedDescriptionKey:@"listener creation failed"}]; return NO; }
    nw_listener_set_queue(_listener,_queue);
    nw_advertise_descriptor_t service=nw_advertise_descriptor_create_bonjour_service("K7Bridge","_k7bridge._tcp",NULL);
    nw_listener_set_advertise_descriptor(_listener,service);
    __weak typeof(self) weakSelf=self;
    nw_listener_set_new_connection_handler(_listener,^(nw_connection_t connection){ [weakSelf accept:connection]; });
    nw_listener_set_state_changed_handler(_listener,^(nw_listener_state_t state,nw_error_t issue){ if(state==nw_listener_state_failed) NSLog(@"K7Bridge listener failed: %s",nw_error_get_error_domain(issue)==nw_error_domain_posix?strerror(nw_error_get_error_code(issue)):"network error"); });
    nw_listener_start(_listener); return YES;
}
- (void)accept:(nw_connection_t)connection {
    NSLog(@"K7Bridge accepted control connection");
    [_connections addObject:connection]; nw_connection_set_queue(connection,_queue);
    __weak typeof(self) weakSelf=self; nw_connection_set_state_changed_handler(connection,^(nw_connection_state_t state,nw_error_t error){
        __strong typeof(weakSelf) strongSelf=weakSelf; if(!strongSelf)return;
        if(state==nw_connection_state_ready){NSLog(@"K7Bridge control connection ready");[strongSelf receive:connection];}
        if(state==nw_connection_state_failed){NSLog(@"K7Bridge control connection failed: %d",error?nw_error_get_error_code(error):0);[strongSelf forget:connection];}
        if(state==nw_connection_state_cancelled){NSLog(@"K7Bridge control connection cancelled");[strongSelf forget:connection];}
    });
    nw_connection_start(connection);
}
- (void)receive:(nw_connection_t)connection {
    __weak typeof(self) weakSelf=self;
    nw_connection_receive_message(connection,^(dispatch_data_t content,nw_content_context_t context,bool complete,nw_error_t error){
        if(error||!content){NSLog(@"K7Bridge control receive ended: %d",error?nw_error_get_error_code(error):0);nw_connection_cancel(connection);return;} const void *buffer=NULL; size_t length=0; dispatch_data_t mapped=dispatch_data_create_map(content,&buffer,&length);
        NSData *data=[NSData dataWithBytes:buffer length:length]; if(mapped) (void)mapped;
        id object=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *request=[object isKindOfClass:NSDictionary.class]?object:@{};
        NSLog(@"K7Bridge received control message: %@",request[@"type"]?:@"invalid");
        NSDictionary *reply=weakSelf.handler(request?:@{});
        if ([request[@"type"] isEqual:@"pair"] && [reply[@"type"] isEqual:@"pairResult"]) {
            [weakSelf authenticate:connection];
        }
        [weakSelf sendDescriptor:reply to:connection];
        [weakSelf receive:connection];
    });
}
- (NSDictionary *)envelopeForDescriptor:(NSDictionary *)descriptor {
    NSString *type=[descriptor[@"type"] isKindOfClass:NSString.class]?descriptor[@"type"]:@"error";
    NSDictionary *payload=[descriptor[@"payload"] isKindOfClass:NSDictionary.class]?descriptor[@"payload"]:@{};
    NSISO8601DateFormatter *formatter=[NSISO8601DateFormatter new];
    formatter.formatOptions=NSISO8601DateFormatWithInternetDateTime|NSISO8601DateFormatWithFractionalSeconds;
    return @{@"v":@1,@"type":type,@"messageId":[NSUUID UUID].UUIDString,
        @"sequence":@(++_outgoingSequence),@"sentAt":[formatter stringFromDate:[NSDate date]],
        @"payload":payload,@"auth":[NSNull null]};
}
- (void)sendDescriptor:(NSDictionary *)descriptor to:(nw_connection_t)connection {
    [self sendEnvelope:[self envelopeForDescriptor:descriptor] to:connection];
}
- (void)sendEnvelope:(NSDictionary *)message to:(nw_connection_t)connection {
    NSData *data=[NSJSONSerialization dataWithJSONObject:message?:@{} options:0 error:nil];
    dispatch_data_t content=dispatch_data_create(data.bytes,data.length,_queue,^{(void)data;});
    nw_content_context_t context=nw_content_context_create("k7bridge.websocket");
    nw_protocol_metadata_t metadata=nw_ws_create_metadata(nw_ws_opcode_binary);
    nw_content_context_set_metadata_for_protocol(context,metadata);
    nw_connection_send(connection,content,context,true,^(nw_error_t error){if(error)NSLog(@"K7Bridge control send failed: %d",nw_error_get_error_code(error));});
}
- (void)authenticate:(nw_connection_t)connection {
    for (id other in [_authenticatedConnections copy]) {
        if ((nw_connection_t)other != connection) nw_connection_cancel((nw_connection_t)other);
    }
    [_authenticatedConnections removeAllObjects];
    [_authenticatedConnections addObject:connection];
    NSLog(@"K7Bridge control connection authenticated");
}
- (void)forget:(nw_connection_t)connection {
    [_authenticatedConnections removeObject:connection];
    [_connections removeObject:connection];
}
- (void)broadcastType:(NSString *)type payload:(NSDictionary *)payload {
    if (!type.length) return;
    dispatch_async(_queue,^{
        if (self->_authenticatedConnections.count==0) return;
        NSDictionary *envelope=[self envelopeForDescriptor:@{@"type":type,@"payload":payload?:@{}}];
        for(id connection in self->_authenticatedConnections) [self sendEnvelope:envelope to:(nw_connection_t)connection];
    });
}
- (SecIdentityRef)identity:(NSError **)error {
    CFArrayRef imported=NULL; NSDictionary *options=@{(__bridge id)kSecImportExportPassphrase:_password};
    OSStatus status=SecPKCS12Import((__bridge CFDataRef)_pkcs12,(__bridge CFDictionaryRef)options,&imported);
    if(status!=errSecSuccess||CFArrayGetCount(imported)==0){if(error)*error=[NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];if(imported)CFRelease(imported);return NULL;}
    NSDictionary *item=(__bridge NSDictionary *)CFArrayGetValueAtIndex(imported,0); SecIdentityRef identity=(SecIdentityRef)CFRetain((__bridge CFTypeRef)item[(__bridge id)kSecImportItemIdentity]); CFRelease(imported); return identity;
}
@end
