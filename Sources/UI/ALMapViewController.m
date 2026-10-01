//
//  ALMapViewController.m — AirLogger
//
//  "Map" tab. A native OSM tile map (ALTileMapView) with the device pins drawn
//  by ALPinOverlayView. Computes each device's estimated position (RSSI-weighted
//  centroid / least-squares multilateration) from the database and pushes fresh
//  estimates to the overlay every few seconds.
//

#import "ALMapViewController.h"
#import "ALDatabase.h"
#import "ALLocationProvider.h"
#import "ALDevice.h"
#import "ALAppDelegate.h"
#import "ALTileMapView.h"
#import "ALPinOverlayView.h"

// MapKit can't render on these devices (Maps.app and its tile engine are removed),
// and WKWebView can't either on iOS 17 + Dopamine (launchd refuses to start
// WebContent for jailbreak-installed apps), so the map is drawn natively.

static const double kTxRef = -45.0;      // approx RSSI at 1 m
static const double kPathLoss = 2.7;     // path-loss exponent
// Recency time constants (seconds); recent readings weigh more. Wi-Fi APs rarely
// move, so their strong older readings stay relevant; Bluetooth devices travel
// with people, so only recent readings say where they are now.
static const double kRecencyTauWiFi = 86400.0;
static const double kRecencyTauBT = 600.0;

@interface ALMapViewController () <ALPinOverlayDelegate>
@property (nonatomic, strong) ALTileMapView *mapView;
@property (nonatomic, strong) ALPinOverlayView *overlay;
@property (nonatomic, strong) NSTimer *liveTimer;
@property (nonatomic, copy) NSString *focusId;   // pin to keep visible + focus (nil = none)
@property (nonatomic) BOOL focusPending;         // focus once the map is on screen

// Filters
@property (nonatomic) NSInteger typeFilter;      // -1 = all, else ALDeviceType
@property (nonatomic, copy) NSString *bandFilter;    // nil = all
@property (nonatomic, copy) NSString *secFilter;     // nil = all
@property (nonatomic, strong) UIBarButtonItem *filterButton;
@end

@implementation ALMapViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"Map";

	self.mapView = [[ALTileMapView alloc] initWithFrame:self.view.bounds];
	self.mapView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	[self.view addSubview:self.mapView];
	self.overlay = [[ALPinOverlayView alloc] initWithMapView:self.mapView];
	self.overlay.delegate = self;
	[self.mapView addSubview:self.overlay];

	// Start on the user (the first data push then fits the nearby pins).
	CLLocation *loc = [ALLocationProvider shared].currentLocation;
	if (loc) [self.mapView setCenterWorld:ALWorldPointForCoordinate(loc.coordinate) zoom:16 animated:NO];

	self.navigationItem.rightBarButtonItem =
		[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
													  target:self action:@selector(recenter)];

	self.typeFilter = -1; // all
	self.filterButton = [[UIBarButtonItem alloc]
		initWithImage:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"]
				 menu:[self buildFilterMenu]];
	self.navigationItem.leftBarButtonItem = self.filterButton;

	// With no scroll view under it, iOS 15+ draws the nav bar in its transparent
	// scroll-edge style over the map; keep the normal blurred background instead.
	// (The tab bar's equivalent is set for all tabs in ALAppDelegate.)
	if (@available(iOS 15.0, *)) {
		UINavigationBarAppearance *nav = [[UINavigationBarAppearance alloc] init];
		[nav configureWithDefaultBackground];
		self.navigationItem.scrollEdgeAppearance = nav;
	}
}

#pragma mark - Filters

- (BOOL)anyFilterActive {
	return self.typeFilter >= 0 || self.bandFilter.length > 0 || self.secFilter.length > 0;
}

