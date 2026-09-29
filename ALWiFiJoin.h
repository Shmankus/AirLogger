#import <UIKit/UIKit.h>
#import "ALDevice.h"

@interface ALWiFiJoin : NSObject
// No password: Security is plain "Open" (not enterprise). A grouped SSID row is
// open only if every access point in it is.
+ (BOOL)isOpen:(ALDevice *)device;
// Open, and has a name to join by (hidden networks can't be joined from here).
+ (BOOL)canJoin:(ALDevice *)device;
// Joins via MobileWiFi (falling back to NEHotspotConfiguration, which shows its
// own iOS prompt), showing progress and then the verified outcome on `vc`.
+ (void)join:(ALDevice *)device from:(UIViewController *)vc;
@end
