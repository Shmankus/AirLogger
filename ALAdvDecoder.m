//
//  ALAdvDecoder.m — AirLogger
//
//  BLE advertisement decoder. Recognizes:
//    - Apple (0x004C) Continuity messages: AirPods/Beats proximity pairing
//      (model + batteries), Nearby Info (activity), Find My, AirPlay target
//      (IP/port), iBeacon, Handoff, AirDrop, hotspot, Watch, HomeKit, AirPrint.
//    - Microsoft (0x0006) CDP beacons (Windows / Xbox / ... device type) and
//      Swift Pair.
//    - Samsung / Google markers, and well-known 16-bit service UUIDs (Fast Pair,
//      Tile, SmartTag, Exposure Notifications, Eddystone, HID, heart rate).
//  Layouts follow public reverse-engineering (furiousMAC continuity, OpenPods,
//  OpenHaystack), so treat the output as hints.
//

#import "ALAdvDecoder.h"

static NSString *const kKind = @"Device Kind";
static NSString *const kOS = @"OS Family";

@implementation ALAdvDecoder

#pragma mark - Helpers

// Earlier (more specific) decoders win; later ones only fill gaps.
static void setIfAbsent(NSMutableDictionary *info, NSString *key, NSString *value) {
	if (value.length && !info[key]) info[key] = value;
}

+ (NSData *)dataFromHex:(NSString *)hex {
	NSMutableData *d = [NSMutableData dataWithCapacity:hex.length / 2];
	const char *s = hex.UTF8String;
	size_t n = s ? strlen(s) : 0;
	for (size_t i = 0; i + 1 < n; i += 2) {
		char pair[3] = { s[i], s[i + 1], 0 };
		char *end = NULL;
		uint8_t byte = (uint8_t)strtoul(pair, &end, 16);
		if (end != pair + 2) return nil;
		[d appendBytes:&byte length:1];
	}
	return d;
}

#pragma mark - Entry points

+ (void)decodeManufacturerData:(NSData *)mfg
				   serviceData:(NSDictionary<NSString *, NSData *> *)serviceData
				  serviceUUIDs:(NSArray<NSString *> *)serviceUUIDs
					 localName:(NSString *)localName
						  into:(NSMutableDictionary *)info {
	if (mfg.length >= 2) {
		const uint8_t *b = mfg.bytes;
		uint16_t cid = (uint16_t)(b[0] | (b[1] << 8));
		NSData *p = [mfg subdataWithRange:NSMakeRange(2, mfg.length - 2)];
		switch (cid) {
			case 0x004C: [self decodeApple:p into:info]; break;
			case 0x0006: [self decodeMicrosoft:p into:info]; break;
			case 0x0075:
				setIfAbsent(info, kKind, @"Samsung device (Galaxy / SmartThings)");
				setIfAbsent(info, kOS, @"Android / Tizen");
				break;
			case 0x00E0:
				setIfAbsent(info, kKind, @"Google device");
				setIfAbsent(info, kOS, @"Android");
				break;
		}
	}

	NSMutableSet<NSString *> *uuids = [NSMutableSet setWithArray:serviceUUIDs ?: @[]];
	[uuids addObjectsFromArray:serviceData.allKeys ?: @[]];
	for (NSString *u in uuids) [self decodeServiceUUID:u.uppercaseString into:info];

	if ([localName hasPrefix:@"[TV]"]) {
		setIfAbsent(info, kKind, @"Samsung TV");
		setIfAbsent(info, kOS, @"Tizen");
	} else if ([localName hasPrefix:@"[AV]"]) {
		setIfAbsent(info, kKind, @"Samsung soundbar");
	}
}

