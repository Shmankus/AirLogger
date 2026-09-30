//
//  ALWiFiIE.m — AirLogger
//
//  802.11 information-element parser for Wi-Fi scan results. MobileWiFi hands
//  back the AP's beacon / probe-response elements (minus SSID and rates, which
//  it exposes separately) as raw [id][length][data] bytes in the "IE" property.
//  Which elements show up depends on the AP; many home routers omit BSS Load,
//  and WPS identity only appears on APs with WPS enabled.
//

#import "ALWiFiIE.h"
#import "ALVendor.h"
#include <ctype.h>

enum {
	kIECountry    = 7,
	kIEBSSLoad    = 11,
	kIEHTCaps     = 45,
	kIEHTOp       = 61,
	kIEVHTCaps    = 191,
	kIEVHTOp      = 192,
	kIEVendor     = 221,
	kIEExtension  = 255,
};
enum {
	kExtHECaps  = 35,
	kExtEHTCaps = 108,
};

@implementation ALWiFiIE

+ (void)parseIE:(NSData *)ie into:(NSMutableDictionary *)info {
	const uint8_t *b = ie.bytes;
	NSUInteger n = ie.length, i = 0;

	BOOL ht = NO, vht = NO, he = NO, eht = NO;
	NSUInteger htStreams = 0, vhtStreams = 0;
	int width = 20;
	NSMutableData *wps = nil; // WPS may be split across several vendor elements
	NSMutableOrderedSet<NSString *> *vendors = [NSMutableOrderedSet orderedSet];

	while (i + 2 <= n) {
		uint8_t eid = b[i];
		NSUInteger len = b[i + 1];
		if (i + 2 + len > n) break; // truncated
		const uint8_t *v = b + i + 2;
		i += 2 + len;

		switch (eid) {
			case kIECountry:
				if (len >= 2 && isalpha(v[0]) && isalpha(v[1]))
					info[@"Country"] = [NSString stringWithFormat:@"%c%c", v[0], v[1]];
				break;

			case kIEBSSLoad:
				// station count (LE16), channel utilization (0-255), admission capacity
				if (len >= 3) {
					info[@"Clients"] = [NSString stringWithFormat:@"%u", (unsigned)(v[0] | (v[1] << 8))];
					info[@"Channel Utilization"] = [NSString stringWithFormat:@"%.0f%%", v[2] * 100.0 / 255.0];
				}
				break;

			case kIEHTCaps:
				ht = YES;
				// Rx MCS bitmask starts at offset 3; one byte per spatial stream.
				if (len >= 7) for (int s = 0; s < 4; s++) if (v[3 + s]) htStreams = s + 1;
				break;

			case kIEHTOp:
				// Secondary channel offset (1 above / 3 below) means a 40 MHz channel.
				if (len >= 2 && (v[1] & 0x03) && width < 40) width = 40;
				break;

			case kIEVHTCaps:
				vht = YES;
				// Rx MCS map (LE16 at offset 4): 2 bits per stream, 3 = unsupported.
				if (len >= 6) {
					uint16_t map = (uint16_t)(v[4] | (v[5] << 8));
					for (int s = 0; s < 8; s++) if (((map >> (2 * s)) & 0x03) != 0x03) vhtStreams = s + 1;
				}
				break;

			case kIEVHTOp:
				// width(1) center-seg0(1) center-seg1(1)
				if (len >= 3) {
					int w = 0;
					if (v[0] == 1) {
						int d = v[2] ? abs((int)v[2] - (int)v[1]) : 0;
						w = (d == 8) ? 160 : (d > 16 ? 8080 : 80);
					} else if (v[0] == 2) w = 160;
					else if (v[0] == 3) w = 8080;
					if (w && w > width) width = w;
				}
				break;

			case kIEExtension:
				if (len >= 1 && v[0] == kExtHECaps) he = YES;
				if (len >= 1 && v[0] == kExtEHTCaps) eht = YES;
				break;

			case kIEVendor: {
				if (len < 4) break;
				uint32_t oui = ((uint32_t)v[0] << 16) | (v[1] << 8) | v[2];
				uint8_t type = v[3];
				if (oui == 0x0050F2) {          // Microsoft: WPA / WMM / WPS
					if (type == 4) {
						if (!wps) wps = [NSMutableData data];
						[wps appendBytes:v + 4 length:len - 4];
					}
				} else if (oui == 0x506F9A) {   // Wi-Fi Alliance
					if (type == 0x09) info[@"Wi-Fi Direct"] = @"Yes";
					else if (type == 0x10) info[@"Hotspot 2.0"] = @"Yes";
				} else {
					NSString *mac = [NSString stringWithFormat:@"%02x:%02x:%02x:00:00:00", v[0], v[1], v[2]];
					NSString *name = [ALVendor vendorForMAC:mac];
					[vendors addObject:name ?: [NSString stringWithFormat:@"%02X:%02X:%02X", v[0], v[1], v[2]]];
				}
				break;
			}
		}
	}

	NSString *gen = eht ? @"Wi-Fi 7 (802.11be)" : he ? @"Wi-Fi 6 (802.11ax)" : vht ? @"Wi-Fi 5 (802.11ac)"
		: ht ? @"Wi-Fi 4 (802.11n)" : @"Legacy (802.11a/b/g)";
	info[@"Wi-Fi Generation"] = gen;
	info[@"Channel Width"] = width == 8080 ? @"80+80 MHz" : [NSString stringWithFormat:@"%d MHz", width];
	NSUInteger streams = vhtStreams ?: htStreams;
	if (streams) info[@"Spatial Streams"] = [NSString stringWithFormat:@"%lu", (unsigned long)streams];
	if (vendors.count) info[@"Vendor Elements"] = [vendors.array componentsJoinedByString:@", "];
	if (wps) [self parseWPS:wps into:info];
}

