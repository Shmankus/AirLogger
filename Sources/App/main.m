//
//  main.m — AirLogger
//
//  Application entry point. Hands control to ALAppDelegate via UIApplicationMain.
//

#import <UIKit/UIKit.h>
#import "ALAppDelegate.h"
#import "ALLog.h"

int main(int argc, char *argv[]) {
	@autoreleasepool {
		ALLog(@"main() entered");
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([ALAppDelegate class]));
	}
}
