#import <Foundation/Foundation.h>
#import "ALDevice.h"

// Live status in the status bar's carrier text, via the CarrierText tweak
// (com.shmank.carriertext). Nothing is written until a mode is picked; turning
// it off clears the text (like `carriertext set ""`).
typedef NS_ENUM(NSInteger, ALStatusBarMode) {
	ALStatusBarModeOff = 0,
	ALStatusBarModeCounts,        // "W18 L29 C2": devices in range per type
	ALStatusBarModeConnectedWiFi, // "OffTheGrid -41"
	ALStatusBarModeTracking,      // "▂▄▆· -58 AirPods": one device's live signal
};

@interface ALStatusBar : NSObject
+ (instancetype)shared;

@property (nonatomic, readonly) ALStatusBarMode mode;
@property (nonatomic, readonly, copy) NSString *trackedName; // while tracking

- (void)setMode:(ALStatusBarMode)mode;   // Tracking needs trackDevice: instead
- (void)trackDevice:(ALDevice *)device;  // grouped Wi-Fi tracks all its APs
- (BOOL)isTracking:(ALDevice *)device;

// Feeds from the Current tab.
- (void)noteDevice:(ALDevice *)device;
- (void)noteCountsWiFi:(NSUInteger)wifi ble:(NSUInteger)ble classic:(NSUInteger)classic;
// Temporarily replaces the mode's text (e.g. speed test progress). Ignored when off.
- (void)showTransient:(NSString *)text duration:(NSTimeInterval)seconds;
@end

// Posted when the mode or tracked device changes, so menus/buttons can refresh.
extern NSString *const ALStatusBarModeChangedNotification;
