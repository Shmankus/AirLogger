//
//  ALWiFiJoin.m — AirLogger
//
//  Joins open (passwordless) Wi-Fi networks. First choice is MobileWiFi's private
//  association call on the network object from the last scan (ALWiFiScanner):
//  NEHotspotConfiguration fails for this ad-hoc-signed app with a bare
//  NEHotspotConfigurationErrorUnknown (11). If the network wasn't in the last
//  scan, or association doesn't connect, it falls back to NEHotspotConfiguration
//  (needs the HotspotConfiguration entitlement; iOS shows its own prompt).
//  Either way the result is verified by polling the current network.
//

#import "ALWiFiJoin.h"
#import "ALWiFiScanner.h"
#import "ALLog.h"
#import <NetworkExtension/NetworkExtension.h>

NSString *const ALWiFiJoinStateChangedNotification = @"ALWiFiJoinStateChangedNotification";

static const int kJoinPollSeconds = 8;
static const int kLeavePollSeconds = 5;
// After leaving, look again this long later: auto-join can pull the phone
// straight back onto a saved network.
static const NSTimeInterval kRejoinCheckDelay = 3.0;

@implementation ALWiFiJoin

+ (BOOL)isOpen:(ALDevice *)d {
	if (d.type != ALDeviceTypeWiFi) return NO;
	if (d.children.count) {
		for (ALDevice *c in d.children) if (![self isOpen:c]) return NO;
		return YES;
	}
	return [d.info[@"Security"] isEqualToString:@"Open"];
}

+ (BOOL)isSaved:(ALDevice *)d {
	return d.type == ALDeviceTypeWiFi && [[ALWiFiScanner shared] isSavedSSID:d.name];
}

+ (BOOL)canJoin:(ALDevice *)d {
	if (!([self isOpen:d] || [self isSaved:d]) || d.name.length == 0) return NO;
	for (ALDevice *c in (d.children.count ? d.children : @[d]))
		if ([c.info[@"Hidden"] isEqualToString:@"Yes"]) return NO;
	return YES;
}

+ (void)join:(ALDevice *)d from:(UIViewController *)vc {
	if (![self canJoin:d]) return;
	NSString *ssid = [d.name copy];
	NSMutableArray<NSString *> *bssids = [NSMutableArray array];
	for (ALDevice *ap in (d.children.count ? d.children : @[d]))
		if (ap.identifier) [bssids addObject:ap.identifier];

	__weak UIViewController *weakVC = vc;
	UIAlertController *progress = [UIAlertController
		alertControllerWithTitle:[NSString stringWithFormat:@"Joining \"%@\"…", ssid]
						 message:nil preferredStyle:UIAlertControllerStyleAlert];
	[vc presentViewController:progress animated:YES completion:nil];

	if (![self isOpen:d]) {
		[self joinSaved:ssid bssids:bssids progress:progress vc:weakVC];
		return;
	}
	if (![[ALWiFiScanner shared] associateWithBSSIDs:bssids]) {
		ALLog(@"Join: '%@' not in the last scan (or MobileWiFi unavailable); trying NEHotspotConfiguration", ssid);
		[self joinWithHotspotConfiguration:ssid progress:progress vc:weakVC];
		return;
	}
	[self waitForSSID:ssid tries:kJoinPollSeconds done:^(BOOL joined) {
		ALLog(@"Join: '%@' via MobileWiFi %@", ssid, joined ? @"connected" : @"did not connect");
		if (joined) [self finish:progress title:[NSString stringWithFormat:@"Joined \"%@\"", ssid]
						 message:@"If the network has a sign-in page, iOS will show it." vc:weakVC];
		else [self joinWithHotspotConfiguration:ssid progress:progress vc:weakVC];
	}];
}

