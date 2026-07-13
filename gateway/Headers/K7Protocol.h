#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, K7CallState) {
    K7CallStateIdle, K7CallStateIncoming, K7CallStateDialing,
    K7CallStateConnecting, K7CallStateActive, K7CallStateEnded, K7CallStateFailed
};

static inline NSString *K7StateString(K7CallState state) {
    switch (state) {
        case K7CallStateIncoming: return @"incoming"; case K7CallStateDialing: return @"dialing";
        case K7CallStateConnecting: return @"connecting"; case K7CallStateActive: return @"active";
        case K7CallStateEnded: return @"ended"; case K7CallStateFailed: return @"failed";
        default: return @"idle";
    }
}
