#import <Foundation/Foundation.h>
#import "ALDevice.h"

@interface ALBluetoothScanner : NSObject
@property (nonatomic, copy) void (^onDevice)(ALDevice *device);
@property (nonatomic, copy) NSString *bleStatus;     // on-screen debug
@property (nonatomic, copy) NSString *classicStatus; // on-screen debug
- (void)start;
- (void)stop;
@end
