#import <UIKit/UIKit.h>

@interface ALHistoryViewController : UITableViewController
// Pops back to the list and pushes the detail page for this identifier.
- (void)showDetailForIdentifier:(NSString *)identifier;
@end
