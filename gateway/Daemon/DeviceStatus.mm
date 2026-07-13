#import "DeviceStatus.h"
#import <CoreTelephony/CoreTelephony.h>
#import <UIKit/UIKit.h>

@implementation K7DeviceStatus
- (instancetype)init { if((self=[super init]))[UIDevice currentDevice].batteryMonitoringEnabled=YES;return self; }
- (NSDictionary *)snapshot {
    CTTelephonyNetworkInfo *network=[CTTelephonyNetworkInfo new];CTCarrier *carrier=network.serviceSubscriberCellularProviders.allValues.firstObject;
    NSString *radio=network.serviceCurrentRadioAccessTechnology.allValues.firstObject?:@"—";UIDevice *device=[UIDevice currentDevice];
    NSDictionary *gate=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@"/var/mobile/Library/K7Bridge/audio-gate.json"]?:[NSData data] options:0 error:nil];
    NSString *thermal=@[@"nominal",@"fair",@"serious",@"critical"][(NSUInteger)MIN(NSProcessInfo.processInfo.thermalState,3)];
    return@{@"carrier":carrier.carrierName?:@"—",@"radioTechnology":radio,@"signalBars":@0,
        @"simReady":@(carrier.mobileNetworkCode.length>0),@"batteryLevel":@(MAX(device.batteryLevel,0)),
        @"charging":@(device.batteryState==UIDeviceBatteryStateCharging||device.batteryState==UIDeviceBatteryStateFull),
        @"thermalState":thermal,@"hotspotEnabled":@NO,@"clientConnected":@YES,@"audioGatePassed":@([gate[@"passed"]boolValue])};
}
@end
