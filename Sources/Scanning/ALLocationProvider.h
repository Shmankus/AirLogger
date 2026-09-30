#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

@interface ALLocationProvider : NSObject
+ (instancetype)shared;
- (void)start;
@property (nonatomic, strong, readonly) CLLocation *currentLocation;
@property (nonatomic, copy, readonly) NSString *status; // e.g. "±8 m" / "no fix" / "denied"
@end
