#import <Foundation/Foundation.h>
@interface K7Pairing : NSObject
@property(nonatomic, readonly) NSString *gatewayID;
@property(nonatomic, readonly) NSString *oneTimeCode;
@property(nonatomic, readonly) NSData *publicKey;
@property(nonatomic, readonly) NSString *relaySecret;
- (NSDictionary *)pairingDocumentWithHost:(NSString *)host port:(uint16_t)port certificateHash:(NSString *)hash relayURL:(NSURL *)relayURL;
- (BOOL)consumeCode:(NSString *)code clientPublicKey:(NSData *)key sharedKey:(NSData **)sharedKey;
@end

