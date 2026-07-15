#import "Diagnostics.h"
#import <unistd.h>

static NSString *const K7DiagnosticsDirectory=@"/var/mobile/Library/Logs/K7Bridge";
static const unsigned long long K7DiagnosticsMaximumBytes=2*1024*1024;
static const unsigned long long K7DiagnosticsMaximumReadBytes=512*1024;

static NSArray<NSDictionary *> *K7ReadRecentEntries(NSString *path,NSUInteger limit) {
    if (!path.length || !limit) return @[];

    NSNumber *sizeValue=[[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil]
        objectForKey:NSFileSize];
    unsigned long long size=sizeValue.unsignedLongLongValue;
    if (!size) return @[];

    unsigned long long offset=size>K7DiagnosticsMaximumReadBytes
        ? size-K7DiagnosticsMaximumReadBytes : 0;
    NSFileHandle *handle=[NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return @[];
    @try {
        [handle seekToFileOffset:offset];
    } @catch (__unused NSException *exception) {
        [handle closeFile];
        return @[];
    }
    NSData *data=[handle readDataToEndOfFile];
    [handle closeFile];
    if (!data.length) return @[];

    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text.length) return @[];
    NSArray<NSString *> *lines=[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSInteger firstCompleteLine=offset>0 ? 1 : 0;
    NSMutableArray<NSDictionary *> *newestFirst=[NSMutableArray arrayWithCapacity:limit];
    for (NSInteger index=(NSInteger)lines.count-1;
         index>=firstCompleteLine && newestFirst.count<limit;
         index--) {
        NSString *line=lines[(NSUInteger)index];
        if (!line.length) continue;
        id value=[NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding]
            options:0 error:nil];
        if ([value isKindOfClass:NSDictionary.class]) [newestFirst addObject:value];
    }
    return newestFirst.reverseObjectEnumerator.allObjects;
}

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
        NSArray<NSDictionary *> *current=K7ReadRecentEntries(self.path,limit);
        if (current.count>=limit) return current;

        NSUInteger remaining=limit-current.count;
        NSArray<NSDictionary *> *previous=K7ReadRecentEntries(
            [self.path stringByAppendingString:@".1"],remaining);
        if (!previous.count) return current;
        NSMutableArray<NSDictionary *> *combined=[NSMutableArray arrayWithCapacity:previous.count+current.count];
        [combined addObjectsFromArray:previous];
        [combined addObjectsFromArray:current];
        return combined;
    }
}
@end
