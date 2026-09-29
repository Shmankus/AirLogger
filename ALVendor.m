//
//  ALVendor.m — AirLogger
//
//  Manufacturer lookups: MAC OUI -> vendor (Wi-Fi BSSIDs, classic BT addresses)
//  and Bluetooth SIG company ID -> name (BLE manufacturer data). Both tables are
//  "KEY\tName" text files in the bundle, parsed once on first use.
//

#import "ALVendor.h"
#import "ALLog.h"

@implementation ALVendor

+ (NSDictionary<NSString *, NSString *> *)loadTable:(NSString *)name {
	NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:@"txt"];
	NSString *text = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
	if (!text) { ALLog(@"vendor: %@.txt missing from bundle", name); return @{}; }
	NSMutableDictionary *d = [NSMutableDictionary dictionaryWithCapacity:40000];
	[text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
		NSRange tab = [line rangeOfString:@"\t"];
		if (tab.location == NSNotFound) return;
		d[[line substringToIndex:tab.location]] = [line substringFromIndex:NSMaxRange(tab)];
	}];
	return d;
}

+ (NSDictionary<NSString *, NSString *> *)ouiTable {
	static NSDictionary *t;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ t = [self loadTable:@"oui"]; });
	return t;
}

+ (NSDictionary<NSString *, NSString *> *)companyTable {
	static NSDictionary *t;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ t = [self loadTable:@"company_ids"]; });
	return t;
}

+ (void)preload {
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		[self ouiTable];
		[self companyTable];
	});
}

// The 6 bytes of a MAC written with ':' or '-' separators (any padding), or NO.
+ (BOOL)parseMAC:(NSString *)mac bytes:(uint8_t *)out {
	NSArray<NSString *> *parts = [mac componentsSeparatedByCharactersInSet:
		[NSCharacterSet characterSetWithCharactersInString:@":-"]];
	if (parts.count != 6) return NO;
	for (NSUInteger i = 0; i < 6; i++) {
		NSString *p = parts[i];
		if (p.length < 1 || p.length > 2) return NO;
		unsigned v = 0;
		NSScanner *sc = [NSScanner scannerWithString:p];
		if (![sc scanHexInt:&v] || !sc.isAtEnd) return NO;
		out[i] = (uint8_t)v;
	}
	return YES;
}

+ (NSString *)normalizeMAC:(NSString *)mac {
	uint8_t b[6];
	if (![self parseMAC:mac bytes:b]) return mac;
	return [NSString stringWithFormat:@"%02x:%02x:%02x:%02x:%02x:%02x", b[0], b[1], b[2], b[3], b[4], b[5]];
}

+ (BOOL)isRandomizedMAC:(NSString *)mac {
	uint8_t b[6];
	return [self parseMAC:mac bytes:b] && (b[0] & 0x02);
}

+ (NSString *)vendorForMAC:(NSString *)mac {
	uint8_t b[6];
	if (![self parseMAC:mac bytes:b] || (b[0] & 0x02)) return nil;
	return [self ouiTable][[NSString stringWithFormat:@"%02X%02X%02X", b[0], b[1], b[2]]];
}

+ (NSString *)companyNameForID:(uint16_t)companyID {
	return [self companyTable][[NSString stringWithFormat:@"%04X", companyID]];
}

@end
