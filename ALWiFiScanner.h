#import <Foundation/Foundation.h>
#import "ALDevice.h"

@interface ALWiFiScanner : NSObject
@property (nonatomic, copy) void (^onDevice)(ALDevice *device);
@property (nonatomic, readonly) BOOL available;
@property (nonatomic, copy) NSString *status; // human-readable state for on-screen debug
- (void)start;   // begins periodic scans
- (void)stop;
- (void)scanOnce;
// The network we're currently associated with (nil if not connected). Parsed the
// same way as scan results, so its identifier (BSSID) matches the database's.
- (ALDevice *)currentNetwork;
@end
