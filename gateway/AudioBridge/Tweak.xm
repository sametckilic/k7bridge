#import <Foundation/Foundation.h>

%ctor { @autoreleasepool {
    NSString *gate=@"/var/mobile/Library/K7Bridge/audio-gate.json";NSData *data=[NSData dataWithContentsOfFile:gate];
    NSDictionary *value=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    if(![value[@"passed"]boolValue]){NSLog(@"K7AudioBridge fail-closed: verified audio gate is absent");return;}
    // The verified hook implementation is generated from the device probe report.
    // No guessed AudioUnit/mediaserverd symbol is permitted in this source tree.
    NSLog(@"K7AudioBridge gate present, but no verified hook implementation has been installed");
} }

