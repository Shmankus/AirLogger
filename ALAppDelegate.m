#import "ALAppDelegate.h"
#import "ALRootViewController.h"
#import "ALMapViewController.h"

@implementation ALAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)opts {
	self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

	ALRootViewController *root = [[ALRootViewController alloc] init];
	UINavigationController *listNav = [[UINavigationController alloc] initWithRootViewController:root];
	listNav.navigationBar.prefersLargeTitles = YES;
	listNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Devices"
													   image:[UIImage systemImageNamed:@"list.bullet"] tag:0];

	ALMapViewController *map = [[ALMapViewController alloc] init];
	UINavigationController *mapNav = [[UINavigationController alloc] initWithRootViewController:map];
	mapNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Map"
													  image:[UIImage systemImageNamed:@"map"] tag:1];

	UITabBarController *tabs = [[UITabBarController alloc] init];
	tabs.viewControllers = @[listNav, mapNav];

	self.window.rootViewController = tabs;
	[self.window makeKeyAndVisible];
	return YES;
}

@end
