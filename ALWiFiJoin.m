//
//  ALWiFiJoin.m — AirLogger
//
//  Joins open (passwordless) Wi-Fi networks via the public NEHotspotConfiguration
//  API, which needs the com.apple.developer.networking.HotspotConfiguration
//  entitlement. iOS shows its own "wants to join" prompt; the network is saved as
//  managed by this app. applyConfiguration can report success even when the join
//  didn't happen, so the result is verified against the current network.
//

#import "ALWiFiJoin.h"
#import "ALLog.h"
#import <NetworkExtension/NetworkExtension.h>

@implementation ALWiFiJoin

+ (BOOL)isOpen:(ALDevice *)d {
	if (d.type != ALDeviceTypeWiFi) return NO;
	if (d.children.count) {
		for (ALDevice *c in d.children) if (![self isOpen:c]) return NO;
		return YES;
	}
	return [d.info[@"Security"] isEqualToString:@"Open"];
}

+ (BOOL)canJoin:(ALDevice *)d {
	if (![self isOpen:d] || d.name.length == 0) return NO;
	for (ALDevice *c in (d.children.count ? d.children : @[d]))
		if ([c.info[@"Hidden"] isEqualToString:@"Yes"]) return NO;
	return YES;
}

+ (void)join:(ALDevice *)d from:(UIViewController *)vc {
	if (![self canJoin:d]) return;
	NSString *ssid = [d.name copy];
	NEHotspotConfiguration *cfg = [[NEHotspotConfiguration alloc] initWithSSID:ssid];
	cfg.joinOnce = NO;

	__weak UIViewController *weakVC = vc;
	[[NEHotspotConfigurationManager sharedManager] applyConfiguration:cfg completionHandler:^(NSError *error) {
		dispatch_async(dispatch_get_main_queue(), ^{
			if (error && !([error.domain isEqualToString:NEHotspotConfigurationErrorDomain] &&
						   error.code == NEHotspotConfigurationErrorAlreadyAssociated)) {
				ALLog(@"Join: '%@' failed: %@ (%@ %ld)", ssid, error.localizedDescription, error.domain, (long)error.code);
				if ([error.domain isEqualToString:NEHotspotConfigurationErrorDomain] &&
					error.code == NEHotspotConfigurationErrorUserDenied) return; // user tapped Cancel
				[self alert:[NSString stringWithFormat:@"Couldn't join \"%@\"", ssid]
					message:error.localizedDescription on:weakVC];
				return;
			}
			// Give the association a moment, then confirm where we actually are.
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
				[NEHotspotNetwork fetchCurrentWithCompletionHandler:^(NEHotspotNetwork *net) {
					dispatch_async(dispatch_get_main_queue(), ^{
						ALLog(@"Join: '%@' applied; current SSID now '%@'", ssid, net.SSID);
						if (!net) {
							// iOS wouldn't tell us the current network, so we can't confirm.
							[self alert:[NSString stringWithFormat:@"Joining \"%@\"", ssid]
								message:@"Check the Connected Wi-Fi card on the Current tab." on:weakVC];
						} else if ([net.SSID isEqualToString:ssid]) {
							[self alert:[NSString stringWithFormat:@"Joined \"%@\"", ssid]
								message:@"If the network has a sign-in page, iOS will show it." on:weakVC];
						} else {
							[self alert:[NSString stringWithFormat:@"Couldn't join \"%@\"", ssid]
								message:@"iOS accepted the request but didn't connect. The network may be out of range." on:weakVC];
						}
					});
				}];
			});
		});
	}];
}

+ (void)alert:(NSString *)title message:(NSString *)msg on:(UIViewController *)vc {
	if (!vc.viewIfLoaded.window) return; // user navigated away
	UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg
													   preferredStyle:UIAlertControllerStyleAlert];
	[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[vc presentViewController:a animated:YES completion:nil];
}

@end
