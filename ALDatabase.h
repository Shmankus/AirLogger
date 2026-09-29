#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import "ALDevice.h"

@interface ALDatabase : NSObject
+ (instancetype)shared;

// Records a sighting (throttled per-identifier). location may be nil.
- (void)recordDevice:(ALDevice *)device location:(CLLocation *)location;

// One row per device at the location where it had the strongest signal.
// Each dict: identifier, name, type (NSNumber), rssi (NSNumber), lat, lon (NSNumber).
- (NSArray<NSDictionary *> *)bestLocationsPerDevice;

// Every geotagged observation: identifier, name, type, rssi, lat, lon.
- (NSArray<NSDictionary *> *)geotaggedObservations;

// One summary row per distinct device (all history, GPS or not):
// identifier, type, rssi (best), cnt, last (ts), name, info (json), channel.
- (NSArray<NSDictionary *> *)allDevices;

// Latest speed test per Wi-Fi access point (BSSID); a new result replaces the old.
- (void)recordSpeedTestForIdentifier:(NSString *)identifier ssid:(NSString *)ssid
							down:(double)downMbps up:(double)upMbps;
// @{identifier, ssid, down, up (Mbps NSNumbers), ts} or nil if never tested.
- (NSDictionary *)speedTestForIdentifier:(NSString *)identifier;

- (NSUInteger)totalSightings;
- (NSString *)path;

// Permanently deletes every stored sighting and speed test.
- (void)wipe;
@end
