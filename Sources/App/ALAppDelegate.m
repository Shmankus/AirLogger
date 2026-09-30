//
//  ALAppDelegate.m — AirLogger
//
//  App delegate. Builds the root UITabBarController with three tabs:
//  Current (live scan), All (stored history), and Map.
//

#import "ALAppDelegate.h"
#import "ALRootViewController.h"
#import "ALHistoryViewController.h"
#import "ALMapViewController.h"
#import "ALVendor.h"

@interface ALAppDelegate ()
@property (nonatomic, strong) UITabBarController *tabs;
@property (nonatomic, strong) ALHistoryViewController *history;
@property (nonatomic, strong) ALMapViewController *map;
@end

@implementation ALAppDelegate

+ (ALAppDelegate *)shared {
	return (ALAppDelegate *)[UIApplication sharedApplication].delegate;
}

+ (void)showOnMap:(NSString *)identifier {
	ALAppDelegate *app = [self shared];
	[app.map.navigationController popToRootViewControllerAnimated:NO];
	app.tabs.selectedViewController = app.map.navigationController;
	[app.map focusOnIdentifier:identifier];
}

+ (void)showDetailForIdentifier:(NSString *)identifier {
	ALAppDelegate *app = [self shared];
	app.tabs.selectedViewController = app.history.navigationController;
	[app.history showDetailForIdentifier:identifier];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)opts {
	[ALVendor preload];
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
	self.tabs = tabs;
	self.history = history;
	self.map = map;

	self.window.rootViewController = tabs;
	[self.window makeKeyAndVisible];
	return YES;
}

@end
