#import <Foundation/Foundation.h>

// This source is deliberately excluded from the shipping package. The previous
// discovery build guessed an AudioUnitRender buffer and destabilized mediaserverd
// without proving that the buffer was the cellular uplink. Audio remains fail-closed
// until both directions are verified on the exact iOS build.
%ctor { @autoreleasepool {
    NSLog(@"K7AudioBridge is fail-closed; no audio process hooks were installed");
} }
