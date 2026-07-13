#import "RelayClient.h"
#import <sodium.h>

@implementation K7RelayClient { NSURL *_baseURL; NSString *_gatewayID; NSString *_secret; NSURLSession *_session; }
- (instancetype)initWithBaseURL:(NSURL *)baseURL gatewayID:(NSString *)gatewayID relaySecret:(NSString *)relaySecret {
    if((self=[super init])){_baseURL=baseURL;_gatewayID=[gatewayID copy];_secret=[relaySecret copy];NSURLSessionConfiguration *configuration=[NSURLSessionConfiguration ephemeralSessionConfiguration];configuration.timeoutIntervalForRequest=5;_session=[NSURLSession sessionWithConfiguration:configuration];}return self;
}
- (void)sendIncomingCall:(NSDictionary *)call sharedKey:(NSData *)sharedKey completion:(void(^)(NSError *))completion {
    if(sharedKey.length!=crypto_aead_chacha20poly1305_ietf_KEYBYTES){if(completion)completion([NSError errorWithDomain:@"K7Relay" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Gateway is not paired"}]);return;}
    NSData *clear=[NSJSONSerialization dataWithJSONObject:call options:NSJSONWritingSortedKeys error:nil];unsigned char nonce[crypto_aead_chacha20poly1305_ietf_NPUBBYTES];randombytes_buf(nonce,sizeof(nonce));
    NSMutableData *cipher=[NSMutableData dataWithLength:clear.length+crypto_aead_chacha20poly1305_ietf_ABYTES];unsigned long long cipherLength=0;
    crypto_aead_chacha20poly1305_ietf_encrypt((unsigned char *)cipher.mutableBytes,&cipherLength,(const unsigned char *)clear.bytes,clear.length,NULL,0,NULL,nonce,(const unsigned char *)sharedKey.bytes);cipher.length=(NSUInteger)cipherLength;
    NSDictionary *body=@{@"callId":call[@"callId"]?:@"",@"nonce":[[NSData dataWithBytes:nonce length:sizeof(nonce)]base64EncodedStringWithOptions:0],@"encryptedEnvelope":[cipher base64EncodedStringWithOptions:0]};
    NSURL *url=[_baseURL URLByAppendingPathComponent:[NSString stringWithFormat:@"v1/gateways/%@/voip-push",_gatewayID]];NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url];request.HTTPMethod=@"POST";[request setValue:@"application/json" forHTTPHeaderField:@"content-type"];[request setValue:[@"Bearer " stringByAppendingString:_secret] forHTTPHeaderField:@"authorization"];request.HTTPBody=[NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [[_session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){NSInteger status=[(NSHTTPURLResponse *)response statusCode];if(!error&&status!=202)error=[NSError errorWithDomain:@"K7Relay" code:status userInfo:@{NSLocalizedDescriptionKey:@"Relay rejected VoIP push"}];if(completion)completion(error);}]resume];
}
@end
