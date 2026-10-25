//
//  ALDevice.m — AirLogger
//
//  Unified model for a scanned device (Wi-Fi / BLE / classic BT): identifier,
//  name, RSSI, an extensible info dictionary, timestamps, and optional child
//  entries (used when Wi-Fi access points are grouped under one SSID).
//

#import "ALDevice.h"

NSString *const ALHideUnnamedChangedNotification = @"ALHideUnnamedChanged";
static NSString *const kHideUnnamedKey = @"ALHideUnnamed";

@implementation ALDevice

+ (BOOL)hideUnnamed {
	id v = [[NSUserDefaults standardUserDefaults] objectForKey:kHideUnnamedKey];
	return v ? [v boolValue] : YES;
}

+ (void)setHideUnnamed:(BOOL)hide {
	[[NSUserDefaults standardUserDefaults] setBool:hide forKey:kHideUnnamedKey];
	[[NSNotificationCenter defaultCenter] postNotificationName:ALHideUnnamedChangedNotification object:nil];
}

- (instancetype)init {
	if ((self = [super init])) {
		_info = [NSMutableDictionary dictionary];
		_firstSeen = [NSDate date];
		_lastSeen = _firstSeen;
		_sightings = 0;
	}
	return self;
}

+ (NSString *)nameForType:(ALDeviceType)type {
	switch (type) {
		case ALDeviceTypeWiFi:       return @"Wi-Fi";
		case ALDeviceTypeBLE:        return @"Bluetooth LE";
		case ALDeviceTypeClassicBT:  return @"Bluetooth (Classic)";
	}
	return @"Unknown";
}

- (NSString *)displayName {
	if (_name.length) return _name;
	return @"(unnamed)";
}

- (NSString *)sightingsText {
	unsigned long n = (unsigned long)_sightings;
	if (!_fromHistory) return [NSString stringWithFormat:@"%lu heard", n];
	return [NSString stringWithFormat:@"%lu %@", n, n == 1 ? @"place" : @"places"];
}

@end
