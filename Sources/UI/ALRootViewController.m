//
//  ALRootViewController.m — AirLogger
//
//  "Current" tab. Owns the scanners, ingests live sightings into an in-memory
//  store (and the database), and shows one radio type at a time (Wi-Fi / BLE /
//  Classic picker, with per-type counts) with SSID grouping. The Live (last
//  30s) / Session toggle sits in the nav bar; a compact header card shows the
//  connected Wi-Fi network and runs speed tests on it. The type picker (plus a
//  small total / scan-state line) floats over the list so it stays reachable.
//

#import "ALRootViewController.h"
#import "ALDetailViewController.h"
#import "ALDeviceCell.h"
#import "ALDevice.h"
#import "ALWiFiScanner.h"
#import "ALBluetoothScanner.h"
#import "ALDatabase.h"
#import "ALLocationProvider.h"
#import "ALSpeedTest.h"
#import "ALWiFiJoin.h"
#import "ALStatusBar.h"

// "Live" mode shows only devices seen within this window (longer than the ~6s
// Wi-Fi scan cycle so present APs don't flicker out); "Session" shows all found.
static const NSTimeInterval kLiveWindow = 30.0;

// Type picker segments, in order. Segment index == ALDeviceType, which is also
// how self.sections is indexed (wifi=0, ble=1, classic=2).
static NSString *const kTypeSegmentTitles[] = { @"Wi-Fi", @"BLE", @"Classic" };
static const NSInteger kTypeSegmentCount = 3;

static const CGFloat kHeaderHeight = 88;  // connected Wi-Fi card
static const CGFloat kTypeBarHeight = 66; // type picker + count line
static const NSTimeInterval kConnectionRefresh = 5.0;

@interface ALRootViewController ()
@property (nonatomic, strong) ALWiFiScanner *wifi;
@property (nonatomic, strong) ALBluetoothScanner *bt;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ALDevice *> *store; // key: "type:id"
@property (nonatomic, strong) NSArray<NSArray<ALDevice *> *> *sections; // sorted snapshot
@property (nonatomic, strong) NSTimer *uiTimer;
@property (nonatomic) BOOL scanning;

// header + floating type bar
@property (nonatomic, strong) UIView *summaryHeader;
@property (nonatomic, strong) UISegmentedControl *modeControl; // nav bar title view
@property (nonatomic) NSInteger mode; // 0 = Live (recent), 1 = Session (all found)
@property (nonatomic, strong) UIView *typeBar; // floats over the table, pinned under the nav bar
@property (nonatomic, strong) UISegmentedControl *typeControl;
@property (nonatomic, strong) UILabel *countLabel;      // "47 nearby now · Scanning"
@property (nonatomic, strong) UILabel *scanStatusLabel; // shown type's scanner status
@property (nonatomic) ALDeviceType shownType; // the one type listed below

// connected Wi-Fi card
@property (nonatomic, strong) ALDevice *connected; // nil when not on Wi-Fi
@property (nonatomic, strong) UILabel *connSSIDLabel;
@property (nonatomic, strong) UILabel *connDetailLabel;
@property (nonatomic, strong) UILabel *connSpeedLabel;
@property (nonatomic, strong) UIButton *speedButton;
@property (nonatomic, strong) NSTimer *connTimer;
@property (nonatomic, strong) ALSpeedTest *speedTest;
@property (nonatomic) BOOL swipeOpen; // a row's swipe actions are showing
@end

