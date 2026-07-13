#import "Pairing.h"
#import <sodium.h>

@implementation K7Pairing { unsigned char _secret[crypto_kx_SECRETKEYBYTES]; BOOL _consumed; }
- (instancetype)init { if ((self=[super init])) { if (sodium_init() < 0) return nil; unsigned char pub[crypto_kx_PUBLICKEYBYTES]; crypto_kx_keypair(pub, _secret); _publicKey=[NSData dataWithBytes:pub length:sizeof(pub)]; _gatewayID=[NSUUID UUID].UUIDString; _oneTimeCode=[NSString stringWithFormat:@"%06u", arc4random_uniform(1000000)]; unsigned char token[32]; randombytes_buf(token,sizeof(token)); _relaySecret=[[NSData dataWithBytes:token length:sizeof(token)] base64EncodedStringWithOptions:0]; } return self; }
- (NSDictionary *)pairingDocumentWithHost:(NSString *)host port:(uint16_t)port certificateHash:(NSString *)hash relayURL:(NSURL *)relayURL {
    return @{ @"gatewayId":_gatewayID,@"host":host,@"port":@(port),@"oneTimeCode":_oneTimeCode,
        @"gatewayPublicKey":[_publicKey base64EncodedStringWithOptions:0],@"certificateSHA256":hash,
        @"relayURL":relayURL.absoluteString,@"relaySecret":_relaySecret };
}
- (BOOL)consumeCode:(NSString *)code clientPublicKey:(NSData *)key sharedKey:(NSData **)sharedKey {
    @synchronized(self) { if (_consumed || ![code isEqual:_oneTimeCode] || key.length != crypto_kx_PUBLICKEYBYTES) return NO;
        unsigned char raw[crypto_scalarmult_BYTES];
        if (crypto_scalarmult_curve25519(raw,_secret,(const unsigned char *)key.bytes) != 0) return NO;
        NSData *salt=[code dataUsingEncoding:NSUTF8StringEncoding]; const char *info="k7bridge-pair-v1";
        unsigned char prk[crypto_auth_hmacsha256_BYTES], output[32], block[crypto_auth_hmacsha256_BYTES];
        crypto_auth_hmacsha256_state extract; crypto_auth_hmacsha256_init(&extract,(const unsigned char *)salt.bytes,salt.length);
        crypto_auth_hmacsha256_update(&extract,raw,sizeof(raw)); crypto_auth_hmacsha256_final(&extract,prk);
        crypto_auth_hmacsha256_state expand; crypto_auth_hmacsha256_init(&expand,prk,sizeof(prk));
        crypto_auth_hmacsha256_update(&expand,(const unsigned char *)info,strlen(info)); unsigned char counter=1;
        crypto_auth_hmacsha256_update(&expand,&counter,1); crypto_auth_hmacsha256_final(&expand,block); memcpy(output,block,sizeof(output));
        *sharedKey=[NSData dataWithBytes:output length:sizeof(output)]; _consumed=YES;
        sodium_memzero(raw,sizeof(raw));sodium_memzero(prk,sizeof(prk));sodium_memzero(block,sizeof(block));sodium_memzero(_secret,sizeof(_secret));return YES; }
}
@end
