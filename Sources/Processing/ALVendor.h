#import <Foundation/Foundation.h>

// Manufacturer lookups backed by bundled tables (Resources/oui.txt from
// Wireshark's manuf list, Resources/company_ids.txt from the Bluetooth SIG).
@interface ALVendor : NSObject

// Parses both tables on a background queue so the first lookup doesn't stall
// the main thread (the OUI table has ~40k entries).
+ (void)preload;

// Lowercase, zero-padded "aa:bb:cc:dd:ee:ff". Anything that isn't a 6-byte
// MAC is returned unchanged.
+ (NSString *)normalizeMAC:(NSString *)mac;

// YES if the locally administered bit is set (randomized / private address),
// in which case the OUI means nothing.
+ (BOOL)isRandomizedMAC:(NSString *)mac;

// Manufacturer registered for the MAC's first 3 bytes, or nil.
+ (NSString *)vendorForMAC:(NSString *)mac;

// Bluetooth SIG company name for a 16-bit company identifier, or nil.
+ (NSString *)companyNameForID:(uint16_t)companyID;

@end
