#import "Diagnostics.h"
#import <unistd.h>

static NSString *const K7DiagnosticsDirectory=@"/var/mobile/Library/Logs/K7Bridge";
static const unsigned long long K7DiagnosticsMaximumBytes=2*1024*1024;

@implementation K7Diagnostics {
    unsigned long long _sequence;
    NSISO8601DateFormatter *_formatter;
}

+ (instancetype)shared {
    static K7Diagnostics *value;
    static dispatch_once_t once;
    dispatch_once(&once,^{ value=[K7Diagnostics new]; });
    return value;
}

- (instancetype)init {
    if ((self=[super init])) {
        _path=[K7DiagnosticsDirectory stringByAppendingPathComponent:@"events.jsonl"];
        _formatter=[NSISO8601DateFormatter new];
        _formatter.formatOptions=NSISO8601DateFormatWithInternetDateTime|NSISO8601DateFormatWithFractionalSeconds;
        [[NSFileManager defaultManager] createDirectoryAtPath:K7DiagnosticsDirectory
            withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil];
    }
    return self;
}

- (NSDictionary<NSString *,NSString *> *)stringFields:(NSDictionary<NSString *,id> *)fields {
    NSMutableDictionary *result=[NSMutableDictionary dictionary];
    [fields enumerateKeysAndObjectsUsingBlock:^(id rawKey,id value,BOOL *stop) {
        if (![rawKey isKindOfClass:NSString.class] || !value || value==NSNull.null) return;
        NSString *key=rawKey;
        NSString *text=[value isKindOfClass:NSString.class]?value:[value description];
        if (text.length>256) text=[[text substringToIndex:256] stringByAppendingString:@"…"];
        result[key]=text;
    }];
    return result;
}

- (void)rotateIfNeeded {
    NSNumber *size=[[[NSFileManager defaultManager] attributesOfItemAtPath:self.path error:nil]
        objectForKey:NSFileSize];
    if (size.unsignedLongLongValue<K7DiagnosticsMaximumBytes) return;
    NSString *previous=[self.path stringByAppendingString:@".1"];
    [[NSFileManager defaultManager] removeItemAtPath:previous error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:self.path toPath:previous error:nil];
}

- (void)recordComponent:(NSString *)component level:(NSString *)level event:(NSString *)event
                  fields:(NSDictionary<NSString *,id> *)fields {
    if (!component.length || !event.length) return;
    @synchronized(self) {
        [self rotateIfNeeded];
        NSDictionary *entry=@{
            @"timestamp":[_formatter stringFromDate:[NSDate date]],
            @"sequence":@(++_sequence),
            @"source":@"gateway",
            @"level":level.length?level:@"info",
            @"component":component,
            @"event":event,
            @"fields":[self stringFields:fields?:@{}],
            @"pid":@(getpid())
        };
        NSData *json=[NSJSONSerialization dataWithJSONObject:entry options:NSJSONWritingSortedKeys error:nil];
        if (!json) return;
        NSMutableData *line=[json mutableCopy];
        [line appendBytes:"\n" length:1];
        if (![[NSFileManager defaultManager] fileExistsAtPath:self.path])
            [[NSFileManager defaultManager] createFileAtPath:self.path contents:nil attributes:@{NSFilePosixPermissions:@0644}];
        NSFileHandle *handle=[NSFileHandle fileHandleForWritingAtPath:self.path];
        [handle seekToEndOfFile];
        [handle writeData:line];
        [handle closeFile];
    }
}

- (NSArray<NSDictionary *> *)recentEntries:(NSUInteger)limit {
    limit=MAX(1,MIN(limit,500));
    @synchronized(self) {
        NSMutableArray<NSDictionary *> *entries=[NSMutableArray array];
        for (NSString *path in @[[self.path stringByAppendingString:@".1"],self.path]) {
            NSData *data=[NSData dataWithContentsOfFile:path];
            if (!data.length) continue;
            NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
                if (!line.length) continue;
                id value=[NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding]
                    options:0 error:nil];
                if ([value isKindOfClass:NSDictionary.class]) [entries addObject:value];
            }
        }
        if (entries.count<=limit) return entries;
        return [entries subarrayWithRange:NSMakeRange(entries.count-limit,limit)];
    }
}
@end
