#import <Foundation/Foundation.h>
#import "K7Protocol.h"

@interface K7StateMachine : NSObject
@property(nonatomic, readonly) K7CallState state;
@property(nonatomic, readonly, nullable) NSUUID *callID;
@property(nonatomic, readonly, nullable) NSString *handle;
- (BOOL)beginIncoming:(NSUUID *)callID handle:(NSString *)handle error:(NSError **)error;
- (BOOL)beginDialing:(NSUUID *)callID handle:(NSString *)handle error:(NSError **)error;
- (BOOL)transition:(K7CallState)state error:(NSError **)error;
- (NSDictionary *)snapshot;
@end

