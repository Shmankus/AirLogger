//
//  ALTileMapView.m — AirLogger
//
//  Tiles are CALayers keyed "z/x/y", repositioned on every camera change (cheap) and
//  fetched from tile.openstreetmap.org. A missing tile shows a cached ancestor
//  stretched over it until it arrives, so zooming never flashes blank.
//

#import "ALTileMapView.h"
#import "ALLog.h"

static const double kTileSize = 256.0;
static const double kMinZoom = 2.0;
static const double kMaxZoom = 19.0;
static const NSInteger kMaxTileZoom = 19;     // OSM's deepest level
static const NSInteger kMaxAncestorLevels = 5;
static const double kDecelRate = 3.0;         // fling velocity decay (1/s)

CGPoint ALWorldPointForCoordinate(CLLocationCoordinate2D c) {
	double lat = fmax(-85.05112878, fmin(85.05112878, c.latitude));
	double s = sin(lat * M_PI / 180.0);
	return CGPointMake((c.longitude + 180.0) / 360.0, 0.5 - log((1 + s) / (1 - s)) / (4 * M_PI));
}

static NSString *ALTileKey(NSInteger z, NSInteger x, NSInteger y) {
	return [NSString stringWithFormat:@"%ld/%ld/%ld", (long)z, (long)x, (long)y];
}

// Shared across map instances so tiles survive leaving and re-entering the tab.
static NSCache<NSString *, UIImage *> *ALTileCache(void) {
	static NSCache *cache;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; cache.countLimit = 400; });
	return cache;
}

static NSURLSession *ALTileSession(void) {
	static NSURLSession *session;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
		// OSM's tile usage policy requires an identifying User-Agent.
		cfg.HTTPAdditionalHeaders = @{ @"User-Agent": @"AirLogger/0.1 (personal iOS app)" };
		cfg.HTTPMaximumConnectionsPerHost = 4;
		// The app can't write its container, so the tile disk cache lives beside the DB.
		NSURL *dir = [NSURL fileURLWithPath:@"/var/mobile/Library/AirLogger/tiles" isDirectory:YES];
		cfg.URLCache = [[NSURLCache alloc] initWithMemoryCapacity:4 << 20 diskCapacity:100 << 20 directoryURL:dir];
		session = [NSURLSession sessionWithConfiguration:cfg];
	});
	return session;
}

// The Leaflet page darkened tiles with CSS `invert(1) hue-rotate(180deg)
// brightness(0.92) contrast(0.9)`. That chain is linear per pixel, so it's one
// colour matrix here: out = k·(1 - M·c) + 0.05, k = 0.92·0.9, M = hue-rotate(180°)
// (whose rows sum to 1, which is what makes the invert fold in).
static CGImageRef ALCreateDarkTile(CGImageRef src) {
	size_t w = CGImageGetWidth(src), h = CGImageGetHeight(src);
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs,
											 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
	CGColorSpaceRelease(cs);
	if (!ctx) return NULL;
	CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), src);
	static const float M[3][3] = {
		{ -0.574f, 1.430f,  0.144f },
		{  0.426f, 0.430f,  0.144f },
		{  0.426f, 1.430f, -0.856f },
	};
	const float k = 0.92f * 0.9f, bias = k + 0.05f;
	uint8_t *px = CGBitmapContextGetData(ctx);
	for (size_t i = 0; i < w * h; i++, px += 4) {
		float r = px[0] / 255.f, g = px[1] / 255.f, b = px[2] / 255.f;
		for (int ch = 0; ch < 3; ch++) {
			float v = bias - k * (M[ch][0] * r + M[ch][1] * g + M[ch][2] * b);
			px[ch] = (uint8_t)(fminf(fmaxf(v, 0.f), 1.f) * 255.f + 0.5f);
		}
	}
	CGImageRef out = CGBitmapContextCreateImage(ctx);
	CGContextRelease(ctx);
	return out;
}

@interface ALTileMapView () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *tileView;
@property (nonatomic, strong) UILabel *attribution;
@property (nonatomic, strong) NSMutableDictionary<NSString *, CALayer *> *tileLayers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSURLSessionDataTask *> *tasks;
@property (nonatomic, strong) UIPinchGestureRecognizer *pinch;
@property (nonatomic) CGSize lastSize;

