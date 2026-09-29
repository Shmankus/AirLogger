//
//  ALMapViewController.m — AirLogger
//
//  "Map" tab. MapKit can't render on this device, so the map is a WKWebView
//  running Leaflet (Resources/map.html) with OSM tiles. Computes each device's
//  estimated position (RSSI-weighted centroid / least-squares multilateration)
//  from the database and pushes fresh estimates into the page via updateData().
//

#import "ALMapViewController.h"
#import <WebKit/WebKit.h>
#import "ALDatabase.h"
#import "ALLocationProvider.h"
#import "ALDevice.h"
#import "ALLog.h"

// MapKit can't render on this device (Maps.app/engine missing), so we draw the
// map with Leaflet in a WKWebView and push fresh estimates in via JS so pan/zoom
// and tiles are preserved between updates.

static const double kTxRef = -45.0;      // approx RSSI at 1 m
static const double kPathLoss = 2.7;     // path-loss exponent
// Recency time constants (seconds); recent readings weigh more. Wi-Fi APs rarely
// move, so their strong older readings stay relevant; Bluetooth devices travel
// with people, so only recent readings say where they are now.
static const double kRecencyTauWiFi = 86400.0;
static const double kRecencyTauBT = 600.0;

@interface ALMapViewController () <WKNavigationDelegate, WKScriptMessageHandler>
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic) BOOL pageReady;
@property (nonatomic, strong) NSTimer *liveTimer;

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

	WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
	WKUserContentController *ucc = [[WKUserContentController alloc] init];
	[ucc addScriptMessageHandler:self name:@"err"];
	NSString *hook = @"window.onerror=function(m,s,l,c){try{window.webkit.messageHandlers.err.postMessage(m+' @'+l+':'+c);}catch(e){}};";
	[ucc addUserScript:[[WKUserScript alloc] initWithSource:hook
											  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
										   forMainFrameOnly:YES]];
	cfg.userContentController = ucc;

	self.web = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:cfg];
	self.web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	self.web.navigationDelegate = self;
	self.web.opaque = NO;
	[self.view addSubview:self.web];

	self.navigationItem.rightBarButtonItem =
		[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
													  target:self action:@selector(recenter)];

	self.typeFilter = -1; // all
	self.filterButton = [[UIBarButtonItem alloc]
		initWithImage:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"]
				 menu:[self buildFilterMenu]];
	self.navigationItem.leftBarButtonItem = self.filterButton;

	[self loadPage];
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

	NSArray *typeOpts = @[@"All", @"Wi-Fi", @"Bluetooth"];
	NSInteger typeVals[] = { -1, ALDeviceTypeWiFi, ALDeviceTypeClassicBT };
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
	[self pushData];
	self.liveTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
													  target:self selector:@selector(pushData)
													userInfo:nil repeats:YES];
}

- (void)viewDidDisappear:(BOOL)animated {
	[super viewDidDisappear:animated];
	[self.liveTimer invalidate];
	self.liveTimer = nil;
}

- (NSString *)hexForType:(ALDeviceType)t {
	switch (t) {
		case ALDeviceTypeWiFi:      return @"#0A84FF";
		case ALDeviceTypeBLE:       return @"#5E5CE6";
		case ALDeviceTypeClassicBT: return @"#40C8E0";
	}
	return @"#8E8E93";
}

#pragma mark - Page

- (void)loadPage {
	CLLocation *loc = [ALLocationProvider shared].currentLocation;
	double lat = loc ? loc.coordinate.latitude : 0.0;
	double lon = loc ? loc.coordinate.longitude : 0.0;

	NSString *path = [[NSBundle mainBundle] pathForResource:@"map" ofType:@"html"];
	NSString *html = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
	if (!html) { ALLog(@"map: map.html missing from bundle"); return; }
	// Placeholders are valid JS identifiers so an HTML/JS formatter won't mangle them.
	html = [html stringByReplacingOccurrencesOfString:@"__LAT__" withString:[NSString stringWithFormat:@"%f", lat]];
	html = [html stringByReplacingOccurrencesOfString:@"__LON__" withString:[NSString stringWithFormat:@"%f", lon]];

	[self.web loadHTMLString:html baseURL:[NSURL URLWithString:@"https://tile.openstreetmap.org/"]];
}

- (void)recenter {
	// Re-fit the view to the pins on the next push.
	[self.web evaluateJavaScript:@"didFit=false;" completionHandler:nil];
	[self pushData];
}

#pragma mark - Data push

- (void)pushData {
	if (!self.pageReady) return;
	NSString *pinsJSON = [self computePinsJSON];
	CLLocation *loc = [ALLocationProvider shared].currentLocation;
	double lat = loc ? loc.coordinate.latitude : 0.0;
	double lon = loc ? loc.coordinate.longitude : 0.0;
	NSString *js = [NSString stringWithFormat:@"updateData({u:[%f,%f],pins:%@});", lat, lon, pinsJSON];
	[self.web evaluateJavaScript:js completionHandler:nil];
}

- (NSString *)computePinsJSON {
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
		if (self.typeFilter >= 0 && t != self.typeFilter) continue;
		if (self.bandFilter.length && ![band isEqualToString:self.bandFilter]) continue;
		if (self.secFilter.length && ![sec hasPrefix:self.secFilter]) continue;

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

		NSString *name = [m[@"name"] length] ? m[@"name"] : id_;
		double ts = [m[@"ts"] doubleValue];
		[pins addObject:@{
			@"lat": @(elat), @"lon": @(elon),
			@"name": name ?: @"", @"id": id_ ?: @"", @"type": [ALDevice nameForType:t],
			@"rssi": @(best), @"n": @(n),
			@"radius": @(radius), @"color": [self hexForType:t],
			@"ts" : @(ts),
			@"band": band, @"security": sec,
			@"method": usedMLAT ? @"multilateration" : @"centroid",
		}];
	}

	NSData *j = [NSJSONSerialization dataWithJSONObject:pins options:0 error:nil];
	return j ? [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding] : @"[]";
}

#pragma mark - Web delegate

- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
	ALLog(@"map(web) JS: %@", message.body);
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
	self.pageReady = YES;
	[self pushData];
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
	ALLog(@"map(web): didFail: %@", error.localizedDescription);
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
	ALLog(@"map(web): didFailProvisional: %@", error.localizedDescription);
}

@end