// Secured network saved in Settings. First associate with the scanned AP and let
// wifid match it to the saved credentials; if that doesn't connect, associate
// with the saved record itself. (NEHotspotConfiguration can't help: it would
// need the password.)
+ (void)joinSaved:(NSString *)ssid bssids:(NSArray<NSString *> *)bssids
		 progress:(UIAlertController *)progress vc:(UIViewController *)vc {
	__weak UIViewController *weakVC = vc;
	ALWiFiScanner *wifi = [ALWiFiScanner shared];
	void (^fail)(void) = ^{
		[self finish:progress title:[NSString stringWithFormat:@"Couldn't join \"%@\"", ssid]
			 message:@"The network may be out of range. Try joining it once from Settings." vc:weakVC];
	};
	void (^trySavedRecord)(void) = ^{
		if (![wifi associateWithSavedSSID:ssid]) { fail(); return; }
		[self waitForSSID:ssid tries:kJoinPollSeconds done:^(BOOL joined) {
			ALLog(@"Join: '%@' via saved record %@", ssid, joined ? @"connected" : @"did not connect");
			if (joined) [self finish:progress title:[NSString stringWithFormat:@"Joined \"%@\"", ssid]
							 message:@"Used the password saved in Settings." vc:weakVC];
			else fail();
		}];
	};

	if (![wifi associateWithBSSIDs:bssids]) { trySavedRecord(); return; }
	[self waitForSSID:ssid tries:kJoinPollSeconds done:^(BOOL joined) {
		ALLog(@"Join: '%@' (saved) via scan result %@", ssid, joined ? @"connected" : @"did not connect");
		if (joined) [self finish:progress title:[NSString stringWithFormat:@"Joined \"%@\"", ssid]
						 message:@"Used the password saved in Settings." vc:weakVC];
		else trySavedRecord();
	}];
}

#pragma mark - Leave

+ (BOOL)isConnected:(ALDevice *)d {
	if (d.type != ALDeviceTypeWiFi || d.name.length == 0) return NO;
	return [[[ALWiFiScanner shared] currentNetwork].name isEqualToString:d.name];
}

+ (void)leave:(ALDevice *)d from:(UIViewController *)vc {
	NSString *ssid = [d.name copy];
	__weak UIViewController *weakVC = vc;
	ALWiFiScanner *wifi = [ALWiFiScanner shared];

	// The screen may be stale: the phone could have dropped off (or been moved to
	// another network) since it was opened.
	if (![self isConnected:d]) {
		ALLog(@"Leave: '%@' not connected", ssid);
		[self finish:nil title:[NSString stringWithFormat:@"Not connected to \"%@\"", ssid]
			 message:@"You're already disconnected from this network." vc:weakVC];
		return;
	}

	UIAlertController *progress = [UIAlertController
		alertControllerWithTitle:[NSString stringWithFormat:@"Leaving \"%@\"…", ssid]
						 message:nil preferredStyle:UIAlertControllerStyleAlert];
	[vc presentViewController:progress animated:YES completion:nil];

	void (^fail)(NSString *) = ^(NSString *why) {
		[self finish:progress title:[NSString stringWithFormat:@"Couldn't leave \"%@\"", ssid] message:why vc:weakVC];
	};
	if (![wifi disassociate]) { fail(@"MobileWiFi's disconnect call isn't available."); return; }

	[self waitForLeaving:ssid tries:kLeavePollSeconds done:^(BOOL left) {
		ALLog(@"Leave: '%@' %@", ssid, left ? @"disconnected" : @"still connected");
		if (!left) { fail(@"iOS is still connected to it."); return; }
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRejoinCheckDelay * NSEC_PER_SEC)),
					   dispatch_get_main_queue(), ^{
			if ([self isConnected:d]) {
				ALLog(@"Leave: '%@' auto-rejoined", ssid);
				fail(@"iOS reconnected to it automatically (Auto-Join). Turn off Auto-Join for it in Settings to stay off.");
				return;
			}
			[self finish:progress title:[NSString stringWithFormat:@"Disconnected from \"%@\"", ssid]
				 message:@"The network is still saved; you can join it again from here." vc:weakVC];
		});
	}];
}

