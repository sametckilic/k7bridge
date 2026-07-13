#import <Foundation/Foundation.h>
@interface K7RelayClient : NSObject
- (instancetype)initWithBaseURL:(NSURL *)baseURL gatewayID:(NSString *)gatewayID relaySecret:(NSString *)relaySecret;
- (void)sendIncomingCall:(NSDictionary *)call sharedKey:(NSData *)sharedKey completion:(void(^)(NSError *error))completion;
@end

