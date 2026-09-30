//
//  ALStatusBar.m — AirLogger
//
//  Drives the status bar's carrier text through the CarrierText tweak. The
//  tweak's CLI (`carriertext`) just edits a plist and posts a Darwin
//  notification, so this does the same directly: keys CarrierText (a string),
//  or LoopTexts + LoopDelay, in the jbroot prefs file, then notify_post. If the
//  sandbox refuses the write, it falls back to running the CLI.
//
//  A 1s tick renders the current mode's text and writes it only when it changed.
//

#import "ALStatusBar.h"
#import "ALWiFiScanner.h"
#import "ALLog.h"
#import <notify.h>
#import <spawn.h>
#import <sys/wait.h>

NSString *const ALStatusBarModeChangedNotification = @"ALStatusBarModeChangedNotification";

static NSString *const kPrefsPath = @"/var/jb/var/mobile/Library/Preferences/com.shmank.carriertext.plist";
static const char *kChangedNotification = "com.shmank.carriertext/changed";
static NSString *const kCLIPath = @"/var/jb/usr/bin/carriertext";

static const NSTimeInterval kCountsStale = 5.0;  // no counts for this long = scanning paused
static const NSTimeInterval kTrackFresh = 4.0;   // readings newer than this count as live
static const NSTimeInterval kTrackLost = 12.0;   // no reading for this long = lost
static const NSUInteger kMaxNameLength = 10;

extern char **environ;

@interface ALStatusBar ()
@property (nonatomic, readwrite) ALStatusBarMode mode;
@property (nonatomic, readwrite, copy) NSString *trackedName;
@property (nonatomic, strong) NSSet<NSString *> *trackedIDs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSArray *> *trackReadings; // id -> @[rssi, date]
@property (nonatomic, strong) NSDate *trackStarted;

@property (nonatomic) NSUInteger wifiCount, bleCount, classicCount;
@property (nonatomic, strong) NSDate *countsAt;

@property (nonatomic, copy) NSString *transient;
@property (nonatomic, strong) NSDate *transientUntil;

@property (nonatomic, strong) NSDictionary *originalPrefs; // restored when turned off
@property (nonatomic, copy) NSString *lastWritten;
@property (nonatomic, strong) NSTimer *timer;
@end

@implementation ALStatusBar

+ (instancetype)shared {
	static ALStatusBar *s;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [[self alloc] init]; });
	return s;
}

#pragma mark - Modes

- (void)setMode:(ALStatusBarMode)mode {
	if (mode == ALStatusBarModeTracking && !self.trackedIDs.count) return;
	if (mode != ALStatusBarModeTracking) { self.trackedIDs = nil; self.trackedName = nil; }

	ALStatusBarMode old = _mode;
	_mode = mode;
	if (old == ALStatusBarModeOff && mode != ALStatusBarModeOff) {
		// Remember the user's own setting (text or loop) to put back later.
		self.originalPrefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath] ?: @{};
		self.lastWritten = nil;
		self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(tick)
													userInfo:nil repeats:YES];
	} else if (mode == ALStatusBarModeOff && old != ALStatusBarModeOff) {
		[self.timer invalidate];
		self.timer = nil;
		self.transient = nil;
		[self writePrefs:self.originalPrefs];
		ALLog(@"statusbar: off, restored previous carrier text");
	}
	ALLog(@"statusbar: mode %ld", (long)mode);
	[self tick];
	[[NSNotificationCenter defaultCenter] postNotificationName:ALStatusBarModeChangedNotification object:self];
}

- (void)trackDevice:(ALDevice *)d {
	NSMutableSet *ids = [NSMutableSet set];
	for (ALDevice *ap in (d.children.count ? d.children : @[d])) if (ap.identifier) [ids addObject:ap.identifier];
	self.trackedIDs = ids;
	self.trackedName = d.displayName;
	self.trackReadings = [NSMutableDictionary dictionary];
	self.trackStarted = [NSDate date];
	// Seed with the reading the screen was showing.
	for (ALDevice *ap in (d.children.count ? d.children : @[d]))
		if (ap.rssi < 0 && ap.identifier) self.trackReadings[ap.identifier] = @[@(ap.rssi), ap.lastSeen ?: [NSDate date]];
	[self setMode:ALStatusBarModeTracking];
}

- (BOOL)isTracking:(ALDevice *)d {
	if (self.mode != ALStatusBarModeTracking) return NO;
	for (ALDevice *ap in (d.children.count ? d.children : @[d]))
		if ([self.trackedIDs containsObject:ap.identifier]) return YES;
	return NO;
}

#pragma mark - Feeds

- (void)noteDevice:(ALDevice *)d {
	if (self.mode != ALStatusBarModeTracking || ![self.trackedIDs containsObject:d.identifier]) return;
	if (d.rssi >= 0) return; // classic BT has no RSSI
	self.trackReadings[d.identifier] = @[@(d.rssi), [NSDate date]];
}

- (void)noteCountsWiFi:(NSUInteger)wifi ble:(NSUInteger)ble classic:(NSUInteger)classic {
	self.wifiCount = wifi; self.bleCount = ble; self.classicCount = classic;
	self.countsAt = [NSDate date];
}

