#import "ALAppDelegate.h"
#import "ALRootViewController.h"
#import "ALHistoryViewController.h"
#import "ALMapViewController.h"

@implementation ALAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)opts {
	self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

	ALRootViewController *root = [[ALRootViewController alloc] init];
	UINavigationController *listNav = [[UINavigationController alloc] initWithRootViewController:root];
	listNav.navigationBar.prefersLargeTitles = YES;
	listNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Current"
													   image:[UIImage systemImageNamed:@"dot.radiowaves.left.and.right"] tag:0];

	ALHistoryViewController *history = [[ALHistoryViewController alloc] init];
	UINavigationController *histNav = [[UINavigationController alloc] initWithRootViewController:history];
	histNav.navigationBar.prefersLargeTitles = YES;
	histNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"All"
													   image:[UIImage systemImageNamed:@"square.stack.3d.up.fill"] tag:1];

	ALMapViewController *map = [[ALMapViewController alloc] init];
	UINavigationController *mapNav = [[UINavigationController alloc] initWithRootViewController:map];
	mapNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Map"
													  image:[UIImage systemImageNamed:@"map"] tag:2];

	UITabBarController *tabs = [[UITabBarController alloc] init];
	tabs.viewControllers = @[listNav, histNav, mapNav];

	self.window.rootViewController = tabs;
	[self.window makeKeyAndVisible];
	return YES;
}

@end
