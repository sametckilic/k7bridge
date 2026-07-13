#import "DeviceStatus.h"
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <UIKit/UIKit.h>

static id K7ValueOrNull(id value) { return value?:[NSNull null]; }

static NSString *K7RadioName(NSString *technology) {
    if (!technology.length) return nil;
    if ([technology containsString:@"NR"]) return @"5G";
    if ([technology containsString:@"LTE"]) return @"LTE";
    if ([technology containsString:@"WCDMA"] || [technology containsString:@"HSDPA"] ||
        [technology containsString:@"HSUPA"] || [technology containsString:@"CDMA"]) return @"3G";
    if ([technology containsString:@"GPRS"] || [technology containsString:@"Edge"]) return @"2G";
    return technology.lastPathComponent;
}

@implementation K7DeviceStatus
- (instancetype)init {
    if((self=[super init])) [UIDevice currentDevice].batteryMonitoringEnabled=YES;
    return self;
}

- (NSDictionary *)snapshot {
    CTTelephonyNetworkInfo *network=[CTTelephonyNetworkInfo new];
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
        @"signalBars":[NSNull null],
        @"simReady":K7ValueOrNull(simReady),
        @"batteryLevel":K7ValueOrNull(battery),
        @"charging":K7ValueOrNull(charging),
        @"thermalState":thermal,
        @"hotspotEnabled":[NSNull null],
        @"clientConnected":[NSNull null],
        @"audioGatePassed":@([gate[@"passed"]boolValue])
    };
}
@end
