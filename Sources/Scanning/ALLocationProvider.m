//
//  ALLocationProvider.m — AirLogger
//
//  Core Location wrapper (singleton). Exposes the current fix and a status
//  string, with background updates enabled so scanning/logging continues with
//  the screen off.
//

#import "ALLocationProvider.h"

@interface ALLocationProvider () <CLLocationManagerDelegate>
@property (nonatomic, strong) CLLocationManager *manager;
@property (nonatomic, strong, readwrite) CLLocation *currentLocation;
@property (nonatomic, copy, readwrite) NSString *status;
@end

@implementation ALLocationProvider

+ (instancetype)shared {
	static ALLocationProvider *s;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [[ALLocationProvider alloc] init]; });
	return s;
}

- (instancetype)init {
	if ((self = [super init])) {
		_status = @"starting…";
	}
	return self;
}

- (void)start {
	if (self.manager) return;
	self.manager = [[CLLocationManager alloc] init];
	self.manager.delegate = self;
	self.manager.desiredAccuracy = kCLLocationAccuracyBest;
	self.manager.distanceFilter = kCLDistanceFilterNone;
	// Keep scanning alive with the screen off / app backgrounded.
	self.manager.pausesLocationUpdatesAutomatically = NO;
	@try { self.manager.allowsBackgroundLocationUpdates = YES; } @catch (__unused id e) {}
	// No blue background-location bar; the status bar's location arrow still shows.
	// iOS only honors NO with "Always" authorization — under "While Using" the bar is forced.
	if (@available(iOS 11.0, *)) self.manager.showsBackgroundLocationIndicator = NO;
	[self.manager requestAlwaysAuthorization];
	[self.manager requestWhenInUseAuthorization];
	[self.manager startUpdatingLocation];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locs {
	CLLocation *loc = locs.lastObject;
	if (!loc) return;
	self.currentLocation = loc;
	self.status = [NSString stringWithFormat:@"±%.0f m", loc.horizontalAccuracy];
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
	if (!self.currentLocation) self.status = @"no fix";
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager API_AVAILABLE(ios(14.0)) {
	CLAuthorizationStatus s = manager.authorizationStatus;
	if (s == kCLAuthorizationStatusDenied || s == kCLAuthorizationStatusRestricted) {
		self.status = @"denied";
	} else if (s == kCLAuthorizationStatusNotDetermined) {
		self.status = @"awaiting permission";
	} else {
		[manager startUpdatingLocation];
	}
}

@end
