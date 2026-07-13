#import <Foundation/Foundation.h>
@interface K7SMSStore : NSObject
- (NSArray<NSDictionary *> *)messagesBeforeRowID:(int64_t)cursor limit:(NSUInteger)limit error:(NSError **)error;
- (BOOL)sendText:(NSString *)text toAddress:(NSString *)address error:(NSError **)error;
@end

