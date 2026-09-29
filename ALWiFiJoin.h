#import <UIKit/UIKit.h>
#import "ALDevice.h"

// Posted on the main thread when a join or leave attempt finishes (either way),
// so screens can refresh their Join / Disconnect buttons.
extern NSString *const ALWiFiJoinStateChangedNotification;

@interface ALWiFiJoin : NSObject
// No password: Security is plain "Open" (not enterprise). A grouped SSID row is
// open only if every access point in it is.
+ (BOOL)isOpen:(ALDevice *)device;
// Secured but saved in Settings > Wi-Fi (the stored password is used to join).
+ (BOOL)isSaved:(ALDevice *)device;
// Open or saved, and has a name to join by (hidden networks can't be joined from here).
+ (BOOL)canJoin:(ALDevice *)device;
// Joins via MobileWiFi (falling back to NEHotspotConfiguration, which shows its
// own iOS prompt), showing progress and then the verified outcome on `vc`.
+ (void)join:(ALDevice *)device from:(UIViewController *)vc;

// YES if the phone is currently associated with this network (matched by SSID).
+ (BOOL)isConnected:(ALDevice *)device;
// Disconnects from the network (it stays saved), then reports on `vc`: left,
// already disconnected, or couldn't leave (including iOS auto-rejoining it).
+ (void)leave:(ALDevice *)device from:(UIViewController *)vc;
@end
