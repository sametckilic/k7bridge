#import <Foundation/Foundation.h>
typedef NSDictionary * _Nonnull (^K7ControlHandler)(NSDictionary *message);
@interface K7ControlServer : NSObject
- (instancetype)initWithPort:(uint16_t)port PKCS12:(NSData *)pkcs12 password:(NSString *)password handler:(K7ControlHandler)handler;
- (BOOL)start:(NSError **)error;
- (BOOL)hasAuthenticatedClient;
- (void)stop;
- (void)broadcastType:(NSString *)type payload:(NSDictionary *)payload;
@end
