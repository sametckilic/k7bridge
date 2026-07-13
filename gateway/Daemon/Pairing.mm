#import "Pairing.h"
#import <sodium.h>

static NSString *const K7PairingStatePath=@"/var/mobile/Library/K7Bridge/pairing-state.json";

@implementation K7Pairing {
    unsigned char _secret[crypto_kx_SECRETKEYBYTES];
    BOOL _consumed;
    NSData *_pairedClientPublicKey;
}

- (instancetype)init {
    if ((self=[super init])) {
        if (sodium_init() < 0) return nil;
        if (![self loadState]) {
            unsigned char pub[crypto_kx_PUBLICKEYBYTES];
            crypto_kx_keypair(pub, _secret);
            _publicKey=[NSData dataWithBytes:pub length:sizeof(pub)];
            _gatewayID=[NSUUID UUID].UUIDString;
            _oneTimeCode=[NSString stringWithFormat:@"%06u", arc4random_uniform(1000000)];
            unsigned char token[32]; randombytes_buf(token,sizeof(token));
            _relaySecret=[[NSData dataWithBytes:token length:sizeof(token)] base64EncodedStringWithOptions:0];
            [self saveState];
        }
    }
    return self;
}

- (BOOL)loadState {
    NSData *data=[NSData dataWithContentsOfFile:K7PairingStatePath];
    NSDictionary *state=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    if (![state isKindOfClass:NSDictionary.class]) return NO;
    NSData *publicKey=[[NSData alloc]initWithBase64EncodedString:state[@"publicKey"] options:0];
    NSData *secret=[[NSData alloc]initWithBase64EncodedString:state[@"secretKey"] options:0];
    NSData *shared=[[NSData alloc]initWithBase64EncodedString:state[@"sharedKey"] options:0];
    NSData *client=[[NSData alloc]initWithBase64EncodedString:state[@"clientPublicKey"] options:0];
    BOOL consumed=[state[@"consumed"]boolValue];
    if (![state[@"gatewayID"]isKindOfClass:NSString.class] || ![state[@"oneTimeCode"]isKindOfClass:NSString.class] ||
        ![state[@"relaySecret"]isKindOfClass:NSString.class] || publicKey.length!=crypto_kx_PUBLICKEYBYTES) return NO;
    if ((!consumed && secret.length!=crypto_kx_SECRETKEYBYTES) ||
        (consumed && (shared.length!=32 || client.length!=crypto_kx_PUBLICKEYBYTES))) return NO;
    _gatewayID=[state[@"gatewayID"]copy]; _oneTimeCode=[state[@"oneTimeCode"]copy];
    _relaySecret=[state[@"relaySecret"]copy]; _publicKey=publicKey; _consumed=consumed;
    if (secret.length==sizeof(_secret)) memcpy(_secret,secret.bytes,sizeof(_secret));
    _pairedSharedKey=shared; _pairedClientPublicKey=client;
    return YES;
}

- (void)saveState {
    NSMutableDictionary *state=[@{@"gatewayID":_gatewayID,@"oneTimeCode":_oneTimeCode,
        @"relaySecret":_relaySecret,@"publicKey":[_publicKey base64EncodedStringWithOptions:0],
        @"consumed":@(_consumed)} mutableCopy];
    if (_consumed) {
        state[@"sharedKey"]=[_pairedSharedKey base64EncodedStringWithOptions:0];
        state[@"clientPublicKey"]=[_pairedClientPublicKey base64EncodedStringWithOptions:0];
    } else {
        state[@"secretKey"]=[[NSData dataWithBytes:_secret length:sizeof(_secret)]base64EncodedStringWithOptions:0];
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingSortedKeys error:nil];
    if (![data writeToFile:K7PairingStatePath options:NSDataWritingAtomic error:nil]) NSLog(@"K7Bridge failed to persist pairing state");
    [[NSFileManager defaultManager]setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:K7PairingStatePath error:nil];
}
- (NSDictionary *)pairingDocumentWithHost:(NSString *)host port:(uint16_t)port certificateHash:(NSString *)hash relayURL:(NSURL *)relayURL {
    return @{ @"gatewayId":_gatewayID,@"host":host,@"port":@(port),@"oneTimeCode":_oneTimeCode,
        @"gatewayPublicKey":[_publicKey base64EncodedStringWithOptions:0],@"certificateSHA256":hash,
        @"relayURL":relayURL.absoluteString,@"relaySecret":_relaySecret };
}
- (BOOL)consumeCode:(NSString *)code clientPublicKey:(NSData *)key sharedKey:(NSData **)sharedKey {
    @synchronized(self) {
        if (_consumed) {
            if ([code isEqual:_oneTimeCode] && [key isEqualToData:_pairedClientPublicKey] && _pairedSharedKey.length==32) {
                *sharedKey=_pairedSharedKey; return YES;
            }
            return NO;
        }
        if (![code isEqual:_oneTimeCode] || key.length != crypto_kx_PUBLICKEYBYTES) return NO;
        unsigned char raw[crypto_scalarmult_BYTES];
        if (crypto_scalarmult_curve25519(raw,_secret,(const unsigned char *)key.bytes) != 0) return NO;
        NSData *salt=[code dataUsingEncoding:NSUTF8StringEncoding]; const char *info="k7bridge-pair-v1";
        unsigned char prk[crypto_auth_hmacsha256_BYTES], output[32], block[crypto_auth_hmacsha256_BYTES];
        crypto_auth_hmacsha256_state extract; crypto_auth_hmacsha256_init(&extract,(const unsigned char *)salt.bytes,salt.length);
        crypto_auth_hmacsha256_update(&extract,raw,sizeof(raw)); crypto_auth_hmacsha256_final(&extract,prk);
        crypto_auth_hmacsha256_state expand; crypto_auth_hmacsha256_init(&expand,prk,sizeof(prk));
        crypto_auth_hmacsha256_update(&expand,(const unsigned char *)info,strlen(info)); unsigned char counter=1;
        crypto_auth_hmacsha256_update(&expand,&counter,1); crypto_auth_hmacsha256_final(&expand,block); memcpy(output,block,sizeof(output));
        *sharedKey=[NSData dataWithBytes:output length:sizeof(output)]; _pairedSharedKey=*sharedKey;
        _pairedClientPublicKey=[key copy]; _consumed=YES; [self saveState];
        sodium_memzero(raw,sizeof(raw));sodium_memzero(prk,sizeof(prk));sodium_memzero(block,sizeof(block));sodium_memzero(_secret,sizeof(_secret));return YES; }
}
@end
