#import <Foundation/Foundation.h>
#import "ALDevice.h"

@interface ALWiFiScanner : NSObject
@property (nonatomic, copy) void (^onDevice)(ALDevice *device);
@property (nonatomic, readonly) BOOL available;
@property (nonatomic, copy) NSString *status; // human-readable state for on-screen debug
- (void)start;   // begins periodic scans
- (void)stop;
- (void)scanOnce;
@end
