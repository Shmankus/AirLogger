#import <UIKit/UIKit.h>
#import "ALDevice.h"

@interface ALDeviceCell : UITableViewCell
- (void)configureWithDevice:(ALDevice *)device;
+ (UIColor *)colorForType:(ALDeviceType)type;
+ (UIColor *)colorForRSSI:(NSInteger)rssi;
@end
