#import "SMSStore.h"
#import <sqlite3.h>
#import <objc/message.h>

static NSString *const K7SMSPath = @"/var/mobile/Library/SMS/sms.db";

@implementation K7SMSStore
- (NSArray<NSDictionary *> *)messagesBeforeRowID:(int64_t)cursor limit:(NSUInteger)limit error:(NSError **)error {
    sqlite3 *db = NULL; NSMutableArray *items = [NSMutableArray array];
    int flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX;
    if (sqlite3_open_v2(K7SMSPath.fileSystemRepresentation, &db, flags, NULL) != SQLITE_OK) { [self databaseError:db out:error]; if (db) sqlite3_close(db); return items; }
    sqlite3_busy_timeout(db, 1500);
    const char *sql = "SELECT m.ROWID, COALESCE(h.id,''), COALESCE(m.text,''), m.date, m.is_from_me "
        "FROM message m LEFT JOIN handle h ON h.ROWID=m.handle_id "
        "WHERE m.service='SMS' AND (?1=0 OR m.ROWID < ?1) ORDER BY m.ROWID DESC LIMIT ?2";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, cursor); sqlite3_bind_int(statement, 2, (int)MIN(MAX(limit, 1), 100));
        while (sqlite3_step(statement) == SQLITE_ROW) {
            int64_t row = sqlite3_column_int64(statement, 0); const char *handle = (const char *)sqlite3_column_text(statement, 1);
            const char *text = (const char *)sqlite3_column_text(statement, 2); int64_t appleTime = sqlite3_column_int64(statement, 3);
            NSTimeInterval seconds = appleTime > 1000000000000LL ? appleTime / 1000000000.0 : appleTime;
            NSDate *date = [NSDate dateWithTimeIntervalSinceReferenceDate:seconds];
            NSISO8601DateFormatter *formatter=[NSISO8601DateFormatter new];formatter.formatOptions=NSISO8601DateFormatWithInternetDateTime|NSISO8601DateFormatWithFractionalSeconds;
            [items addObject:@{ @"id": [NSString stringWithFormat:@"sms-%lld", row], @"handle": handle ? @(handle) : @"",
                @"text": text ? @(text) : @"", @"date": [formatter stringFromDate:date],
                @"isFromMe": @(sqlite3_column_int(statement, 4) != 0), @"state": @"sent", @"cursor": @(row) }];
        }
    } else [self databaseError:db out:error];
    if (statement) sqlite3_finalize(statement); sqlite3_close(db); return items;
}
- (BOOL)sendText:(NSString *)text toAddress:(NSString *)address error:(NSError **)error {
    Class cls = NSClassFromString(@"CTMessageCenter"); SEL shared = NSSelectorFromString(@"sharedMessageCenter");
    if (!cls || ![cls respondsToSelector:shared]) return [self unavailable:error];
    id center = ((id(*)(id,SEL))objc_msgSend)(cls, shared);
    BOOL result=NO;
    unsigned int trackingID=0;
    SEL tracked=NSSelectorFromString(@"sendSMSWithText:serviceCenter:toAddress:trackingID:");
    SEL basic=NSSelectorFromString(@"sendSMSWithText:serviceCenter:toAddress:");
    if ([center respondsToSelector:tracked]) {
        result=((BOOL(*)(id,SEL,id,id,id,unsigned int *))objc_msgSend)(center,tracked,
            text,nil,address,&trackingID);
    } else if ([center respondsToSelector:basic]) {
        result=((BOOL(*)(id,SEL,id,id,id))objc_msgSend)(center,basic,text,nil,address);
    } else return [self unavailable:error];
    if (!result && error) *error = [NSError errorWithDomain:@"K7SMS" code:2 userInfo:@{
        NSLocalizedDescriptionKey:@"CoreTelephony SMS isteğini reddetti"}];
    NSLog(@"K7Bridge SMS submission %@ tracking id %u",result?@"accepted":@"rejected",trackingID);
    return result;
}
- (BOOL)unavailable:(NSError **)error { if (error) *error = [NSError errorWithDomain:@"K7SMS" code:1 userInfo:@{NSLocalizedDescriptionKey:@"CTMessageCenter unavailable on this build"}]; return NO; }
- (void)databaseError:(sqlite3 *)db out:(NSError **)error { if (error) *error = [NSError errorWithDomain:@"K7SMS" code:3 userInfo:@{NSLocalizedDescriptionKey:db ? @(sqlite3_errmsg(db)) : @"Cannot open SMS database"}]; }
@end