@implementation ALRootViewController

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
		_store = [NSMutableDictionary dictionary];
		_sections = @[@[], @[], @[]];
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	// No title: the tab bar already says "Current"; the Live/Session toggle takes its place.
	self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
	_modeControl = [[UISegmentedControl alloc] initWithItems:@[@"Live", @"Session"]];
	_modeControl.selectedSegmentIndex = 0;
	_modeControl.frame = CGRectMake(0, 0, 180, 30);
	[_modeControl addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
	self.navigationItem.titleView = _modeControl;
	self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
	self.tableView.separatorInset = UIEdgeInsetsMake(0, 62, 0, 0);
	[self.tableView registerClass:[ALDeviceCell class] forCellReuseIdentifier:@"dev"];

	// Start with the Pause icon (or Play, depending on initial state)
	UIImage *pauseImage = [UIImage systemImageNamed:@"pause.fill"];
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:pauseImage
		style:UIBarButtonItemStylePlain
		target:self
		action:@selector(toggleScan)];


	// Status bar (CarrierText tweak) mode picker.
	self.navigationItem.leftBarButtonItem =
		[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"text.bubble"] menu:[self statusBarMenu]];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(statusBarModeChanged)
												 name:ALStatusBarModeChangedNotification object:nil];

	// on boot start location service but do not start scan yet
	[self buildSummaryHeader];
	[[ALLocationProvider shared] start];

	// Create the Wi-Fi scanner up front (init doesn't scan) so the connected
	// network can be shown while paused.
	__weak typeof(self) weakSelf = self;
	self.wifi = [ALWiFiScanner shared];
	self.wifi.onDevice = ^(ALDevice *d) { [weakSelf ingest:d]; };

	[self updateSummary];
	[self refreshConnection];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshConnection)
												 name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self refreshConnection];
	self.connTimer = [NSTimer scheduledTimerWithTimeInterval:kConnectionRefresh target:self
													selector:@selector(refreshConnection) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	[self.connTimer invalidate]; self.connTimer = nil;
}

- (void)viewDidLayoutSubviews {
	[super viewDidLayoutSubviews];
	if (self.summaryHeader) {
		CGFloat h = kHeaderHeight;
		if (self.summaryHeader.frame.size.width != self.tableView.bounds.size.width ||
			self.summaryHeader.frame.size.height != h) {
			self.summaryHeader.frame = CGRectMake(0, 0, self.tableView.bounds.size.width, h);
			self.tableView.tableHeaderView = self.summaryHeader;
		}
	}
	[self layoutTypeBar];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
	[self layoutTypeBar];
}

#pragma mark - Header + type bar