// Motion (animated camera move or fling), driven by one display link.
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic) BOOL animating, decelerating;
@property (nonatomic) CGPoint fromCenter, toCenter;
@property (nonatomic) double fromZoom, toZoom;
@property (nonatomic) CFTimeInterval animStart, lastTick;
@property (nonatomic) CGPoint velocity;             // points/s

@property (nonatomic) CGPoint pinchWorld;           // world point under the fingers
@property (nonatomic) double pinchStartZoom;
@end

@implementation ALTileMapView

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.backgroundColor = [UIColor colorWithRed:0x1c/255.0 green:0x1c/255.0 blue:0x1e/255.0 alpha:1];
		self.clipsToBounds = YES;
		_centerWorld = CGPointMake(0.5, 0.5);
		_zoom = kMinZoom;
		_tileLayers = [NSMutableDictionary dictionary];
		_tasks = [NSMutableDictionary dictionary];

		_tileView = [[UIView alloc] initWithFrame:self.bounds];
		_tileView.userInteractionEnabled = NO;
		[self addSubview:_tileView];

		// OSM requires visible attribution.
		_attribution = [[UILabel alloc] init];
		_attribution.text = @" © OpenStreetMap ";
		_attribution.font = [UIFont systemFontOfSize:10];
		_attribution.textColor = [UIColor colorWithWhite:1 alpha:0.7];
		_attribution.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
		[_attribution sizeToFit];
		[self addSubview:_attribution];

		UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
		pan.maximumNumberOfTouches = 1;
		pan.delegate = self;
		[self addGestureRecognizer:pan];

		_pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(onPinch:)];
		_pinch.delegate = self;
		[self addGestureRecognizer:_pinch];

		UITapGestureRecognizer *dbl = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onDoubleTap:)];
		dbl.numberOfTapsRequired = 2;
		[self addGestureRecognizer:dbl];

		UITapGestureRecognizer *two = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTwoFingerTap:)];
		two.numberOfTouchesRequired = 2;
		[self addGestureRecognizer:two];

		UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)];
		[tap requireGestureRecognizerToFail:dbl];
		[self addGestureRecognizer:tap];
	}
	return self;
}

- (void)dealloc {
	for (NSURLSessionDataTask *t in self.tasks.allValues) [t cancel];
}

- (void)layoutSubviews {
	[super layoutSubviews];
	self.tileView.frame = self.bounds;
	UIEdgeInsets safe = self.safeAreaInsets;
	CGSize a = self.attribution.bounds.size;
	self.attribution.frame = CGRectMake(self.bounds.size.width - safe.right - a.width - 4,
										self.bounds.size.height - safe.bottom - a.height - 4, a.width, a.height);
	[self bringSubviewToFront:self.attribution];
	if (!CGSizeEqualToSize(self.bounds.size, self.lastSize)) {
		self.lastSize = self.bounds.size;
		[self applyCenter:self.centerWorld zoom:self.zoom];
		[self notifySettle];
	}
}

#pragma mark - Camera

- (double)pointsPerWorld {
	return kTileSize * pow(2.0, self.zoom);
}

- (CGPoint)pointForWorldPoint:(CGPoint)w {
	double S = self.pointsPerWorld;
	return CGPointMake((w.x - _centerWorld.x) * S + self.bounds.size.width / 2,
					   (w.y - _centerWorld.y) * S + self.bounds.size.height / 2);
}

- (CGPoint)worldPointForPoint:(CGPoint)p {
	double S = self.pointsPerWorld;
	return CGPointMake(_centerWorld.x + (p.x - self.bounds.size.width / 2) / S,
					   _centerWorld.y + (p.y - self.bounds.size.height / 2) / S);
}

// Moves the camera without animation or a settle notification.
- (void)applyCenter:(CGPoint)c zoom:(double)z {
	_zoom = fmax(kMinZoom, fmin(kMaxZoom, z));
	_centerWorld = CGPointMake(fmax(0, fmin(1, c.x)), fmax(0, fmin(1, c.y)));
	[self layoutTiles];
	if ([self.delegate respondsToSelector:@selector(mapViewCameraDidChange:)])
		[self.delegate mapViewCameraDidChange:self];
}

