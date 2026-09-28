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

- (NSUInteger)totalSightings;
- (NSString *)path;

// Permanently deletes every stored sighting.
- (void)wipe;
@end
