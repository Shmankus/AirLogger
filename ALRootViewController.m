//
//  ALRootViewController.m — AirLogger
//
//  "Current" tab. Owns the scanners, ingests live sightings into an in-memory
//  store (and the database), and shows them grouped by radio type with SSID
//  grouping. Has a Live (last 30s) / Session toggle; BLE is hidden. A second
//  header card shows the connected Wi-Fi network and runs speed tests on it.
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

// "Live" mode shows only devices seen within this window (longer than the ~6s
// Wi-Fi scan cycle so present APs don't flicker out); "Session" shows all found.
static const NSTimeInterval kLiveWindow = 30.0;

// Sections shown in the Current list. BLE is hidden because CoreBluetooth scanning
// is blocked for this sideloaded app, so it never populates. These index into
// self.sections, which is stored by ALDeviceType (wifi=0, ble=1, classic=2).
static const ALDeviceType kDisplaySections[] = { ALDeviceTypeWiFi, ALDeviceTypeClassicBT };
static const NSInteger kDisplaySectionCount = 2;

static const CGFloat kHeaderHeight = 252; // summary card + connected Wi-Fi card
static const NSTimeInterval kConnectionRefresh = 5.0;

@interface ALRootViewController ()
@property (nonatomic, strong) ALWiFiScanner *wifi;
@property (nonatomic, strong) ALBluetoothScanner *bt;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ALDevice *> *store; // key: "type:id"
@property (nonatomic, strong) NSArray<NSArray<ALDevice *> *> *sections; // sorted snapshot
@property (nonatomic, strong) NSTimer *uiTimer;
@property (nonatomic) BOOL scanning;

// summary header
@property (nonatomic, strong) UIView *summaryHeader;
@property (nonatomic, strong) UILabel *totalLabel;
@property (nonatomic, strong) UILabel *totalCaption;
@property (nonatomic, strong) UIView *statusPill;
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UILabel *statusPillLabel;
@property (nonatomic, strong) UISegmentedControl *modeControl;
@property (nonatomic) NSInteger mode; // 0 = Live (recent), 1 = Session (all found)

// connected Wi-Fi card
@property (nonatomic, strong) ALDevice *connected; // nil when not on Wi-Fi
@property (nonatomic, strong) UILabel *connSSIDLabel;
@property (nonatomic, strong) UILabel *connDetailLabel;
@property (nonatomic, strong) UILabel *connSpeedLabel;
@property (nonatomic, strong) UIButton *speedButton;
@property (nonatomic, strong) NSTimer *connTimer;
@property (nonatomic, strong) ALSpeedTest *speedTest;
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
	self.title = @"Current";
	self.navigationController.navigationBar.prefersLargeTitles = YES;
	self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
	self.tableView.separatorInset = UIEdgeInsetsMake(0, 62, 0, 0);
	[self.tableView registerClass:[ALDeviceCell class] forCellReuseIdentifier:@"dev"];

	// Start with the Pause icon (or Play, depending on initial state)
	UIImage *pauseImage = [UIImage systemImageNamed:@"pause.fill"];
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:pauseImage
		style:UIBarButtonItemStylePlain
		target:self
		action:@selector(toggleScan)];


	// on boot start location service but do not start scan yet
	[self buildSummaryHeader];
	[[ALLocationProvider shared] start];

	// Create the Wi-Fi scanner up front (init doesn't scan) so the connected
	// network can be shown while paused.
	__weak typeof(self) weakSelf = self;
	self.wifi = [[ALWiFiScanner alloc] init];
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
}

#pragma mark - Summary header