- (void)notifySettle {
	if ([self.delegate respondsToSelector:@selector(mapViewCameraDidSettle:)])
		[self.delegate mapViewCameraDidSettle:self];
}

- (void)setCenterWorld:(CGPoint)center zoom:(double)zoom animated:(BOOL)animated {
	[self stopMotion];
	if (!animated || !self.window) {
		[self applyCenter:center zoom:zoom];
		[self notifySettle];
		return;
	}
	self.fromCenter = self.centerWorld; self.toCenter = center;
	self.fromZoom = self.zoom;          self.toZoom = fmax(kMinZoom, fmin(kMaxZoom, zoom));
	self.animStart = CACurrentMediaTime();
	self.animating = YES;
	[self startLink];
}

- (void)fitWorldRect:(CGRect)rect padding:(CGFloat)padding maxZoom:(double)maxZoom animated:(BOOL)animated {
	UIEdgeInsets safe = self.safeAreaInsets;
	UIEdgeInsets pad = UIEdgeInsetsMake(safe.top + padding, safe.left + padding,
										safe.bottom + padding, safe.right + padding);
	double aw = self.bounds.size.width - pad.left - pad.right;
	double ah = self.bounds.size.height - pad.top - pad.bottom;
	if (aw <= 0 || ah <= 0) return;
	double zx = rect.size.width > 0 ? log2(aw / (rect.size.width * kTileSize)) : maxZoom;
	double zy = rect.size.height > 0 ? log2(ah / (rect.size.height * kTileSize)) : maxZoom;
	double z = floor(fmin(fmin(zx, zy), maxZoom));   // whole levels, like Leaflet
	double S = kTileSize * pow(2.0, fmax(kMinZoom, fmin(kMaxZoom, z)));
	// Put the rect's centre at the centre of the padded area, not of the view.
	double ox = (pad.left - pad.right) / 2, oy = (pad.top - pad.bottom) / 2;
	CGPoint c = CGPointMake(CGRectGetMidX(rect) - ox / S, CGRectGetMidY(rect) - oy / S);
	[self setCenterWorld:c zoom:z animated:animated];
}

- (void)panContentBy:(CGPoint)delta animated:(BOOL)animated {
	double S = self.pointsPerWorld;
	[self setCenterWorld:CGPointMake(self.centerWorld.x - delta.x / S, self.centerWorld.y - delta.y / S)
					zoom:self.zoom animated:animated];
}

#pragma mark - Motion

- (void)startLink {
	if (self.link) return;
	self.lastTick = CACurrentMediaTime();
	self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
	[self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

// The link retains self, so it only exists while something is moving.
- (void)stopMotion {
	self.animating = NO;
	self.decelerating = NO;
	[self.link invalidate];
	self.link = nil;
}

- (void)tick:(CADisplayLink *)link {
	CFTimeInterval now = CACurrentMediaTime();
	double dt = now - self.lastTick;
	self.lastTick = now;

	if (self.animating) {
		double t = fmin(1.0, (now - self.animStart) / 0.3);
		double e = 1 - pow(1 - t, 3);   // ease-out
		CGPoint c = CGPointMake(self.fromCenter.x + (self.toCenter.x - self.fromCenter.x) * e,
								self.fromCenter.y + (self.toCenter.y - self.fromCenter.y) * e);
		[self applyCenter:c zoom:self.fromZoom + (self.toZoom - self.fromZoom) * e];
		if (t >= 1) { [self stopMotion]; [self notifySettle]; }
		return;
	}
	if (self.decelerating) {
		double S = self.pointsPerWorld;
		CGPoint v = self.velocity;
		[self applyCenter:CGPointMake(self.centerWorld.x - v.x * dt / S, self.centerWorld.y - v.y * dt / S)
					 zoom:self.zoom];
		double decay = exp(-kDecelRate * dt);
		self.velocity = CGPointMake(v.x * decay, v.y * decay);
		if (hypot(self.velocity.x, self.velocity.y) < 20) { [self stopMotion]; [self notifySettle]; }
		return;
	}
	[self stopMotion];
}

#pragma mark - Gestures

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
	return YES;
}

- (void)onPan:(UIPanGestureRecognizer *)g {
	if (g.state == UIGestureRecognizerStateBegan) [self stopMotion];
	// While pinching, the pinch owns the camera (it keeps the fingers' point fixed).
	BOOL pinching = self.pinch.state == UIGestureRecognizerStateBegan ||
					self.pinch.state == UIGestureRecognizerStateChanged;
	CGPoint t = [g translationInView:self];
	[g setTranslation:CGPointZero inView:self];
	if (!pinching && (t.x != 0 || t.y != 0)) {
		double S = self.pointsPerWorld;
		[self applyCenter:CGPointMake(self.centerWorld.x - t.x / S, self.centerWorld.y - t.y / S) zoom:self.zoom];
	}
	if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
		CGPoint v = [g velocityInView:self];
		if (!pinching && g.state == UIGestureRecognizerStateEnded && hypot(v.x, v.y) > 150) {
			self.velocity = v;
			self.decelerating = YES;
			[self startLink];
		} else if (!pinching) {
			[self notifySettle];
		}
	}
}

