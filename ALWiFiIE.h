#import <Foundation/Foundation.h>

// Parses a scan result's raw 802.11 information elements (the "IE" property)
// into readable fields: Wi-Fi generation, channel width, spatial streams, BSS
// Load (clients / channel utilization), country, WPS identity (router make and
// model), and vendor elements (chipset / platform hints).
@interface ALWiFiIE : NSObject
+ (void)parseIE:(NSData *)ie into:(NSMutableDictionary *)info;
@end
