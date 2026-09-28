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
static const double kRecencyTau = 600.0; // seconds; recent readings weigh more

@interface ALMapViewController () <WKNavigationDelegate, WKScriptMessageHandler>
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic) BOOL pageReady;
@property (nonatomic, strong) NSTimer *liveTimer;
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

	[self loadPage];
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
	html = [html stringByReplacingOccurrencesOfString:@"{{LAT}}" withString:[NSString stringWithFormat:@"%f", lat]];
	html = [html stringByReplacingOccurrencesOfString:@"{{LON}}" withString:[NSString stringWithFormat:@"%f", lon]];

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

	double now = [NSDate date].timeIntervalSince1970;
	NSMutableArray *pins = [NSMutableArray array];

	for (NSString *id_ in groups) {
		NSArray *obs = groups[id_];
		NSUInteger n = obs.count;

		double mlat = 0, mlon = 0; NSInteger best = -999;
		for (NSDictionary *o in obs) {
			mlat += [o[@"lat"] doubleValue]; mlon += [o[@"lon"] doubleValue];
			if ([o[@"rssi"] integerValue] > best) best = [o[@"rssi"] integerValue];
		}
		mlat /= n; mlon /= n;
		double mpd = 111320.0 * cos(mlat * M_PI / 180.0);

		double xs[n], ys[n], rs[n], tw[n], cw[n];
		double sw = 0, cx = 0, cy = 0; NSInteger ki = 0; double kbestw = -1;
		for (NSUInteger i = 0; i < n; i++) {
			NSDictionary *o = obs[i];
			double x = ([o[@"lon"] doubleValue] - mlon) * mpd;
			double y = ([o[@"lat"] doubleValue] - mlat) * 111320.0;
			NSInteger rssi = [o[@"rssi"] integerValue];
			double age = now - [o[@"ts"] doubleValue];
			if (age < 0) age = 0;
			double recency = exp(-age / kRecencyTau);           // recent weighs more
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
			double xk = xs[ki], yk = ys[ki], rk = rs[ki];
			double m00=0,m01=0,m11=0,v0=0,v1=0;
			for (NSUInteger i = 0; i < n; i++) {
				if ((NSInteger)i == ki) continue;
				double wt = tw[i];
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

		NSDictionary *m = meta[id_];
		ALDeviceType t = (ALDeviceType)[m[@"type"] integerValue];
		NSString *name = [m[@"name"] length] ? m[@"name"] : id_;
		[pins addObject:@{
			@"lat": @(elat), @"lon": @(elon),
			@"name": name ?: @"", @"id": id_ ?: @"", @"type": [ALDevice nameForType:t],
			@"rssi": @(best), @"n": @(n),
			@"radius": @(radius), @"color": [self hexForType:t],
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
