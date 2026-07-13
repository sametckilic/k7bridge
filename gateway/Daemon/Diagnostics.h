#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface K7Diagnostics : NSObject
@property(nonatomic,readonly) NSString *path;
+ (instancetype)shared;
- (void)recordComponent:(NSString *)component
                  level:(NSString *)level
                  event:(NSString *)event
                 fields:(nullable NSDictionary<NSString *,id> *)fields;
- (NSArray<NSDictionary *> *)recentEntries:(NSUInteger)limit;
@end

NS_ASSUME_NONNULL_END
