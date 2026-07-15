#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Local, encrypted, single-call media bridge. Downlink is captured with the
/// iOS telephony audio tap; uplink is rendered through AVAudioPlayer's private
/// telephony-uplink route. No code is injected into mediaserverd.
@interface K7MediaServer : NSObject
@property(nonatomic, readonly, getter=isReady) BOOL ready;
@property(nonatomic, readonly, nullable) NSString *lastError;
- (BOOL)start:(NSError **)error;
- (void)stop;
- (void)setActiveCall:(nullable NSUUID *)callID sharedKey:(nullable NSData *)sharedKey;
@end

NS_ASSUME_NONNULL_END
