#import "BridgeIPC.h"
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

@interface K7BridgeIPC () @property(nonatomic,copy) K7MessageHandler handler; @end

static uint16_t K7PortNumber(NSString *name) {
    if ([name isEqualToString:@"com.k7bridge.gateway"]) return 17444;
    if ([name isEqualToString:@"com.k7bridge.telephony"]) return 17445;
    return 0;
}

static BOOL K7WriteAll(int fd,const void *bytes,size_t length) {
    const uint8_t *cursor=(const uint8_t *)bytes;
    while (length>0) {
        ssize_t count=send(fd,cursor,length,0);
        if (count<0 && errno==EINTR) continue;
        if (count<=0) return NO;
        cursor+=count; length-=(size_t)count;
    }
    return YES;
}

static BOOL K7ReadAll(int fd,void *bytes,size_t length) {
    uint8_t *cursor=(uint8_t *)bytes;
    while (length>0) {
        ssize_t count=recv(fd,cursor,length,0);
        if (count<0 && errno==EINTR) continue;
        if (count<=0) return NO;
        cursor+=count; length-=(size_t)count;
    }
    return YES;
}

static NSDictionary *K7ReadMessage(int fd) {
    uint32_t encodedLength=0;
    if (!K7ReadAll(fd,&encodedLength,sizeof(encodedLength))) return nil;
    uint32_t length=ntohl(encodedLength);
    if (length==0 || length>1024*1024) return nil;
    NSMutableData *data=[NSMutableData dataWithLength:length];
    if (!K7ReadAll(fd,data.mutableBytes,length)) return nil;
    id object=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class]?object:nil;
}

static BOOL K7WriteMessage(int fd,NSDictionary *message) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:message?:@{} options:0 error:nil];
    if (!data || data.length>1024*1024) return NO;
    uint32_t encodedLength=htonl((uint32_t)data.length);
    return K7WriteAll(fd,&encodedLength,sizeof(encodedLength))&&
        K7WriteAll(fd,data.bytes,data.length);
}

@implementation K7BridgeIPC {
    int _listenFD;
    dispatch_source_t _acceptSource;
}

- (instancetype)initLocalPort:(NSString *)name handler:(K7MessageHandler)handler {
    if (!(self=[super init])) return nil;
    _listenFD=-1;
    _handler=[handler copy];
    uint16_t port=K7PortNumber(name);
    if (!port || !_handler) return nil;

    int fd=socket(AF_INET,SOCK_STREAM,0);
    if (fd<0) return nil;
    int enabled=1;
    setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&enabled,sizeof(enabled));
    setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&enabled,sizeof(enabled));
    sockaddr_in address={};
    address.sin_family=AF_INET;
    address.sin_port=htons(port);
    address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    if (bind(fd,(sockaddr *)&address,sizeof(address))<0 || listen(fd,16)<0) {
        close(fd);
        return nil;
    }
    fcntl(fd,F_SETFL,fcntl(fd,F_GETFL,0)|O_NONBLOCK);
    _listenFD=fd;

    dispatch_queue_t queue=dispatch_queue_create("com.k7bridge.ipc.accept",DISPATCH_QUEUE_SERIAL);
    _acceptSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,(uintptr_t)fd,0,queue);
    __weak K7BridgeIPC *weakSelf=self;
    dispatch_source_set_event_handler(_acceptSource,^{
        K7BridgeIPC *bridge=weakSelf;
        if (!bridge) return;
        for (;;) {
            int client=accept(bridge->_listenFD,NULL,NULL);
            if (client<0) {
                if (errno==EINTR) continue;
                break;
            }
            setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&enabled,sizeof(enabled));
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
                NSDictionary *message=K7ReadMessage(client);
                __block NSDictionary *reply=@{@"ok":@NO,@"error":@"invalid IPC message"};
                if (message) {
                    void (^invoke)(void)=^{ reply=bridge.handler(message)?:@{}; };
                    if ([NSThread isMainThread]) invoke();
                    else dispatch_sync(dispatch_get_main_queue(),invoke);
                }
                K7WriteMessage(client,reply);
                close(client);
            });
        }
    });
    dispatch_resume(_acceptSource);
    return self;
}

- (void)dealloc {
    if (_acceptSource) dispatch_source_cancel(_acceptSource);
    if (_listenFD>=0) close(_listenFD);
}

+ (NSDictionary *)send:(NSDictionary *)message toPort:(NSString *)name timeout:(NSTimeInterval)timeout {
    uint16_t port=K7PortNumber(name);
    if (!port) return nil;
    int fd=socket(AF_INET,SOCK_STREAM,0);
    if (fd<0) return nil;
    int enabled=1;
    setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&enabled,sizeof(enabled));
    NSTimeInterval bounded=MAX(0.05,timeout);
    time_t seconds=(time_t)bounded;
    timeval value={seconds,(suseconds_t)((bounded-seconds)*1000000)};
    setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&value,sizeof(value));
    setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&value,sizeof(value));
    sockaddr_in address={};
    address.sin_family=AF_INET;
    address.sin_port=htons(port);
    address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    NSDictionary *reply=nil;
    if (connect(fd,(sockaddr *)&address,sizeof(address))==0 && K7WriteMessage(fd,message))
        reply=K7ReadMessage(fd);
    close(fd);
    return reply;
}
@end