- (UIMenu *)singleMenu:(NSString *)title options:(NSArray<NSString *> *)opts
			   current:(NSString *)current setter:(void (^)(NSString *))setter {
	__weak typeof(self) ws = self;
	NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
	for (NSString *opt in opts) {
		BOOL isAll = [opt isEqualToString:@"All"];
		BOOL on = (isAll && current == nil) || [opt isEqualToString:current];
		UIAction *a = [UIAction actionWithTitle:opt image:nil identifier:nil
										handler:^(__kindof UIAction *action) {
			setter(isAll ? nil : opt);
			[ws rebuildFilterMenu];
			[ws recenter];
		}];
		a.state = on ? UIMenuElementStateOn : UIMenuElementStateOff;
		[actions addObject:a];
	}
	return [UIMenu menuWithTitle:title image:nil identifier:nil
						 options:UIMenuOptionsDisplayInline children:actions];
}

- (UIMenu *)buildFilterMenu {
	__weak typeof(self) ws = self;

	NSArray *typeOpts = @[@"All", @"Wi-Fi", @"BLE", @"Classic Bluetooth"];
	NSInteger typeVals[] = { -1, ALDeviceTypeWiFi, ALDeviceTypeBLE, ALDeviceTypeClassicBT };
	NSMutableArray<UIMenuElement *> *typeActions = [NSMutableArray array];
	for (NSUInteger i = 0; i < typeOpts.count; i++) {
		NSInteger val = typeVals[i];
		UIAction *a = [UIAction actionWithTitle:typeOpts[i] image:nil identifier:nil
										handler:^(__kindof UIAction *action) {
			ws.typeFilter = val;
			[ws rebuildFilterMenu];
			[ws recenter];
		}];
		a.state = (self.typeFilter == val) ? UIMenuElementStateOn : UIMenuElementStateOff;
		[typeActions addObject:a];
	}
	UIMenu *typeMenu = [UIMenu menuWithTitle:@"Type" image:nil identifier:nil
									 options:UIMenuOptionsDisplayInline children:typeActions];

	UIMenu *bandMenu = [self singleMenu:@"Band"
								options:@[@"All", @"2.4 GHz", @"5 GHz", @"6 GHz"]
								current:self.bandFilter setter:^(NSString *v) { ws.bandFilter = v; }];
	UIMenu *secMenu = [self singleMenu:@"Security"
							   options:@[@"All", @"Open", @"WEP", @"WPA/WPA2", @"WPA3"]
							   current:self.secFilter setter:^(NSString *v) { ws.secFilter = v; }];

	return [UIMenu menuWithTitle:@"" image:nil identifier:nil options:0
						children:@[typeMenu, bandMenu, secMenu]];
}

- (void)rebuildFilterMenu {
	self.filterButton.image = [UIImage systemImageNamed:
		([self anyFilterActive] ? @"line.3.horizontal.decrease.circle.fill"
								 : @"line.3.horizontal.decrease.circle")];
	self.filterButton.menu = [self buildFilterMenu];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	self.liveTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
													  target:self selector:@selector(pushData)
													userInfo:nil repeats:YES];
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	// First push here, not in viewWillAppear: the initial fit needs the final safe area.
	[self pushData];
	[self applyFocus];
}

- (void)viewDidDisappear:(BOOL)animated {
	[super viewDidDisappear:animated];
	[self.liveTimer invalidate];
	self.liveTimer = nil;
}

- (UIColor *)colorForType:(ALDeviceType)t {
	switch (t) {
		case ALDeviceTypeWiFi:      return [UIColor colorWithRed:0x0A/255.0 green:0x84/255.0 blue:0xFF/255.0 alpha:1];
		case ALDeviceTypeBLE:       return [UIColor colorWithRed:0x5E/255.0 green:0x5C/255.0 blue:0xE6/255.0 alpha:1];
		case ALDeviceTypeClassicBT: return [UIColor colorWithRed:0x40/255.0 green:0xC8/255.0 blue:0xE0/255.0 alpha:1];
	}
	return [UIColor colorWithRed:0x8E/255.0 green:0x8E/255.0 blue:0x93/255.0 alpha:1];
}

- (void)recenter {
	// Re-fit the view to the pins on the next push (and drop any focused pin).
	self.focusId = nil;
	self.overlay.didFit = NO;
	[self pushData];
}

- (void)focusOnIdentifier:(NSString *)identifier {
	self.focusId = identifier;
	self.focusPending = YES;
	[self loadViewIfNeeded];
	[self applyFocus];
}