// Polls once a second until the phone is no longer on `ssid`.
+ (void)waitForLeaving:(NSString *)ssid tries:(int)tries done:(void (^)(BOOL left))done {
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		if (![[[ALWiFiScanner shared] currentNetwork].name isEqualToString:ssid]) { done(YES); return; }
		if (tries <= 1) { done(NO); return; }
		[self waitForLeaving:ssid tries:tries - 1 done:done];
	});
}

#pragma mark - Helpers

// Polls the current network once a second for up to `tries` seconds.
+ (void)waitForSSID:(NSString *)ssid tries:(int)tries done:(void (^)(BOOL joined))done {
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		if ([[[ALWiFiScanner shared] currentNetwork].name isEqualToString:ssid]) { done(YES); return; }
		if (tries <= 1) { done(NO); return; }
		[self waitForSSID:ssid tries:tries - 1 done:done];
	});
}

+ (void)joinWithHotspotConfiguration:(NSString *)ssid progress:(UIAlertController *)progress
								  vc:(UIViewController *)vc {
	__weak UIViewController *weakVC = vc;
	NEHotspotConfiguration *cfg = [[NEHotspotConfiguration alloc] initWithSSID:ssid];
	cfg.joinOnce = NO;
	[[NEHotspotConfigurationManager sharedManager] applyConfiguration:cfg completionHandler:^(NSError *error) {
		dispatch_async(dispatch_get_main_queue(), ^{
			BOOL already = [error.domain isEqualToString:NEHotspotConfigurationErrorDomain] &&
						   error.code == NEHotspotConfigurationErrorAlreadyAssociated;
			if (error && !already) {
				ALLog(@"Join: '%@' NEHotspotConfiguration failed: %@ (%@ %ld)",
					  ssid, error.localizedDescription, error.domain, (long)error.code);
				BOOL cancelled = [error.domain isEqualToString:NEHotspotConfigurationErrorDomain] &&
								 error.code == NEHotspotConfigurationErrorUserDenied;
				[self finish:progress title:cancelled ? nil : [NSString stringWithFormat:@"Couldn't join \"%@\"", ssid]
					 message:@"The network may be out of range, or iOS refused the request." vc:weakVC];
				return;
			}
			[self waitForSSID:ssid tries:kJoinPollSeconds done:^(BOOL joined) {
				ALLog(@"Join: '%@' via NEHotspotConfiguration %@", ssid, joined ? @"connected" : @"did not connect");
				[self finish:progress
					   title:joined ? [NSString stringWithFormat:@"Joined \"%@\"", ssid]
									: [NSString stringWithFormat:@"Couldn't join \"%@\"", ssid]
					 message:joined ? @"If the network has a sign-in page, iOS will show it."
									: @"iOS accepted the request but didn't connect. The network may be out of range."
						  vc:weakVC];
			}];
		});
	}];
}

// Dismisses the progress alert, then shows the result (title nil = no result
// alert), and tells screens the connection state may have changed.
+ (void)finish:(UIAlertController *)progress title:(NSString *)title message:(NSString *)msg
			vc:(UIViewController *)vc {
	[[NSNotificationCenter defaultCenter] postNotificationName:ALWiFiJoinStateChangedNotification object:nil];
	void (^show)(void) = ^{ if (title) [self alert:title message:msg on:vc]; };
	if (progress.presentingViewController) [progress dismissViewControllerAnimated:YES completion:show];
	else show();
}

+ (void)alert:(NSString *)title message:(NSString *)msg on:(UIViewController *)vc {
	if (!vc.viewIfLoaded.window) return; // user navigated away
	UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg
													   preferredStyle:UIAlertControllerStyleAlert];
	[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[vc presentViewController:a animated:YES completion:nil];
}

@end