- (void)onPinch:(UIPinchGestureRecognizer *)g {
	CGPoint loc = [g locationInView:self];
	if (g.state == UIGestureRecognizerStateBegan) {
		[self stopMotion];
		self.pinchWorld = [self worldPointForPoint:loc];
		self.pinchStartZoom = self.zoom;
	}
	if ((g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged) &&
		g.numberOfTouches >= 2) {
		// Keep the world point that started under the fingers under them.
		double z = fmax(kMinZoom, fmin(kMaxZoom, self.pinchStartZoom + log2(g.scale)));
		double S = kTileSize * pow(2.0, z);
		CGPoint c = CGPointMake(self.pinchWorld.x - (loc.x - self.bounds.size.width / 2) / S,
								self.pinchWorld.y - (loc.y - self.bounds.size.height / 2) / S);
		[self applyCenter:c zoom:z];
	}
	if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled)
		[self notifySettle];
}

- (void)zoomBy:(double)dz aroundPoint:(CGPoint)p {
	CGPoint w = [self worldPointForPoint:p];
	double z = fmax(kMinZoom, fmin(kMaxZoom, round(self.zoom) + dz));
	double S = kTileSize * pow(2.0, z);
	CGPoint c = CGPointMake(w.x - (p.x - self.bounds.size.width / 2) / S,
							w.y - (p.y - self.bounds.size.height / 2) / S);
	[self setCenterWorld:c zoom:z animated:YES];
}

- (void)onDoubleTap:(UITapGestureRecognizer *)g {
	[self zoomBy:1 aroundPoint:[g locationInView:self]];
}

- (void)onTwoFingerTap:(UITapGestureRecognizer *)g {
	[self zoomBy:-1 aroundPoint:CGPointMake(self.bounds.size.width / 2, self.bounds.size.height / 2)];
}

- (void)onTap:(UITapGestureRecognizer *)g {
	if ([self.delegate respondsToSelector:@selector(mapView:didTapAtPoint:)])
		[self.delegate mapView:self didTapAtPoint:[g locationInView:self]];
}

#pragma mark - Tiles

