#import <Foundation/Foundation.h>
#import "ALDevice.h"

@interface ALWiFiScanner : NSObject
// One scanner for the app: the Current tab drives scanning, ALWiFiJoin joins with it.
+ (instancetype)shared;
@property (nonatomic, copy) void (^onDevice)(ALDevice *device);
@property (nonatomic, readonly) BOOL available;
@property (nonatomic, copy) NSString *status; // human-readable state for on-screen debug
- (void)start;   // begins periodic scans
- (void)stop;
- (void)scanOnce;
// The network we're currently associated with (nil if not connected). Parsed the
// same way as scan results, so its identifier (BSSID) matches the database's.
- (ALDevice *)currentNetwork;
// Starts joining the strongest of these access points (BSSIDs) as seen in the
// last scan, via MobileWiFi's private association call. Scans pause for a few
// seconds meanwhile. Returns NO if none of them was in the last scan or the API
// is missing. The outcome isn't reported: check currentNetwork.
- (BOOL)associateWithBSSIDs:(NSArray<NSString *> *)bssids;
@end
