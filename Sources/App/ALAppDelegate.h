#import <UIKit/UIKit.h>

@interface ALAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;

// Cross-tab navigation. Switch to the Map tab and focus the device's pin, or
// switch to the All tab and open the device's detail page.
+ (void)showOnMap:(NSString *)identifier;
+ (void)showDetailForIdentifier:(NSString *)identifier;
@end
