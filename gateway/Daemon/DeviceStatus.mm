#import "DeviceStatus.h"
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <ifaddrs.h>
#import <netinet/in.h>
#import <arpa/inet.h>

static id K7ValueOrNull(id value) { return value?:[NSNull null]; }

static NSNumber *K7SignalBars(CTTelephonyNetworkInfo *network) {
    SEL servicesSelector=NSSelectorFromString(@"serviceSignalStrength");
    id services=[network respondsToSelector:servicesSelector]?
        ((id(*)(id,SEL))objc_msgSend)(network,servicesSelector):nil;
    id info=[services isKindOfClass:NSDictionary.class]?[services allValues].firstObject:nil;
    if (!info) {
        SEL legacySelector=NSSelectorFromString(@"signalStrength");
        info=[network respondsToSelector:legacySelector]?
            ((id(*)(id,SEL))objc_msgSend)(network,legacySelector):nil;
    }
    for (NSString *name in @[@"displayBars",@"bars"]) {
        SEL selector=NSSelectorFromString(name);
        id value=info&&[info respondsToSelector:selector]?((id(*)(id,SEL))objc_msgSend)(info,selector):nil;
        if ([value isKindOfClass:NSNumber.class])
            return @(MAX(0,MIN(4,[value integerValue])));
    }
    return nil;
}

static NSNumber *K7HotspotEnabled(void) {
    struct ifaddrs *interfaces=NULL;
    if (getifaddrs(&interfaces)!=0) return nil;
    BOOL enabled=NO;
    for (struct ifaddrs *item=interfaces;item;item=item->ifa_next) {
        if (!item->ifa_addr || item->ifa_addr->sa_family!=AF_INET) continue;
        struct sockaddr_in *address=(struct sockaddr_in *)item->ifa_addr;
        char buffer[INET_ADDRSTRLEN]={0};
        if (!inet_ntop(AF_INET,&address->sin_addr,buffer,sizeof(buffer))) continue;
        if (strcmp(buffer,"172.20.10.1")==0 ||
            (item->ifa_name && strcmp(item->ifa_name,"bridge100")==0)) {
            enabled=YES;
            break;
        }
    }
    freeifaddrs(interfaces);
    return @(enabled);
}

static NSString *K7RadioName(NSString *technology) {
    if (!technology.length) return nil;
    if ([technology containsString:@"NR"]) return @"5G";
    if ([technology containsString:@"LTE"]) return @"LTE";
    if ([technology containsString:@"WCDMA"] || [technology containsString:@"HSDPA"] ||
        [technology containsString:@"HSUPA"] || [technology containsString:@"CDMA"]) return @"3G";
    if ([technology containsString:@"GPRS"] || [technology containsString:@"Edge"]) return @"2G";
    return technology.lastPathComponent;
}

@implementation K7DeviceStatus {
    CTTelephonyNetworkInfo *_network;
}
- (instancetype)init {
    if((self=[super init])) {
        [UIDevice currentDevice].batteryMonitoringEnabled=YES;
        _network=[CTTelephonyNetworkInfo new];
        SEL query=NSSelectorFromString(@"queryCTSignalStrength");
        if ([_network respondsToSelector:query])
            ((void(*)(id,SEL))objc_msgSend)(_network,query);
    }
    return self;
}

- (NSDictionary *)snapshot {
    CTTelephonyNetworkInfo *network=_network?:[CTTelephonyNetworkInfo new];
    CTCarrier *carrier=network.serviceSubscriberCellularProviders.allValues.firstObject;
    NSString *radio=K7RadioName(network.serviceCurrentRadioAccessTechnology.allValues.firstObject);
    UIDevice *device=[UIDevice currentDevice];
    NSNumber *battery=device.batteryLevel<0?nil:@(device.batteryLevel);
    NSNumber *charging=device.batteryState==UIDeviceBatteryStateUnknown?nil:
        @(device.batteryState==UIDeviceBatteryStateCharging||device.batteryState==UIDeviceBatteryStateFull);
    NSData *gateData=[NSData dataWithContentsOfFile:@"/var/mobile/Library/K7Bridge/audio-gate.json"];
    NSDictionary *gate=gateData?[NSJSONSerialization JSONObjectWithData:gateData options:0 error:nil]:nil;
    NSString *thermal=@[@"nominal",@"fair",@"serious",@"critical"][(NSUInteger)MIN(NSProcessInfo.processInfo.thermalState,3)];
    NSNumber *simReady=carrier?@(carrier.mobileNetworkCode.length>0):nil;
    return @{
        @"carrier":K7ValueOrNull(carrier.carrierName),
        @"radioTechnology":K7ValueOrNull(radio),
        @"signalBars":K7ValueOrNull(K7SignalBars(network)),
        @"simReady":K7ValueOrNull(simReady),
        @"batteryLevel":K7ValueOrNull(battery),
        @"charging":K7ValueOrNull(charging),
        @"thermalState":thermal,
        @"hotspotEnabled":K7ValueOrNull(K7HotspotEnabled()),
        @"clientConnected":[NSNull null],
        @"audioGatePassed":@([gate[@"passed"]boolValue])
    };
}
@end
