#import "StateMachine.h"

@implementation K7StateMachine { K7CallState _state; NSUUID *_callID; NSString *_handle; }
- (K7CallState)state { @synchronized(self) { return _state; } }
- (NSUUID *)callID { @synchronized(self) { return _callID; } }
- (NSString *)handle { @synchronized(self) { return _handle; } }
- (BOOL)beginIncoming:(NSUUID *)callID handle:(NSString *)handle error:(NSError **)error { return [self begin:K7CallStateIncoming callID:callID handle:handle error:error]; }
- (BOOL)beginDialing:(NSUUID *)callID handle:(NSString *)handle error:(NSError **)error { return [self begin:K7CallStateDialing callID:callID handle:handle error:error]; }
- (BOOL)begin:(K7CallState)state callID:(NSUUID *)callID handle:(NSString *)handle error:(NSError **)error {
    @synchronized(self) {
        if (_state != K7CallStateIdle && _state != K7CallStateEnded && _state != K7CallStateFailed) return [self fail:@"busy" error:error];
        _callID = callID; _handle = [handle copy]; _state = state; return YES;
    }
}
- (BOOL)transition:(K7CallState)next error:(NSError **)error {
    @synchronized(self) {
        BOOL valid = (_state == K7CallStateIncoming && (next == K7CallStateConnecting || next == K7CallStateEnded || next == K7CallStateFailed)) ||
            (_state == K7CallStateDialing && (next == K7CallStateConnecting || next == K7CallStateEnded || next == K7CallStateFailed)) ||
            (_state == K7CallStateConnecting && (next == K7CallStateActive || next == K7CallStateEnded || next == K7CallStateFailed)) ||
            (_state == K7CallStateActive && (next == K7CallStateEnded || next == K7CallStateFailed)) ||
            ((next == K7CallStateIdle) && (_state == K7CallStateEnded || _state == K7CallStateFailed));
        if (!valid) return [self fail:@"invalid_transition" error:error];
        _state = next; if (next == K7CallStateIdle) { _callID = nil; _handle = nil; } return YES;
    }
}
- (BOOL)fail:(NSString *)code error:(NSError **)error { if (error) *error = [NSError errorWithDomain:@"K7Call" code:1 userInfo:@{NSLocalizedDescriptionKey:code}]; return NO; }
- (NSDictionary *)snapshot { @synchronized(self) { return @{ @"id": _callID.UUIDString ?: [NSNull null], @"handle": _handle ?: [NSNull null], @"state": K7StateString(_state) }; } }
@end