- (void)showTransient:(NSString *)text duration:(NSTimeInterval)seconds {
	if (self.mode == ALStatusBarModeOff) return;
	self.transient = text;
	self.transientUntil = [NSDate dateWithTimeIntervalSinceNow:seconds];
	[self tick];
}

#pragma mark - Rendering

static NSString *shorten(NSString *s, NSUInteger max) {
	if (s.length <= max) return s ?: @"";
	return [[s substringToIndex:max - 1] stringByAppendingString:@"…"];
}

static NSString *bars(NSInteger rssi) {
	if (rssi >= -55) return @"▂▄▆█";
	if (rssi >= -65) return @"▂▄▆·";
	if (rssi >= -75) return @"▂▄··";
	if (rssi >= -85) return @"▂···";
	return @"····";
}

- (NSString *)render {
	if (self.transient && self.transientUntil.timeIntervalSinceNow > 0) return self.transient;
	self.transient = nil;

	switch (self.mode) {
		case ALStatusBarModeOff:
			return nil;
		case ALStatusBarModeCounts:
			if (!self.countsAt || -self.countsAt.timeIntervalSinceNow > kCountsStale) return @"Scan paused";
			return [NSString stringWithFormat:@"W%lu L%lu C%lu", (unsigned long)self.wifiCount,
					(unsigned long)self.bleCount, (unsigned long)self.classicCount];
		case ALStatusBarModeConnectedWiFi: {
			ALDevice *c = [[ALWiFiScanner shared] currentNetwork];
			if (!c) return @"No Wi-Fi";
			return c.rssi < 0 ? [NSString stringWithFormat:@"%@ %ld", shorten(c.displayName, 12), (long)c.rssi]
							  : shorten(c.displayName, 16);
		}
		case ALStatusBarModeTracking: {
			// Strongest fresh reading across the tracked APs / device.
			NSInteger best = 0; NSDate *latest = nil;
			for (NSArray *r in self.trackReadings.allValues) {
				NSDate *at = r[1];
				if (!latest || [at compare:latest] == NSOrderedDescending) latest = at;
				if (-at.timeIntervalSinceNow <= kTrackFresh && (best == 0 || [r[0] integerValue] > best))
					best = [r[0] integerValue];
			}
			NSString *name = shorten(self.trackedName, kMaxNameLength);
			NSTimeInterval since = latest ? -latest.timeIntervalSinceNow : -self.trackStarted.timeIntervalSinceNow;
			if (best < 0) return [NSString stringWithFormat:@"%@ %ld %@", bars(best), (long)best, name];
			if (since > kTrackLost) return [NSString stringWithFormat:@"···· lost %@", name];
			return [NSString stringWithFormat:@"···· ?? %@", name]; // between readings
		}
	}
	return nil;
}

- (void)tick {
	if (self.mode == ALStatusBarModeOff) return;
	NSString *text = [self render];
	if (!text || [text isEqualToString:self.lastWritten]) return;
	self.lastWritten = text;

	NSMutableDictionary *prefs = [self.originalPrefs mutableCopy] ?: [NSMutableDictionary dictionary];
	[prefs removeObjectsForKeys:@[@"CarrierText", @"LoopTexts", @"LoopDelay"]];
	prefs[@"CarrierText"] = text;
	[self writePrefs:prefs];
}

#pragma mark - Writing

- (void)writePrefs:(NSDictionary *)prefs {
	NSError *err = nil;
	NSData *data = [NSPropertyListSerialization dataWithPropertyList:prefs ?: @{}
															  format:NSPropertyListBinaryFormat_v1_0
															 options:0 error:&err];
	if (data && [data writeToFile:kPrefsPath options:NSDataWritingAtomic error:&err]) {
		notify_post(kChangedNotification);
		return;
	}
	ALLog(@"statusbar: prefs write failed (%@); using the CLI", err.localizedDescription);
	[self runCLIForPrefs:prefs];
}

// Fallback: express the same setting as a carriertext command.
- (void)runCLIForPrefs:(NSDictionary *)prefs {
	NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObject:@"carriertext"];
	if ([prefs[@"CarrierText"] isKindOfClass:[NSString class]]) {
		[args addObjectsFromArray:@[@"set", prefs[@"CarrierText"]]];
	} else if ([prefs[@"LoopTexts"] isKindOfClass:[NSArray class]]) {
		[args addObjectsFromArray:@[@"loop", [prefs[@"LoopDelay"] description] ?: @"2"]];
		[args addObjectsFromArray:prefs[@"LoopTexts"]];
	} else {
		[args addObject:@"reset"];
	}

	char **argv = calloc(args.count + 1, sizeof(char *));
	for (NSUInteger i = 0; i < args.count; i++) argv[i] = (char *)args[i].UTF8String;
	pid_t pid;
	int rc = posix_spawn(&pid, kCLIPath.fileSystemRepresentation, NULL, NULL, argv, environ);
	free(argv);
	if (rc != 0) { ALLog(@"statusbar: spawning carriertext failed: %s", strerror(rc)); return; }
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ waitpid(pid, NULL, 0); });
}

@end