+ (void)decodeStoredInfo:(NSMutableDictionary *)info {
	NSData *mfg = [info[@"Manufacturer Data"] isKindOfClass:[NSString class]]
		? [self dataFromHex:info[@"Manufacturer Data"]] : nil;

	// Stored as "UUID=HEX" lines.
	NSMutableDictionary *svc = [NSMutableDictionary dictionary];
	if ([info[@"Service Data"] isKindOfClass:[NSString class]]) {
		for (NSString *line in [info[@"Service Data"] componentsSeparatedByString:@"\n"]) {
			NSRange eq = [line rangeOfString:@"="];
			if (eq.location == NSNotFound) continue;
			NSData *v = [self dataFromHex:[line substringFromIndex:NSMaxRange(eq)]];
			if (v) svc[[line substringToIndex:eq.location]] = v;
		}
	}

	NSArray *uuids = nil;
	if ([info[@"Service UUIDs"] isKindOfClass:[NSString class]])
		uuids = [info[@"Service UUIDs"] componentsSeparatedByString:@", "];

	NSString *name = [info[@"Local Name"] isKindOfClass:[NSString class]] ? info[@"Local Name"] : nil;
	[self decodeManufacturerData:mfg serviceData:svc serviceUUIDs:uuids localName:name into:info];
}

#pragma mark - Apple Continuity

// Payload after the company ID is a sequence of [type][length][value] messages.
+ (void)decodeApple:(NSData *)p into:(NSMutableDictionary *)info {
	const uint8_t *b = p.bytes;
	NSUInteger n = p.length, i = 0;
	NSMutableArray<NSString *> *msgs = [NSMutableArray array];
	while (i + 2 <= n) {
		uint8_t type = b[i];
		// 0x01 (background-app "overflow" bitmask) has no length byte and runs to
		// the end of the payload.
		if (type == 0x01) {
			[msgs addObject:[self decodeAppleType:type value:b + i + 1 length:n - i - 1 into:info]];
			break;
		}
		NSUInteger len = b[i + 1];
		if (i + 2 + len > n) len = n - i - 2; // truncated: decode what's there
		NSString *label = [self decodeAppleType:type value:b + i + 2 length:len into:info];
		[msgs addObject:label ?: [NSString stringWithFormat:@"0x%02X", type]];
		i += 2 + len;
	}
	if (msgs.count) info[@"Apple Messages"] = [msgs componentsJoinedByString:@", "];
	setIfAbsent(info, kKind, @"Apple device");
}

// Returns a short label for the message type (nil = unknown type).
+ (NSString *)decodeAppleType:(uint8_t)type value:(const uint8_t *)v length:(NSUInteger)len
						 into:(NSMutableDictionary *)info {
	switch (type) {
		case 0x01:
			setIfAbsent(info, kKind, @"iPhone / iPad (app advertising in background)");
			setIfAbsent(info, kOS, @"iOS / iPadOS");
			return @"Background app";
		case 0x02:
			if (len >= 21) {
				NSUUID *u = [[NSUUID alloc] initWithUUIDBytes:v];
				info[@"iBeacon UUID"] = u.UUIDString;
				info[@"iBeacon Major / Minor"] = [NSString stringWithFormat:@"%u / %u",
					(unsigned)((v[16] << 8) | v[17]), (unsigned)((v[18] << 8) | v[19])];
			}
			setIfAbsent(info, kKind, @"iBeacon");
			return @"iBeacon";
		case 0x03:
			setIfAbsent(info, kKind, @"AirPrint printer");
			return @"AirPrint";
		case 0x05:
			setIfAbsent(info, kKind, @"iPhone / iPad / Mac (AirDrop open)");
			setIfAbsent(info, kOS, @"iOS / macOS");
			return @"AirDrop";
		case 0x06:
			setIfAbsent(info, kKind, @"HomeKit accessory");
			return @"HomeKit";
		case 0x07:
			[self decodeProximityPairing:v length:len into:info];
			return @"Proximity Pairing";
		case 0x08:
			setIfAbsent(info, kKind, @"Apple device (Hey Siri)");
			return @"Hey Siri";
		case 0x09:
			// flags(1) seed(1) IPv4(4) [port(2)]
			if (len >= 6) info[@"AirPlay IP"] = [NSString stringWithFormat:@"%u.%u.%u.%u", v[2], v[3], v[4], v[5]];
			if (len >= 8) info[@"AirPlay Port"] = [NSString stringWithFormat:@"%u", (unsigned)((v[6] << 8) | v[7])];
			setIfAbsent(info, kKind, @"AirPlay receiver (Apple TV / HomePod / Mac)");
			setIfAbsent(info, kOS, @"tvOS / audioOS / macOS");
			return @"AirPlay Target";
		case 0x0A:
			setIfAbsent(info, kOS, @"iOS / macOS");
			return @"AirPlay Source";
		case 0x0B:
			setIfAbsent(info, kKind, @"Apple Watch");
			setIfAbsent(info, kOS, @"watchOS");
			return @"Watch";
		case 0x0C:
			setIfAbsent(info, kOS, @"iOS / macOS");
			return @"Handoff";
		case 0x0D:
			setIfAbsent(info, kOS, @"iOS / macOS");
			return @"Hotspot client";
		case 0x0E:
			setIfAbsent(info, kKind, @"iPhone / iPad (Personal Hotspot)");
			setIfAbsent(info, kOS, @"iOS / iPadOS");
			return @"Personal Hotspot";
		case 0x0F:
			setIfAbsent(info, kOS, @"iOS / macOS");
			return @"Nearby Action";
		case 0x10: {
			// Low nibble of the first byte is the activity ("action") code.
			if (len >= 1) {
				NSString *act = nil;
				switch (v[0] & 0x0F) {
					case 0x01: act = @"Reporting disabled"; break;
					case 0x03: act = @"Idle"; break;
					case 0x05: act = @"Audio playing, screen locked"; break;
					case 0x07: act = @"Screen on"; break;
					case 0x09: act = @"Screen on, video playing"; break;
					case 0x0A: act = @"Watch on wrist, unlocked"; break;
					case 0x0B: act = @"Recently used"; break;
					case 0x0D: act = @"Driving"; break;
					case 0x0E: act = @"On a call"; break;
				}
				if (act) info[@"Activity"] = act;
			}
			setIfAbsent(info, kKind, @"iPhone / iPad / Mac");
			setIfAbsent(info, kOS, @"iOS / macOS");
			return @"Nearby Info";
		}
		case 0x12: {
			// Full-length payload = separated from its owner (AirTag or lost device);
			// short = near its owner. Status byte bits 6-7 = battery level.
			if (len >= 1) {
				NSArray *levels = @[@"Full", @"Medium", @"Low", @"Critically low"];
				info[@"Find My Battery"] = levels[(v[0] >> 6) & 0x03];
			}
			info[@"Find My"] = len >= 25 ? @"Away from owner" : @"Near owner";
			setIfAbsent(info, kKind, @"Find My device (AirTag / Apple device / accessory)");
			return @"Find My";
		}
	}
	return nil;
}