- (void)buildSummaryHeader {
	UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, kHeaderHeight)];
	UIView *conn = [self buildConnectionCard];
	[header addSubview:conn];
	[NSLayoutConstraint activateConstraints:@[
		[conn.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
		[conn.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
		[conn.topAnchor constraintEqualToAnchor:header.topAnchor constant:4],
		[conn.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-8],
	]];
	self.summaryHeader = header;
	self.tableView.tableHeaderView = header;
	[self buildTypeBar];
}

// Inset-grouped section headers don't stick, so the type bar is a subview of the
// table positioned over the (empty, same-height) section header and pinned under
// the nav bar once the header scrolls past it. See layoutTypeBar.
- (void)buildTypeBar {
	UIView *bar = [[UIView alloc] init];
	bar.backgroundColor = [UIColor systemGroupedBackgroundColor];

	NSMutableArray *typeTitles = [NSMutableArray array];
	for (NSInteger i = 0; i < kTypeSegmentCount; i++) [typeTitles addObject:kTypeSegmentTitles[i]];
	_typeControl = [[UISegmentedControl alloc] initWithItems:typeTitles];
	_typeControl.selectedSegmentIndex = ALDeviceTypeWiFi;
	[_typeControl addTarget:self action:@selector(typeChanged:) forControlEvents:UIControlEventValueChanged];
	_typeControl.translatesAutoresizingMaskIntoConstraints = NO;
	[bar addSubview:_typeControl];

	_countLabel = [[UILabel alloc] init];
	_countLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
	_countLabel.textColor = [UIColor secondaryLabelColor];
	_countLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[_countLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
	[bar addSubview:_countLabel];

	_scanStatusLabel = [[UILabel alloc] init];
	_scanStatusLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
	_scanStatusLabel.textColor = [UIColor tertiaryLabelColor];
	_scanStatusLabel.textAlignment = NSTextAlignmentRight;
	_scanStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[_scanStatusLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
	[bar addSubview:_scanStatusLabel];

	[NSLayoutConstraint activateConstraints:@[
		[_typeControl.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:16],
		[_typeControl.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-16],
		[_typeControl.topAnchor constraintEqualToAnchor:bar.topAnchor constant:6],
		[_typeControl.heightAnchor constraintEqualToConstant:30],

		[_countLabel.leadingAnchor constraintEqualToAnchor:_typeControl.leadingAnchor constant:4],
		[_countLabel.topAnchor constraintEqualToAnchor:_typeControl.bottomAnchor constant:7],
		[_scanStatusLabel.trailingAnchor constraintEqualToAnchor:_typeControl.trailingAnchor constant:-4],
		[_scanStatusLabel.firstBaselineAnchor constraintEqualToAnchor:_countLabel.firstBaselineAnchor],
		[_scanStatusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_countLabel.trailingAnchor constant:8],
	]];

	self.typeBar = bar;
	[self.tableView addSubview:bar];
	[self layoutTypeBar];
}

- (void)layoutTypeBar {
	if (!self.typeBar) return;
	UITableView *tv = self.tableView;
	CGFloat natural = [tv rectForHeaderInSection:0].origin.y;
	CGFloat pinned = tv.contentOffset.y + tv.adjustedContentInset.top;
	self.typeBar.frame = CGRectMake(0, MAX(natural, pinned), tv.bounds.size.width, kTypeBarHeight);
	[tv bringSubviewToFront:self.typeBar]; // cells get re-added on reload
}

#pragma mark - Connected Wi-Fi

- (UIView *)buildConnectionCard {
	UIView *card = [[UIView alloc] init];
	card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
	card.layer.cornerRadius = 14;
	card.layer.cornerCurve = kCACornerCurveContinuous;
	card.translatesAutoresizingMaskIntoConstraints = NO;
	[card addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showConnectedDetail)]];

	UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"wifi"]];
	icon.tintColor = [ALDeviceCell colorForType:ALDeviceTypeWiFi];
	icon.contentMode = UIViewContentModeScaleAspectFit;
	icon.translatesAutoresizingMaskIntoConstraints = NO;
	[card addSubview:icon];

	_connSSIDLabel = [[UILabel alloc] init];
	_connSSIDLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
	_connSSIDLabel.textColor = [UIColor labelColor];
	_connSSIDLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[card addSubview:_connSSIDLabel];

	_connDetailLabel = [[UILabel alloc] init];
	_connDetailLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
	_connDetailLabel.textColor = [UIColor secondaryLabelColor];
	_connDetailLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[card addSubview:_connDetailLabel];

	_connSpeedLabel = [[UILabel alloc] init];
	_connSpeedLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
	_connSpeedLabel.textColor = [UIColor labelColor];
	_connSpeedLabel.adjustsFontSizeToFitWidth = YES;
	_connSpeedLabel.minimumScaleFactor = 0.8;
	_connSpeedLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[card addSubview:_connSpeedLabel];

	_speedButton = [UIButton buttonWithType:UIButtonTypeSystem];
	UIImageSymbolConfiguration *sym = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
	[_speedButton setImage:[UIImage systemImageNamed:@"speedometer" withConfiguration:sym] forState:UIControlStateNormal];
	_speedButton.tintColor = [UIColor whiteColor];
	_speedButton.backgroundColor = [UIColor systemBlueColor];
	_speedButton.layer.cornerRadius = 18;
	_speedButton.accessibilityLabel = @"Speed Test";
	[_speedButton addTarget:self action:@selector(runSpeedTest) forControlEvents:UIControlEventTouchUpInside];
	_speedButton.translatesAutoresizingMaskIntoConstraints = NO;
	[card addSubview:_speedButton];

	[NSLayoutConstraint activateConstraints:@[
		[icon.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
		[icon.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
		[icon.widthAnchor constraintEqualToConstant:24],
		[icon.heightAnchor constraintEqualToConstant:24],

		[_speedButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
		[_speedButton.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
		[_speedButton.widthAnchor constraintEqualToConstant:36],
		[_speedButton.heightAnchor constraintEqualToConstant:36],

		[_connSSIDLabel.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:12],
		[_connSSIDLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:10],
		[_connSSIDLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_speedButton.leadingAnchor constant:-10],

		[_connDetailLabel.leadingAnchor constraintEqualToAnchor:_connSSIDLabel.leadingAnchor],
		[_connDetailLabel.topAnchor constraintEqualToAnchor:_connSSIDLabel.bottomAnchor constant:1],
		[_connDetailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_speedButton.leadingAnchor constant:-10],

		[_connSpeedLabel.leadingAnchor constraintEqualToAnchor:_connSSIDLabel.leadingAnchor],
		[_connSpeedLabel.topAnchor constraintEqualToAnchor:_connDetailLabel.bottomAnchor constant:2],
		[_connSpeedLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_speedButton.leadingAnchor constant:-10],
	]];
	return card;
}

- (void)refreshConnection {
	if (!self.speedTest.running) self.connected = [self.wifi currentNetwork];
	ALDevice *c = self.connected;

	self.connSSIDLabel.text = c ? c.displayName : @"Not connected";
	NSMutableArray *parts = [NSMutableArray array];
	if (c) {
		if (c.info[@"Band"]) [parts addObject:c.info[@"Band"]];
		if (c.info[@"Channel"]) [parts addObject:[@"ch " stringByAppendingString:c.info[@"Channel"]]];
		if (c.rssi < 0) [parts addObject:[NSString stringWithFormat:@"%ld dBm", (long)c.rssi]];
	}
	NSString *radio = [parts componentsJoinedByString:@" · "];
	// BSSID lives on the detail page (tap the card); keep this to one line.
	self.connDetailLabel.text = c ? (radio.length ? radio : c.identifier) : @"Join a network to run a speed test";

	if (self.speedTest.running) return; // progress owns the speed label and button
	self.speedButton.enabled = (c != nil);
	self.speedButton.alpha = c ? 1.0 : 0.4;
	[self showLastSpeedTest];
}

- (void)showLastSpeedTest {
	NSDictionary *t = self.connected ? [[ALDatabase shared] speedTestForIdentifier:self.connected.identifier] : nil;
	if (!t) {
		self.connSpeedLabel.textColor = [UIColor tertiaryLabelColor];
		self.connSpeedLabel.text = self.connected ? @"No speed test yet" : @"";
		return;
	}
	NSRelativeDateTimeFormatter *rel = [[NSRelativeDateTimeFormatter alloc] init];
	rel.unitsStyle = NSRelativeDateTimeFormatterUnitsStyleShort;
	NSString *ago = [rel localizedStringForDate:[NSDate dateWithTimeIntervalSince1970:[t[@"ts"] doubleValue]]
								 relativeToDate:[NSDate date]];
	self.connSpeedLabel.textColor = [UIColor labelColor];
	self.connSpeedLabel.text = [NSString stringWithFormat:@"↓ %.1f  ↑ %.1f Mbps · %@",
								[t[@"down"] doubleValue], [t[@"up"] doubleValue], ago];
}

- (void)showConnectedDetail {
	if (!self.connected) return;
	ALDetailViewController *vc = [[ALDetailViewController alloc] initWithDevice:self.connected];
	[self.navigationController pushViewController:vc animated:YES];
}

- (void)runSpeedTest {
	ALDevice *ap = [self.wifi currentNetwork];
	if (!ap || self.speedTest.running) return;
	self.connected = ap;

	// Background Wi-Fi scans go off-channel and would drag throughput down, so
	// hold them for the duration of the test.
	[self.wifi stop];

	self.speedButton.enabled = NO;
	self.speedButton.alpha = 0.5;
	self.connSpeedLabel.textColor = [UIColor secondaryLabelColor];
	self.connSpeedLabel.text = @"Starting…";

	if (!self.speedTest) self.speedTest = [[ALSpeedTest alloc] init];
	__weak typeof(self) weakSelf = self;
	self.speedTest.onProgress = ^(ALSpeedTestPhase phase, double mbps) {
		weakSelf.connSpeedLabel.text = [NSString stringWithFormat:@"Testing %@…  %.1f Mbps",
										phase == ALSpeedTestPhaseDownload ? @"download" : @"upload", mbps];
		[[ALStatusBar shared] showTransient:[NSString stringWithFormat:@"%@ %.0f Mbps",
											 phase == ALSpeedTestPhaseDownload ? @"↓" : @"↑", mbps] duration:3];
	};
	self.speedTest.onComplete = ^(double down, double up, NSError *error) {
		typeof(self) strongSelf = weakSelf;
		if (!strongSelf) return;
		if (strongSelf.scanning) [strongSelf.wifi start];
		if (error) {
			strongSelf.connSpeedLabel.textColor = [UIColor systemRedColor];
			strongSelf.connSpeedLabel.text = [@"Speed test failed: " stringByAppendingString:error.localizedDescription];
		} else {
			[[ALStatusBar shared] showTransient:[NSString stringWithFormat:@"↓%.0f ↑%.0f Mbps", down, up] duration:15];
			[[ALDatabase shared] recordSpeedTestForIdentifier:ap.identifier ssid:ap.name down:down up:up];
			// Log the AP as a sighting too, so it's in All Devices even if it hasn't
			// been scanned yet. Skip if the RSSI is missing: a 0 dBm row would look
			// like the strongest reading ever and skew the map estimate.
			if (ap.rssi < 0) [[ALDatabase shared] recordDevice:ap location:[ALLocationProvider shared].currentLocation];
		}
		strongSelf.speedButton.enabled = YES;
		strongSelf.speedButton.alpha = 1.0;
		if (!error) [strongSelf refreshConnection];
	};
	[self.speedTest start];
}

#pragma mark - Status bar text

- (UIMenu *)statusBarMenu {
	ALStatusBar *sb = [ALStatusBar shared];
	NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
	NSArray *titles = @[@"Off", @"Nearby Counts", @"Connected Wi-Fi"];
	NSArray *symbols = @[@"xmark", @"number", @"wifi"];
	for (NSInteger m = ALStatusBarModeOff; m <= ALStatusBarModeConnectedWiFi; m++) {
		UIAction *a = [UIAction actionWithTitle:titles[m] image:[UIImage systemImageNamed:symbols[m]]
									 identifier:nil handler:^(__kindof UIAction *action) {
			[[ALStatusBar shared] setMode:(ALStatusBarMode)m];
		}];
		a.state = (sb.mode == m) ? UIMenuElementStateOn : UIMenuElementStateOff;
		[items addObject:a];
	}
	if (sb.mode == ALStatusBarModeTracking) {
		UIAction *t = [UIAction actionWithTitle:[NSString stringWithFormat:@"Tracking %@", sb.trackedName]
										  image:[UIImage systemImageNamed:@"scope"] identifier:nil
										handler:^(__kindof UIAction *action) {}];
		t.state = UIMenuElementStateOn;
		[items addObject:t];
	}
	return [UIMenu menuWithTitle:@"Status Bar Text (off clears it)" children:items];
}

- (void)statusBarModeChanged {
	UIBarButtonItem *b = self.navigationItem.leftBarButtonItem;
	b.menu = [self statusBarMenu];
	b.image = [UIImage systemImageNamed:([ALStatusBar shared].mode == ALStatusBarModeOff
										 ? @"text.bubble" : @"text.bubble.fill")];
}

- (void)modeChanged:(UISegmentedControl *)sender {
	self.mode = sender.selectedSegmentIndex;
	[self rebuildAndReload];
}

- (void)typeChanged:(UISegmentedControl *)sender {
	self.shownType = (ALDeviceType)sender.selectedSegmentIndex;
	[self rebuildAndReload];
}

- (NSArray<ALDevice *> *)shownItems {
	return self.sections[self.shownType];
}

- (void)updateSummary {
	// Counts reflect the current mode (Live/Session): total across every type, and
	// each type's own count on its picker segment.
	NSUInteger total = 0;
	for (NSInteger i = 0; i < kTypeSegmentCount; i++) {
		NSUInteger n = self.sections[i].count;
		total += n;
		NSString *title = n ? [NSString stringWithFormat:@"%@ %lu", kTypeSegmentTitles[i], (unsigned long)n]
							: kTypeSegmentTitles[i];
		if (![[self.typeControl titleForSegmentAtIndex:i] isEqualToString:title])
			[self.typeControl setTitle:title forSegmentAtIndex:i];
	}
	NSString *scope = (self.mode == 0) ? @"nearby now" : @"found this session";
	self.countLabel.text = [NSString stringWithFormat:@"%lu %@ · %@", (unsigned long)total, scope,
							self.scanning ? @"Scanning" : @"Paused"];
	self.scanStatusLabel.text = [self statusForSection:self.shownType];
}

#pragma mark - Scanning

- (void)toggleScan {
	if (self.scanning) [self stopScan]; else [self startScan];
}

- (void)startScan {
	self.scanning = YES;
	self.navigationItem.rightBarButtonItem.image = [UIImage systemImageNamed:@"play.fill"];
	

	__weak typeof(self) weakSelf = self;
	void (^sink)(ALDevice *) = ^(ALDevice *d) { [weakSelf ingest:d]; };

	// Create the scanners once and reuse them; tearing them down while an async
	// Wi-Fi scan is in flight causes a use-after-free crash.
	if (!self.wifi) { self.wifi = [ALWiFiScanner shared]; self.wifi.onDevice = sink; }
	if (!self.bt)   { self.bt = [[ALBluetoothScanner alloc] init]; self.bt.onDevice = sink; }
	if (!self.speedTest.running) [self.wifi start]; // else resumed when the test finishes
	[self.bt start];

	self.uiTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
													target:self
												  selector:@selector(rebuildAndReload)
												  userInfo:nil
												   repeats:YES];
	[self updateSummary];
}

- (void)stopScan {
	self.scanning = NO;
	self.navigationItem.rightBarButtonItem.image = [UIImage systemImageNamed:@"pause.fill"];
	[self.wifi stop];   // keep the objects alive; just stop scanning
	[self.bt stop];
	[self.uiTimer invalidate]; self.uiTimer = nil;
	[self updateSummary];
}

- (void)ingest:(ALDevice *)d {
	NSString *key = [NSString stringWithFormat:@"%ld:%@", (long)d.type, d.identifier];
	ALDevice *existing = self.store[key];
	if (existing) {
		existing.rssi = d.rssi;
		existing.lastSeen = [NSDate date];
		existing.sightings += 1;
		if (d.name.length) existing.name = d.name;
		[existing.info addEntriesFromDictionary:d.info];
	} else {
		d.sightings = 1;
		self.store[key] = d;
	}
	[[ALDatabase shared] recordDevice:(existing ?: d) location:[ALLocationProvider shared].currentLocation];
	[[ALStatusBar shared] noteDevice:d];
}

- (void)rebuildAndReload {
	// reloadData would snap an open swipe action shut before it can be tapped.
	if (self.swipeOpen) return;
	NSTimeInterval now = [NSDate date].timeIntervalSince1970;
	NSMutableArray *wifi = [NSMutableArray array];
	NSMutableArray *ble = [NSMutableArray array];
	NSMutableArray *classic = [NSMutableArray array];
	for (ALDevice *d in self.store.allValues) {
		// Live mode: only devices seen within the recent window.
		if (self.mode == 0 && (now - d.lastSeen.timeIntervalSince1970) > kLiveWindow) continue;
		if (d.type == ALDeviceTypeWiFi) [wifi addObject:d];
		else if (d.type == ALDeviceTypeBLE) [ble addObject:d];
		else [classic addObject:d];
	}
	NSComparator byRSSI = ^NSComparisonResult(ALDevice *a, ALDevice *b) {
		if (a.rssi == b.rssi) return NSOrderedSame;
		return (a.rssi > b.rssi) ? NSOrderedAscending : NSOrderedDescending; // strongest first
	};

	// Collapse Wi-Fi networks that share an SSID into one row, keeping each
	// access point (BSSID) as a child. Hidden networks (no SSID) stay separate.
	NSMutableDictionary<NSString *, NSMutableArray<ALDevice *> *> *bySSID = [NSMutableDictionary dictionary];
	NSMutableArray<ALDevice *> *wifiRows = [NSMutableArray array];
	for (ALDevice *d in wifi) {
		if (d.name.length) {
			NSMutableArray *arr = bySSID[d.name];
			if (!arr) { arr = [NSMutableArray array]; bySSID[d.name] = arr; }
			[arr addObject:d];
		} else {
			[wifiRows addObject:d]; // hidden network — leave individual
		}
	}
	for (NSString *ssid in bySSID) {
		NSArray<ALDevice *> *members = [bySSID[ssid] sortedArrayUsingComparator:byRSSI];
		if (members.count == 1) { [wifiRows addObject:members[0]]; continue; }

		ALDevice *group = [[ALDevice alloc] init];
		group.type = ALDeviceTypeWiFi;
		group.name = ssid;
		group.rssi = members.firstObject.rssi; // strongest (members are sorted)
		group.identifier = [NSString stringWithFormat:@"%lu access points", (unsigned long)members.count];
		group.children = members;
		NSUInteger total = 0;
		NSMutableOrderedSet *channels = [NSMutableOrderedSet orderedSet];
		for (ALDevice *m in members) {
			total += m.sightings;
			if (m.info[@"Channel"]) [channels addObject:m.info[@"Channel"]];
		}
		group.sightings = total;
		group.info[@"Access Points"] = [NSString stringWithFormat:@"%lu", (unsigned long)members.count];
		if (channels.count) group.info[@"Channels"] = [channels.array componentsJoinedByString:@", "];
		// A mesh's APs share vendor / model / standard; take each from the strongest
		// AP that reports it.
		for (NSString *k in @[@"Manufacturer", @"Wi-Fi Generation", @"Device Kind",
							  @"WPS Manufacturer", @"WPS Model Name", @"WPS Model Number"]) {
			for (ALDevice *m in members) {
				if (m.info[k]) { group.info[k] = m.info[k]; break; }
			}
		}
		[wifiRows addObject:group];
	}
	[wifiRows sortUsingComparator:byRSSI];

	[ble sortUsingComparator:byRSSI];
	[classic sortUsingComparator:byRSSI];
	self.sections = @[wifiRows, ble, classic];
	[[ALStatusBar shared] noteCountsWiFi:wifiRows.count ble:ble.count classic:classic.count];
	[self updateSummary];
	[self.tableView reloadData];
	[self layoutTypeBar];
}

#pragma mark - Section metadata

- (NSString *)statusForSection:(NSInteger)s {
	switch (s) {
		case ALDeviceTypeWiFi:      return self.wifi.status ?: @"—";
		case ALDeviceTypeBLE:       return self.bt.bleStatus ?: @"—";
		case ALDeviceTypeClassicBT: return self.bt.classicStatus ?: @"—";
	}
	return @"";
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	NSUInteger n = [self shownItems].count;
	return n == 0 ? 1 : n; // one placeholder row when empty
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
	NSArray *items = [self shownItems];
	if (items.count == 0) {
		UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
		cell.textLabel.text = self.scanning ? @"Scanning…" : @"No devices";
		cell.textLabel.font = [UIFont systemFontOfSize:15];
		cell.textLabel.textColor = [UIColor tertiaryLabelColor];
		cell.textLabel.textAlignment = NSTextAlignmentCenter;
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
		return cell;
	}
	ALDeviceCell *cell = [tableView dequeueReusableCellWithIdentifier:@"dev" forIndexPath:ip];
	[cell configureWithDevice:items[ip.row]];
	return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)ip {
	return UITableViewAutomaticDimension;
}

- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)ip {
	return 66;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
	[tableView deselectRowAtIndexPath:ip animated:YES];
	NSArray *items = [self shownItems];
	if (items.count == 0) return;
	ALDevice *d = items[ip.row];
	ALDetailViewController *vc = [[ALDetailViewController alloc] initWithDevice:d];
	[self.navigationController pushViewController:vc animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
	trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
	NSArray *items = [self shownItems];
	if (items.count == 0) return nil;
	ALDevice *d = items[ip.row];
	if (![ALWiFiJoin canJoin:d] || [d.name isEqualToString:self.connected.name]) return nil;
	__weak typeof(self) weakSelf = self;
	UIContextualAction *join = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Join"
		handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
			[ALWiFiJoin join:d from:weakSelf];
			done(YES);
		}];
	join.backgroundColor = [UIColor systemGreenColor];
	join.image = [UIImage systemImageNamed:@"wifi"];
	UISwipeActionsConfiguration *cfg = [UISwipeActionsConfiguration configurationWithActions:@[join]];
	cfg.performsFirstActionWithFullSwipe = NO;
	return cfg;
}

- (void)tableView:(UITableView *)tableView willBeginEditingRowAtIndexPath:(NSIndexPath *)ip {
	self.swipeOpen = YES;
}

- (void)tableView:(UITableView *)tableView didEndEditingRowAtIndexPath:(NSIndexPath *)ip {
	self.swipeOpen = NO;
	[self rebuildAndReload];
}

#pragma mark - Section headers

// Spacer the floating type bar sits over (see buildTypeBar).
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section { return kTypeBarHeight; }

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
	return [[UIView alloc] init];
}

@end