- (void)buildSummaryHeader {
	UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, kHeaderHeight)];

	UIView *card = [[UIView alloc] init];
	card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
	card.layer.cornerRadius = 14;
	card.layer.cornerCurve = kCACornerCurveContinuous;
	card.translatesAutoresizingMaskIntoConstraints = NO;
	[header addSubview:card];

	_totalLabel = [[UILabel alloc] init];
	_totalLabel.font = [UIFont monospacedDigitSystemFontOfSize:36 weight:UIFontWeightBold];
	_totalLabel.textColor = [UIColor labelColor];
	_totalLabel.text = @"0";
	_totalLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[card addSubview:_totalLabel];

	_totalCaption = [[UILabel alloc] init];
	_totalCaption.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
	_totalCaption.textColor = [UIColor secondaryLabelColor];
	_totalCaption.text = @"devices in range";
	_totalCaption.translatesAutoresizingMaskIntoConstraints = NO;
	[card addSubview:_totalCaption];

	_statusPill = [[UIView alloc] init];
	_statusPill.backgroundColor = [UIColor tertiarySystemGroupedBackgroundColor];
	_statusPill.layer.cornerRadius = 13;
	_statusPill.layer.cornerCurve = kCACornerCurveContinuous;
	_statusPill.translatesAutoresizingMaskIntoConstraints = NO;
	[card addSubview:_statusPill];

	_statusDot = [[UIView alloc] init];
	_statusDot.backgroundColor = [UIColor systemGreenColor];
	_statusDot.layer.cornerRadius = 4;
	_statusDot.translatesAutoresizingMaskIntoConstraints = NO;
	[_statusPill addSubview:_statusDot];

	_statusPillLabel = [[UILabel alloc] init];
	_statusPillLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
	_statusPillLabel.textColor = [UIColor labelColor];
	_statusPillLabel.text = @"Scanning";
	_statusPillLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[_statusPill addSubview:_statusPillLabel];

	_modeControl = [[UISegmentedControl alloc] initWithItems:@[@"Live", @"Session"]];
	_modeControl.selectedSegmentIndex = 0;
	[_modeControl addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
	_modeControl.translatesAutoresizingMaskIntoConstraints = NO;
	[card addSubview:_modeControl];

	[NSLayoutConstraint activateConstraints:@[
		[card.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
		[card.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
		[card.topAnchor constraintEqualToAnchor:header.topAnchor constant:4],
		[card.heightAnchor constraintEqualToConstant:120],

		[_totalLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
		[_totalLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
		[_totalCaption.leadingAnchor constraintEqualToAnchor:_totalLabel.leadingAnchor constant:2],
		[_totalCaption.topAnchor constraintEqualToAnchor:_totalLabel.bottomAnchor constant:0],

		[_statusPill.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
		[_statusPill.centerYAnchor constraintEqualToAnchor:_totalLabel.centerYAnchor],
		[_statusPill.heightAnchor constraintEqualToConstant:26],
		[_statusDot.leadingAnchor constraintEqualToAnchor:_statusPill.leadingAnchor constant:12],
		[_statusDot.centerYAnchor constraintEqualToAnchor:_statusPill.centerYAnchor],
		[_statusDot.widthAnchor constraintEqualToConstant:8],
		[_statusDot.heightAnchor constraintEqualToConstant:8],
		[_statusPillLabel.leadingAnchor constraintEqualToAnchor:_statusDot.trailingAnchor constant:7],
		[_statusPillLabel.trailingAnchor constraintEqualToAnchor:_statusPill.trailingAnchor constant:-12],
		[_statusPillLabel.centerYAnchor constraintEqualToAnchor:_statusPill.centerYAnchor],

		[_modeControl.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
		[_modeControl.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
		[_modeControl.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
		[_modeControl.heightAnchor constraintEqualToConstant:30],
	]];

	UIView *conn = [self buildConnectionCard];
	[header addSubview:conn];
	[NSLayoutConstraint activateConstraints:@[
		[conn.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
		[conn.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
		[conn.topAnchor constraintEqualToAnchor:card.bottomAnchor constant:10],
		[conn.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-8],
	]];

	self.summaryHeader = header;
	self.tableView.tableHeaderView = header;
}

#pragma mark - Connected Wi-Fi

- (UIView *)buildConnectionCard {
	UIView *card = [[UIView alloc] init];
	card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
	card.layer.cornerRadius = 14;
	card.layer.cornerCurve = kCACornerCurveContinuous;
	card.translatesAutoresizingMaskIntoConstraints = NO;
	[card addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showConnectedDetail)]];

	UILabel *caption = [[UILabel alloc] init];
	caption.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
	caption.textColor = [UIColor secondaryLabelColor];
	caption.text = @"CONNECTED WI-FI";
	caption.translatesAutoresizingMaskIntoConstraints = NO;
	[card addSubview:caption];

	_connSSIDLabel = [[UILabel alloc] init];
	_connSSIDLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
	_connSSIDLabel.textColor = [UIColor labelColor];
	_connSSIDLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[card addSubview:_connSSIDLabel];

	_connDetailLabel = [[UILabel alloc] init];
	_connDetailLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
	_connDetailLabel.textColor = [UIColor secondaryLabelColor];
	_connDetailLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[card addSubview:_connDetailLabel];

	_connSpeedLabel = [[UILabel alloc] init];
	_connSpeedLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];
	_connSpeedLabel.textColor = [UIColor labelColor];
	_connSpeedLabel.adjustsFontSizeToFitWidth = YES;
	_connSpeedLabel.minimumScaleFactor = 0.8;
	_connSpeedLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[card addSubview:_connSpeedLabel];

	_speedButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[_speedButton setTitle:@"Speed Test" forState:UIControlStateNormal];
	_speedButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
	[_speedButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	[_speedButton setTitleColor:[UIColor colorWithWhite:1 alpha:0.6] forState:UIControlStateDisabled];
	_speedButton.backgroundColor = [UIColor systemBlueColor];
	_speedButton.layer.cornerRadius = 15;
	_speedButton.layer.cornerCurve = kCACornerCurveContinuous;
	[_speedButton addTarget:self action:@selector(runSpeedTest) forControlEvents:UIControlEventTouchUpInside];
	_speedButton.translatesAutoresizingMaskIntoConstraints = NO;
	[card addSubview:_speedButton];

	[NSLayoutConstraint activateConstraints:@[
		[caption.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
		[caption.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],

		[_speedButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
		[_speedButton.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
		[_speedButton.heightAnchor constraintEqualToConstant:30],
		[_speedButton.widthAnchor constraintEqualToConstant:108],

		[_connSSIDLabel.leadingAnchor constraintEqualToAnchor:caption.leadingAnchor],
		[_connSSIDLabel.topAnchor constraintEqualToAnchor:caption.bottomAnchor constant:2],
		[_connSSIDLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_speedButton.leadingAnchor constant:-10],

		[_connDetailLabel.leadingAnchor constraintEqualToAnchor:caption.leadingAnchor],
		[_connDetailLabel.topAnchor constraintEqualToAnchor:_connSSIDLabel.bottomAnchor constant:2],
		[_connDetailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:card.trailingAnchor constant:-16],

		[_connSpeedLabel.leadingAnchor constraintEqualToAnchor:caption.leadingAnchor],
		[_connSpeedLabel.topAnchor constraintEqualToAnchor:_connDetailLabel.bottomAnchor constant:6],
		[_connSpeedLabel.trailingAnchor constraintLessThanOrEqualToAnchor:card.trailingAnchor constant:-16],
	]];
	return card;
}

- (void)refreshConnection {
	if (!self.speedTest.running) self.connected = [self.wifi currentNetwork];
	ALDevice *c = self.connected;

	self.connSSIDLabel.text = c ? c.displayName : @"Not connected";
	NSMutableArray *parts = [NSMutableArray array];
	if (c) {
		[parts addObject:c.identifier];
		if (c.info[@"Band"]) [parts addObject:c.info[@"Band"]];
		if (c.info[@"Channel"]) [parts addObject:[@"ch " stringByAppendingString:c.info[@"Channel"]]];
		if (c.rssi < 0) [parts addObject:[NSString stringWithFormat:@"%ld dBm", (long)c.rssi]];
	}
	self.connDetailLabel.text = parts.count ? [parts componentsJoinedByString:@" · "] : @"Join a Wi-Fi network to run a speed test";

	if (self.speedTest.running) return; // progress owns the speed label and button
	self.speedButton.enabled = (c != nil);
	self.speedButton.alpha = c ? 1.0 : 0.5;
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
	self.connSpeedLabel.text = [NSString stringWithFormat:@"↓ %.1f  ↑ %.1f Mbps  ·  %@",
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
	};
	self.speedTest.onComplete = ^(double down, double up, NSError *error) {
		typeof(self) strongSelf = weakSelf;
		if (!strongSelf) return;
		if (strongSelf.scanning) [strongSelf.wifi start];
		if (error) {
			strongSelf.connSpeedLabel.textColor = [UIColor systemRedColor];
			strongSelf.connSpeedLabel.text = [@"Speed test failed: " stringByAppendingString:error.localizedDescription];
		} else {
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

- (void)modeChanged:(UISegmentedControl *)sender {
	self.mode = sender.selectedSegmentIndex;
	[self rebuildAndReload];
}

- (void)updateSummary {
	// Count reflects what's actually shown (mode-filtered, displayed sections only).
	NSUInteger total = 0;
	for (NSInteger i = 0; i < kDisplaySectionCount; i++) total += self.sections[kDisplaySections[i]].count;


	self.totalLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)total];


	
	NSString *scope = (self.mode == 0) ? @"nearby now" : @"found this session";
	self.totalCaption.text = [NSString stringWithFormat:@"%@", scope];
	self.statusDot.backgroundColor = self.scanning ? [UIColor systemGreenColor] : [UIColor systemGrayColor];
	self.statusPillLabel.text = self.scanning ? @"Scanning" : @"Paused";
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
	if (!self.wifi) { self.wifi = [[ALWiFiScanner alloc] init]; self.wifi.onDevice = sink; }
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
}

- (void)rebuildAndReload {
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
		[wifiRows addObject:group];
	}
	[wifiRows sortUsingComparator:byRSSI];

	[ble sortUsingComparator:byRSSI];
	[classic sortUsingComparator:byRSSI];
	self.sections = @[wifiRows, ble, classic];
	[self updateSummary];
	[self.tableView reloadData];
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return kDisplaySectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	NSUInteger n = self.sections[kDisplaySections[section]].count;
	return n == 0 ? 1 : n; // one placeholder row when empty
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
	NSArray *items = self.sections[kDisplaySections[ip.section]];
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
	NSArray *items = self.sections[kDisplaySections[ip.section]];
	if (items.count == 0) return;
	ALDevice *d = items[ip.row];
	ALDetailViewController *vc = [[ALDetailViewController alloc] initWithDevice:d];
	[self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - Section headers

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section { return 46; }

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
	ALDeviceType t = kDisplaySections[section];
	UIView *v = [[UIView alloc] init];

	UIView *dot = [[UIView alloc] init];
	dot.backgroundColor = [ALDeviceCell colorForType:t];
	dot.layer.cornerRadius = 5;
	dot.translatesAutoresizingMaskIntoConstraints = NO;
	[v addSubview:dot];

	UILabel *title = [[UILabel alloc] init];
	title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
	title.textColor = [UIColor labelColor];
	title.text = [NSString stringWithFormat:@"%@  %lu",
				  [ALDevice nameForType:t], (unsigned long)self.sections[t].count];
	title.translatesAutoresizingMaskIntoConstraints = NO;
	[v addSubview:title];

	UILabel *status = [[UILabel alloc] init];
	status.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
	status.textColor = [UIColor tertiaryLabelColor];
	status.textAlignment = NSTextAlignmentRight;
	status.text = [self statusForSection:t];
	status.translatesAutoresizingMaskIntoConstraints = NO;
	[status setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
	[v addSubview:status];

	[NSLayoutConstraint activateConstraints:@[
		[dot.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:20],
		[dot.centerYAnchor constraintEqualToAnchor:v.centerYAnchor constant:4],
		[dot.widthAnchor constraintEqualToConstant:10],
		[dot.heightAnchor constraintEqualToConstant:10],
		[title.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:8],
		[title.centerYAnchor constraintEqualToAnchor:dot.centerYAnchor],
		[status.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-20],
		[status.centerYAnchor constraintEqualToAnchor:dot.centerYAnchor],
		[status.leadingAnchor constraintGreaterThanOrEqualToAnchor:title.trailingAnchor constant:8],
	]];
	return v;
}

@end