+ (NSString *)podsModelName:(uint16_t)model {
	switch (model) {
		case 0x0220: return @"AirPods (1st gen)";
		case 0x0F20: return @"AirPods (2nd gen)";
		case 0x1320: return @"AirPods (3rd gen)";
		case 0x0E20: return @"AirPods Pro";
		case 0x1420: return @"AirPods Pro (2nd gen)";
		case 0x0A20: return @"AirPods Max";
		case 0x0320: return @"Powerbeats3";
		case 0x0520: return @"BeatsX";
		case 0x0620: return @"Beats Solo3";
		case 0x0920: return @"Beats Studio3";
		case 0x0B20: return @"Powerbeats Pro";
		case 0x0C20: return @"Beats Solo Pro";
		case 0x1020: return @"Beats Flex";
		case 0x1120: return @"Beats Studio Buds";
		case 0x1220: return @"Beats Fit Pro";
	}
	return nil;
}

// Battery nibble: 0-10 = tens of percent, 15 = not connected.
static NSString *podBattery(uint8_t nib, BOOL charging) {
	if (nib == 0x0F) return @"—";
	if (nib > 10) return nil;
	return [NSString stringWithFormat:@"%u%%%@", nib * 10, charging ? @" (charging)" : @""];
}

// Two layouts, told apart by the prefix byte:
//   0x01: prefix(1) model(2) status(1) battery(1) charge|case(1) ... (rest encrypted)
//   0x00: prefix(1) model(2) classic BT address(6) ... (short form, no batteries)
+ (void)decodeProximityPairing:(const uint8_t *)v length:(NSUInteger)len into:(NSMutableDictionary *)info {
	if (len < 3) return;
	uint16_t model = (uint16_t)((v[1] << 8) | v[2]);
	NSString *name = [self podsModelName:model];
	info[@"Audio Model"] = name ?: [NSString stringWithFormat:@"0x%04X", model];
	setIfAbsent(info, kKind, name ?: @"AirPods / Beats headphones");

	if (v[0] == 0x00 && len >= 9) {
		// Same address the classic scanner logs, linking the two sightings.
		info[@"Classic Address"] = [NSString stringWithFormat:@"%02x:%02x:%02x:%02x:%02x:%02x",
									v[3], v[4], v[5], v[6], v[7], v[8]];
		return;
	}
	if (v[0] != 0x01 || len < 6) return;

	// Which battery nibble is left vs right depends on which bud is primary.
	BOOL flip = ((v[3] >> 4) & 0x02) == 0;
	uint8_t hi = v[4] >> 4, lo = v[4] & 0x0F;
	uint8_t chg = v[5] >> 4, caseNib = v[5] & 0x0F;
	NSString *l = podBattery(flip ? hi : lo, (chg & (flip ? 0x02 : 0x01)) != 0);
	NSString *r = podBattery(flip ? lo : hi, (chg & (flip ? 0x01 : 0x02)) != 0);
	NSString *c = podBattery(caseNib, (chg & 0x04) != 0);
	if (l) info[@"Battery Left"] = l;
	if (r) info[@"Battery Right"] = r;
	if (c) info[@"Battery Case"] = c;
}

