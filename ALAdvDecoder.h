#import <Foundation/Foundation.h>

// Decodes BLE advertisements into readable fields: "Device Kind", "OS Family",
// and type-specific extras (AirPods batteries, AirPlay IP, iBeacon IDs, ...).
// Formats are reverse-engineered (Apple Continuity, Microsoft CDP), so the
// results are best-effort hints, not guarantees.
@interface ALAdvDecoder : NSObject

// mfg is the full manufacturer data (company ID first). serviceData is keyed by
// UUID string ("FEF3"); serviceUUIDs are UUID strings.
+ (void)decodeManufacturerData:(NSData *)mfg
				   serviceData:(NSDictionary<NSString *, NSData *> *)serviceData
				  serviceUUIDs:(NSArray<NSString *> *)serviceUUIDs
					 localName:(NSString *)localName
						  into:(NSMutableDictionary *)info;

// Same, for a device loaded from the database: reads the hex strings stored in
// info ("Manufacturer Data", "Service Data", "Service UUIDs", "Local Name").
+ (void)decodeStoredInfo:(NSMutableDictionary *)info;

@end