#pragma mark - WPS

// Trims padding/NULs; returns nil for empty or placeholder values.
static NSString *wpsString(const uint8_t *v, NSUInteger len) {
	NSString *s = [[NSString alloc] initWithBytes:v length:len encoding:NSUTF8StringEncoding]
		?: [[NSString alloc] initWithBytes:v length:len encoding:NSISOLatin1StringEncoding];
	NSMutableCharacterSet *trim = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
	[trim addCharactersInString:@"\0"];
	s = [s stringByTrimmingCharactersInSet:trim];
	if (!s.length || [s isEqualToString:@"0"]) return nil;
	return s;
}

+ (NSString *)wpsCategory:(uint16_t)cat sub:(uint16_t)sub {
	switch (cat) {
		case 1:  return @"Computer";
		case 2:  return @"Input device";
		case 3:  return @"Printer / scanner";
		case 4:  return @"Camera";
		case 5:  return @"Storage (NAS)";
		case 6: {
			NSArray *subs = @[@"Network device", @"Access point", @"Router", @"Switch", @"Gateway", @"Bridge"];
			return sub < subs.count ? subs[sub] : subs[0];
		}
		case 7:  return sub == 1 ? @"TV" : @"Display";
		case 8:  return sub == 4 ? @"Set-top box" : @"Media device";
		case 9:  return @"Game console";
		case 10: return @"Phone (hotspot)";
		case 11: return @"Audio device";
	}
	return nil;
}

// WPS attributes: [type BE16][length BE16][value].
+ (void)parseWPS:(NSData *)d into:(NSMutableDictionary *)info {
	const uint8_t *b = d.bytes;
	NSUInteger n = d.length, i = 0;
	while (i + 4 <= n) {
		uint16_t type = (uint16_t)((b[i] << 8) | b[i + 1]);
		NSUInteger len = (b[i + 2] << 8) | b[i + 3];
		if (i + 4 + len > n) break;
		const uint8_t *v = b + i + 4;
		i += 4 + len;

		NSString *s = nil;
		switch (type) {
			case 0x1021: if ((s = wpsString(v, len))) info[@"WPS Manufacturer"] = s; break;
			case 0x1023: if ((s = wpsString(v, len))) info[@"WPS Model Name"] = s; break;
			case 0x1024: if ((s = wpsString(v, len))) info[@"WPS Model Number"] = s; break;
			case 0x1011: if ((s = wpsString(v, len))) info[@"WPS Device Name"] = s; break;
			case 0x1044:
				if (len >= 1) info[@"WPS"] = v[0] == 2 ? @"Enabled (configured)" : @"Enabled (unconfigured)";
				break;
			case 0x1054:
				// category(2) OUI(4) subcategory(2)
				if (len >= 8) {
					NSString *kind = [self wpsCategory:(uint16_t)((v[0] << 8) | v[1])
												   sub:(uint16_t)((v[6] << 8) | v[7])];
					if (kind) info[@"Device Kind"] = kind;
				}
				break;
		}
	}
	if (!info[@"WPS"]) info[@"WPS"] = @"Enabled";
}

@end
