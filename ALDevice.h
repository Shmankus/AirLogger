#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, ALDeviceType) {
	ALDeviceTypeWiFi = 0,
	ALDeviceTypeBLE,
	ALDeviceTypeClassicBT,
};

@interface ALDevice : NSObject
@property (nonatomic) ALDeviceType type;
@property (nonatomic, copy) NSString *identifier;   // BSSID / UUID / MAC
@property (nonatomic, copy) NSString *name;         // SSID / peripheral name
@property (nonatomic) NSInteger rssi;
@property (nonatomic, strong) NSMutableDictionary *info; // extra per-type fields
@property (nonatomic, strong) NSDate *firstSeen;
@property (nonatomic, strong) NSDate *lastSeen;
@property (nonatomic) NSUInteger sightings;
@property (nonatomic, strong) NSArray<ALDevice *> *children; // per-AP breakdown for grouped Wi-Fi

+ (NSString *)nameForType:(ALDeviceType)type;
- (NSString *)displayName;
@end