- (void)layoutTiles {
	CGSize size = self.bounds.size;
	if (size.width <= 0 || size.height <= 0) return;
	NSInteger tz = MAX(0, MIN(kMaxTileZoom, (NSInteger)lround(self.zoom)));
	double n = (double)(1L << tz);
	CGPoint tl = [self worldPointForPoint:CGPointZero];
	CGPoint br = [self worldPointForPoint:CGPointMake(size.width, size.height)];
	NSInteger x0 = MAX(0, (NSInteger)floor(tl.x * n)), x1 = MIN((NSInteger)n - 1, (NSInteger)floor(br.x * n));
	NSInteger y0 = MAX(0, (NSInteger)floor(tl.y * n)), y1 = MIN((NSInteger)n - 1, (NSInteger)floor(br.y * n));
	CGFloat scale = self.window.screen.scale ?: UIScreen.mainScreen.scale;

	NSMutableSet<NSString *> *wanted = [NSMutableSet set];
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	for (NSInteger y = y0; y <= y1; y++) {
		for (NSInteger x = x0; x <= x1; x++) {
			NSString *key = ALTileKey(tz, x, y);
			[wanted addObject:key];
			CALayer *l = self.tileLayers[key];
			if (!l) {
				l = [CALayer layer];
				self.tileLayers[key] = l;
				[self.tileView.layer addSublayer:l];
				[self fillTileLayer:l z:tz x:x y:y key:key];
			}
			// Round both edges the same way so neighbouring tiles share an edge (no seams).
			CGPoint a = [self pointForWorldPoint:CGPointMake(x / n, y / n)];
			CGPoint b = [self pointForWorldPoint:CGPointMake((x + 1) / n, (y + 1) / n)];
			CGFloat ax = round(a.x * scale) / scale, ay = round(a.y * scale) / scale;
			CGFloat bx = round(b.x * scale) / scale, by = round(b.y * scale) / scale;
			l.frame = CGRectMake(ax, ay, bx - ax, by - ay);
		}
	}
	for (NSString *key in self.tileLayers.allKeys) {
		if ([wanted containsObject:key]) continue;
		[self.tileLayers[key] removeFromSuperlayer];
		[self.tileLayers removeObjectForKey:key];
	}
	[CATransaction commit];
	for (NSString *key in self.tasks.allKeys) {
		if ([wanted containsObject:key]) continue;
		[self.tasks[key] cancel];
		[self.tasks removeObjectForKey:key];
	}
}

// Shows the tile if cached, else a cached ancestor's matching quarter (etc.) while it loads.
- (void)fillTileLayer:(CALayer *)l z:(NSInteger)z x:(NSInteger)x y:(NSInteger)y key:(NSString *)key {
	UIImage *img = [ALTileCache() objectForKey:key];
	if (img) { l.contents = (__bridge id)img.CGImage; return; }
	for (NSInteger d = 1; d <= kMaxAncestorLevels && d <= z; d++) {
		NSInteger px = x >> d, py = y >> d, sub = 1L << d;
		UIImage *anc = [ALTileCache() objectForKey:ALTileKey(z - d, px, py)];
		if (!anc) continue;
		l.contents = (__bridge id)anc.CGImage;
		l.contentsRect = CGRectMake((double)(x - (px << d)) / sub, (double)(y - (py << d)) / sub,
									1.0 / sub, 1.0 / sub);
		break;
	}
	[self loadTileZ:z x:x y:y key:key];
}

- (void)loadTileZ:(NSInteger)z x:(NSInteger)x y:(NSInteger)y key:(NSString *)key {
	if (self.tasks[key]) return;
	NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://tile.openstreetmap.org/%ld/%ld/%ld.png",
									   (long)z, (long)x, (long)y]];
	__weak typeof(self) ws = self;
	NSURLSessionDataTask *task = [ALTileSession() dataTaskWithURL:url
		completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
		NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
		UIImage *out = nil;
		if (data.length && status == 200) {
			UIImage *img = [UIImage imageWithData:data];
			CGImageRef dark = img.CGImage ? ALCreateDarkTile(img.CGImage) : NULL;
			if (dark) { out = [UIImage imageWithCGImage:dark]; CGImageRelease(dark); }
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			[ws tileFinished:key image:out status:status error:err];
		});
	}];
	self.tasks[key] = task;
	[task resume];
}

- (void)tileFinished:(NSString *)key image:(UIImage *)img status:(NSInteger)status error:(NSError *)err {
	[self.tasks removeObjectForKey:key];
	if (!img) {
		static NSUInteger logged = 0;
		if (err.code != NSURLErrorCancelled && logged++ < 5)
			ALLog(@"map: tile %@ failed (HTTP %ld) %@", key, (long)status, err.localizedDescription ?: @"");
		return;
	}
	[ALTileCache() setObject:img forKey:key];
	CALayer *l = self.tileLayers[key];
	if (!l) return;
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	l.contents = (__bridge id)img.CGImage;
	l.contentsRect = CGRectMake(0, 0, 1, 1);
	[CATransaction commit];
}

@end