- (void)applyFocus {
	// Wait until the map has its on-screen size, so the popup can be placed.
	if (!self.view.window || !self.focusPending || !self.focusId) return;
	self.focusPending = NO;
	// Skip the auto-fit, push pins (so the focused one exists), then zoom to it.
	self.overlay.didFit = YES;
	[self pushData];
	[self.overlay focusPin:self.focusId];
}

#pragma mark - Data push

- (void)pushData {
	if (!self.isViewLoaded) return;
	[self.overlay updateUser:[ALLocationProvider shared].currentLocation pins:[self computePins]];
}

- (NSArray<ALMapPin *> *)computePins {
	// Group every geotagged observation by device.
	NSMutableDictionary<NSString *, NSMutableArray *> *groups = [NSMutableDictionary dictionary];
	NSMutableDictionary<NSString *, NSDictionary *> *meta = [NSMutableDictionary dictionary];
	for (NSDictionary *o in [[ALDatabase shared] geotaggedObservations]) {
		NSString *id_ = o[@"identifier"];
		if (!id_.length) continue;
		NSMutableArray *arr = groups[id_];
		if (!arr) { arr = [NSMutableArray array]; groups[id_] = arr; }
		[arr addObject:o];
		meta[id_] = o;
	}

	// Per-device band/security (parsed from the latest stored info JSON) for filtering.
	NSMutableDictionary<NSString *, NSDictionary *> *metaInfo = [NSMutableDictionary dictionary];
	for (NSDictionary *r in [[ALDatabase shared] allDevices]) {
		NSString *rid = r[@"identifier"];
		if (!rid.length) continue;
		NSString *band = @"", *sec = @"";
		NSString *infoStr = r[@"info"];
		if (infoStr.length) {
			id p = [NSJSONSerialization JSONObjectWithData:[infoStr dataUsingEncoding:NSUTF8StringEncoding]
												   options:0 error:nil];
			if ([p isKindOfClass:[NSDictionary class]]) {
				if (p[@"Band"]) band = p[@"Band"];
				if (p[@"Security"]) sec = p[@"Security"];
			}
		}
		metaInfo[rid] = @{ @"band": band, @"security": sec };
	}

	double now = [NSDate date].timeIntervalSince1970;
	NSMutableArray *pins = [NSMutableArray array];

	for (NSString *id_ in groups) {
		NSArray *obs = groups[id_];
		NSUInteger n = obs.count;

		// Apply filters up front (skip the math for excluded devices).
		NSDictionary *m = meta[id_];
		ALDeviceType t = (ALDeviceType)[m[@"type"] integerValue];
		NSDictionary *mi = metaInfo[id_];
		NSString *band = mi[@"band"] ?: @"";
		NSString *sec = mi[@"security"] ?: @"";
		BOOL focused = [id_ isEqualToString:self.focusId];
		if (!focused && self.typeFilter >= 0 && t != self.typeFilter) continue;
		if (!focused && self.bandFilter.length && ![band isEqualToString:self.bandFilter]) continue;
		if (!focused && self.secFilter.length && ![sec hasPrefix:self.secFilter]) continue;

		double mlat = 0, mlon = 0; NSInteger best = -999;
		for (NSDictionary *o in obs) {
			mlat += [o[@"lat"] doubleValue]; mlon += [o[@"lon"] doubleValue];
			if ([o[@"rssi"] integerValue] > best) best = [o[@"rssi"] integerValue];
		}
		mlat /= n; mlon /= n;
		double mpd = 111320.0 * cos(mlat * M_PI / 180.0);

		double tau = (t == ALDeviceTypeWiFi) ? kRecencyTauWiFi : kRecencyTauBT;
		double xs[n], ys[n], rs[n], tw[n], cw[n];
		double sw = 0, cx = 0, cy = 0; NSInteger ki = 0; double kbestw = -1;
		for (NSUInteger i = 0; i < n; i++) {
			NSDictionary *o = obs[i];
			double x = ([o[@"lon"] doubleValue] - mlon) * mpd;
			double y = ([o[@"lat"] doubleValue] - mlat) * 111320.0;
			NSInteger rssi = [o[@"rssi"] integerValue];
			double age = now - [o[@"ts"] doubleValue];
			if (age < 0) age = 0;
			double recency = exp(-age / tau);                   // recent weighs more
			double rweight = pow(10.0, rssi / 20.0);            // stronger weighs more
			double combined = rweight * recency;
			xs[i] = x; ys[i] = y;
			rs[i] = pow(10.0, (kTxRef - rssi) / (10.0 * kPathLoss));
			tw[i] = recency; cw[i] = combined;
			sw += combined; cx += combined * x; cy += combined * y;
			if (combined > kbestw) { kbestw = combined; ki = (NSInteger)i; }
		}
		double wcx = sw > 0 ? cx / sw : 0, wcy = sw > 0 ? cy / sw : 0;

		// combined-weighted spread from the centroid (uncertainty + guard).
		double spread = 0, wsum = 0;
		for (NSUInteger i = 0; i < n; i++) {
			double d = sqrt((xs[i]-wcx)*(xs[i]-wcx) + (ys[i]-wcy)*(ys[i]-wcy));
			spread += cw[i] * d; wsum += cw[i];
		}
		spread = wsum > 0 ? spread / wsum : 0;

		// Recency-weighted least-squares multilateration.
		double ex = wcx, ey = wcy; BOOL usedMLAT = NO;
		if (n >= 3) {
			// Normalize the recency weights: scaling all weights by a constant
			// gives the identical WLS solution, but keeps the matrix from
			// underflowing to a near-zero determinant when the data is old
			// (otherwise it always falls back to the centroid).
			double maxTw = 0;
			for (NSUInteger i = 0; i < n; i++) if (tw[i] > maxTw) maxTw = tw[i];
			if (maxTw <= 0) maxTw = 1;

			double xk = xs[ki], yk = ys[ki], rk = rs[ki];
			double m00=0,m01=0,m11=0,v0=0,v1=0;
			for (NSUInteger i = 0; i < n; i++) {
				if ((NSInteger)i == ki) continue;
				double wt = tw[i] / maxTw;
				double a0 = 2*(xk - xs[i]), a1 = 2*(yk - ys[i]);
				double bi = rs[i]*rs[i] - rk*rk - xs[i]*xs[i] - ys[i]*ys[i] + xk*xk + yk*yk;
				m00 += wt*a0*a0; m01 += wt*a0*a1; m11 += wt*a1*a1; v0 += wt*a0*bi; v1 += wt*a1*bi;
			}
			double det = m00*m11 - m01*m01;
			if (fabs(det) > 1e-3) {
				double sx = ( m11*v0 - m01*v1) / det;
				double sy = (-m01*v0 + m00*v1) / det;
				double dist = sqrt(sx*sx + sy*sy);
				double cap = fmax(5.0 * spread, 120.0);
				if (dist <= cap) { ex = sx; ey = sy; usedMLAT = YES; }
			}
		}

		double elat = mlat + ey / 111320.0;
		double elon = mlon + ex / mpd;
		double radius = n > 1 ? fmax(spread, 12.0) : 40.0;

		ALMapPin *pin = [[ALMapPin alloc] init];
		pin.identifier = id_;
		pin.name = [m[@"name"] length] ? m[@"name"] : id_;
		pin.typeName = [ALDevice nameForType:t];
		pin.color = [self colorForType:t];
		pin.coordinate = CLLocationCoordinate2DMake(elat, elon);
		pin.rssi = best;
		pin.observations = (NSInteger)n;
		pin.radius = radius;
		pin.lastSeen = [m[@"ts"] doubleValue];
		pin.method = usedMLAT ? @"multilateration" : @"centroid";
		[pins addObject:pin];
	}
	return pins;
}

#pragma mark - Overlay delegate

- (void)pinOverlay:(ALPinOverlayView *)overlay showDetailForIdentifier:(NSString *)identifier {
	[ALAppDelegate showDetailForIdentifier:identifier];
}

@end