#pragma mark - Microsoft

// scenario(1): 0x01 = CDP beacon (next byte: version<<5 | device type),
// 0x03 = Swift Pair.
+ (void)decodeMicrosoft:(NSData *)p into:(NSMutableDictionary *)info {
	const uint8_t *b = p.bytes;
	if (p.length < 1) return;
	if (b[0] == 0x03) {
		setIfAbsent(info, kKind, @"Accessory in Swift Pair mode");
		return;
	}
	if (b[0] != 0x01 || p.length < 2) return;
	NSString *kind = nil, *os = nil;
	switch (b[1] & 0x1F) {
		case 1:  kind = @"Xbox One";               os = @"Xbox OS"; break;
		case 6:  kind = @"iPhone (Microsoft app)"; os = @"iOS"; break;
		case 7:  kind = @"iPad (Microsoft app)";   os = @"iPadOS"; break;
		case 8:  kind = @"Android device (Microsoft app)"; os = @"Android"; break;
		case 9:  kind = @"Windows desktop";        os = @"Windows"; break;
		case 11: kind = @"Windows phone";          os = @"Windows"; break;
		case 12: kind = @"Linux device";           os = @"Linux"; break;
		case 13: kind = @"Windows IoT device";     os = @"Windows"; break;
		case 14: kind = @"Surface Hub";            os = @"Windows"; break;
		case 15: kind = @"Windows laptop";         os = @"Windows"; break;
		case 16: kind = @"Windows tablet";         os = @"Windows"; break;
	}
	setIfAbsent(info, kKind, kind ?: @"Microsoft device");
	setIfAbsent(info, kOS, os);
}

#pragma mark - Service UUIDs

+ (void)decodeServiceUUID:(NSString *)u into:(NSMutableDictionary *)info {
	NSString *kind = nil, *os = nil;
	if      ([u isEqualToString:@"FE2C"]) kind = @"Google Fast Pair accessory";
	else if ([u isEqualToString:@"FEF3"] || [u isEqualToString:@"FE9F"]) { kind = @"Google / Android device"; os = @"Android"; }
	else if ([u isEqualToString:@"FD5A"]) kind = @"Samsung SmartTag";
	else if ([u isEqualToString:@"FEED"] || [u isEqualToString:@"FEEC"]) kind = @"Tile tracker";
	else if ([u isEqualToString:@"FD6F"]) kind = @"Phone (Exposure Notifications)";
	else if ([u isEqualToString:@"FEAA"]) kind = @"Eddystone beacon";
	else if ([u isEqualToString:@"FE95"]) kind = @"Xiaomi device";
	else if ([u isEqualToString:@"1812"]) kind = @"Keyboard / mouse / controller (HID)";
	else if ([u isEqualToString:@"180D"]) kind = @"Heart-rate sensor";
	else if ([u isEqualToString:@"1826"]) kind = @"Fitness machine";
	else if ([u isEqualToString:@"181A"]) kind = @"Environmental sensor";
	setIfAbsent(info, kKind, kind);
	setIfAbsent(info, kOS, os);
}

@end
