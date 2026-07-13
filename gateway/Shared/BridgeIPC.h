#import <Foundation/Foundation.h>
typedef NSDictionary * _Nullable (^K7MessageHandler)(NSDictionary *message);
@interface K7BridgeIPC : NSObject
- (instancetype)initLocalPort:(NSString *)name handler:(K7MessageHandler)handler;
+ (NSDictionary * _Nullable)send:(NSDictionary *)message toPort:(NSString *)name timeout:(NSTimeInterval)timeout;
@end

