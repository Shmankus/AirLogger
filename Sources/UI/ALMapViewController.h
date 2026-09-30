#import <UIKit/UIKit.h>

@interface ALMapViewController : UIViewController
// Centers the map on this device's pin and opens its popup (shown even if the
// current filters would hide it).
- (void)focusOnIdentifier:(NSString *)identifier;
@end
