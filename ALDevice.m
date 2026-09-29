//
//  ALDevice.m — AirLogger
//
//  Unified model for a scanned device (Wi-Fi / BLE / classic BT): identifier,
//  name, RSSI, an extensible info dictionary, timestamps, and optional child
//  entries (used when Wi-Fi access points are grouped under one SSID).
//

#import "ALDevice.h"

@implementation ALDevice

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

@end
