//
//  ALPinOverlayView.m — AirLogger
//
//  Same rendering budget as the Leaflet page: the pin list is re-culled and the
//  canvas redrawn only when the camera settles or data arrives. During a gesture
//  the canvas is just transformed to follow the camera, and the easing display
//  link runs only while a dot is still moving.
//

#import "ALPinOverlayView.h"

// Below kNoClusterZoom, pins within kClusterPx of each other merge into one counted
// bubble; from kNoClusterZoom up every pin is its own dot.
static const double kClusterPx = 50.0;
static const NSInteger kNoClusterZoom = 18;
// The canvas extends past each edge by this fraction of the view, so a pan shows
// already-drawn pins until it settles and the canvas is redrawn.
static const double kCanvasPad = 0.15;
// Dots within this many metres count as stacked (drawn on top of one another).
static const double kStackMeters = 3.0;
static const double kDotRadius = 6.0;
static const double kTapRadius = 22.0;

static double ALDistMeters(CLLocationCoordinate2D a, CLLocationCoordinate2D b) {
	double dy = (a.latitude - b.latitude) * 111320.0;
	double dx = (a.longitude - b.longitude) * 111320.0 * cos(a.latitude * M_PI / 180.0);
	return sqrt(dx * dx + dy * dy);
}

static UIColor *ALHex(uint32_t rgb, CGFloat a) {
	return [UIColor colorWithRed:((rgb >> 16) & 0xff) / 255.0 green:((rgb >> 8) & 0xff) / 255.0
							blue:(rgb & 0xff) / 255.0 alpha:a];
}

@implementation ALMapPin
@end

// A pin plus where its dot is drawn (cur eases toward target; both world points).
@interface ALPinEntry : NSObject
@property (nonatomic, strong) ALMapPin *pin;
@property (nonatomic) CGPoint cur, target;
@end
@implementation ALPinEntry
@end

// A cluster-level item: a lone pin (n == 1, leafId set) or a merged bubble.
@interface ALPinCluster : NSObject
@property (nonatomic) double x, y;                   // weighted centre, world
@property (nonatomic) NSInteger n;
@property (nonatomic, copy) NSString *leafId;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *typeCounts;
@property (nonatomic) double minX, minY, maxX, maxY; // member bounds, world
- (CGFloat)bubbleSize;
@end
@implementation ALPinCluster
- (CGFloat)bubbleSize {
	return MIN(60, round(22 + 8 * log2((double)self.n)));
}
@end

#pragma mark - Canvas / popup views

@interface ALPinOverlayView ()
- (void)drawCanvasRect:(CGRect)rect size:(CGSize)size;
@end

@interface ALPinCanvas : UIView
@property (nonatomic, weak) ALPinOverlayView *owner;
@end
@implementation ALPinCanvas
- (void)drawRect:(CGRect)rect {
	[self.owner drawCanvasRect:rect size:self.bounds.size];
}
@end

@interface ALPinPopupView : UIView
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UIButton *prev, *next, *details;
@property (nonatomic, strong) CAShapeLayer *bubble;
@property (nonatomic) BOOL showsButtons;
@property (nonatomic, copy) void (^onPrev)(void), (^onNext)(void), (^onDetails)(void);
@end

@implementation ALPinPopupView

static const CGFloat kPopupWidth = 250, kPopupInset = 12, kTipHeight = 8, kButtonHeight = 30;

- (UIButton *)buttonWithTitle:(NSString *)title color:(UIColor *)color action:(SEL)action {
	UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
	[b setTitle:title forState:UIControlStateNormal];
	[b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
	b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
	b.backgroundColor = color;
	b.layer.cornerRadius = 8;
	[b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
	[self addSubview:b];
	return b;
}

- (instancetype)init {
	if ((self = [super initWithFrame:CGRectZero])) {
		_bubble = [CAShapeLayer layer];
		_bubble.fillColor = ALHex(0x2c2c2e, 1).CGColor;
		_bubble.shadowColor = UIColor.blackColor.CGColor;
		_bubble.shadowOpacity = 0.4;
		_bubble.shadowRadius = 6;
		_bubble.shadowOffset = CGSizeMake(0, 2);
		[self.layer addSublayer:_bubble];
		_label = [[UILabel alloc] init];
		_label.numberOfLines = 0;
		[self addSubview:_label];
		_prev = [self buttonWithTitle:@"‹ Prev" color:ALHex(0x3a3a3c, 1) action:@selector(tapPrev)];
		_next = [self buttonWithTitle:@"Next ›" color:ALHex(0x3a3a3c, 1) action:@selector(tapNext)];
		_details = [self buttonWithTitle:@"View Details" color:ALHex(0x0a84ff, 1) action:@selector(tapDetails)];
	}
	return self;
}

- (void)tapPrev { if (self.onPrev) self.onPrev(); }
- (void)tapNext { if (self.onNext) self.onNext(); }
- (void)tapDetails { if (self.onDetails) self.onDetails(); }

- (void)setText:(NSAttributedString *)text buttons:(BOOL)buttons prevEnabled:(BOOL)prev nextEnabled:(BOOL)next {
	self.label.attributedText = text;
	self.showsButtons = buttons;
	self.prev.hidden = self.next.hidden = self.details.hidden = !buttons;
	self.prev.enabled = prev;
	self.next.enabled = next;
	self.prev.alpha = prev ? 1 : 0.35;
	self.next.alpha = next ? 1 : 0.35;

	CGFloat inner = kPopupWidth - 2 * kPopupInset;
	CGFloat lh = ceil([text boundingRectWithSize:CGSizeMake(inner, CGFLOAT_MAX)
										 options:NSStringDrawingUsesLineFragmentOrigin context:nil].size.height);
	self.label.frame = CGRectMake(kPopupInset, kPopupInset, inner, lh);
	CGFloat y = kPopupInset + lh;
	if (buttons) {
		CGFloat half = (inner - 8) / 2;
		self.prev.frame = CGRectMake(kPopupInset, y + 8, half, kButtonHeight);
		self.next.frame = CGRectMake(kPopupInset + half + 8, y + 8, half, kButtonHeight);
		self.details.frame = CGRectMake(kPopupInset, y + 16 + kButtonHeight, inner, kButtonHeight);
		y += 16 + 2 * kButtonHeight;
	}
	CGFloat bodyH = y + kPopupInset;
	self.bounds = CGRectMake(0, 0, kPopupWidth, bodyH + kTipHeight);

	UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, kPopupWidth, bodyH) cornerRadius:12];
	[path moveToPoint:CGPointMake(kPopupWidth / 2 - kTipHeight, bodyH)];
	[path addLineToPoint:CGPointMake(kPopupWidth / 2, bodyH + kTipHeight)];
	[path addLineToPoint:CGPointMake(kPopupWidth / 2 + kTipHeight, bodyH)];
	[path closePath];
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	self.bubble.path = path.CGPath;
	self.bubble.shadowPath = path.CGPath;
	[CATransaction commit];
}

// Places the popup so its tip points just above `anchor`.
- (void)placeAtAnchor:(CGPoint)anchor {
	CGSize s = self.bounds.size;
	self.center = CGPointMake(anchor.x, anchor.y - kDotRadius - 2 - s.height / 2);
}

@end

#pragma mark - Overlay

@interface ALPinOverlayView ()
@property (nonatomic, weak) ALTileMapView *map;
@property (nonatomic, strong) ALPinCanvas *canvas;
@property (nonatomic, strong) ALPinPopupView *popup;

@property (nonatomic, strong) NSMutableDictionary<NSString *, ALPinEntry *> *entries;
@property (nonatomic, strong) NSDictionary<NSString *, UIColor *> *typeColors;
@property (nonatomic, strong) NSArray<NSArray<ALPinCluster *> *> *levels;  // levels[z], z = 0...kNoClusterZoom
@property (nonatomic, strong) NSSet<NSString *> *visibleIds;               // lone pins drawn now
@property (nonatomic, strong) NSArray<ALPinCluster *> *visibleClusters;

@property (nonatomic) BOOL hasUser;
@property (nonatomic) CLLocationCoordinate2D userCoord;
@property (nonatomic) CGPoint userWorld;

// Camera the canvas was last drawn with; a gesture transforms from it to the live one.
@property (nonatomic) CGPoint renderCenter;
@property (nonatomic) double renderScale;

// Popup state. currentId = pin whose popup is open; userPopup = the "You" popup.
@property (nonatomic, copy) NSString *currentId;
@property (nonatomic) BOOL userPopup;
// Prev/Next walk: every pin by distance from the dot the walk started on
// (navOrder[0]). Fixed while walking so Prev exactly retraces Next; reset when
// a popup is opened any other way.
@property (nonatomic, strong) NSArray<NSString *> *navOrder;
@property (nonatomic, strong) NSArray<NSNumber *> *navDist;
@property (nonatomic) NSInteger navIdx;
@property (nonatomic) BOOL navigating;     // a popup is being opened by goTo, not a tap

@property (nonatomic, strong) CADisplayLink *easeLink;
@end

@implementation ALPinOverlayView

- (instancetype)initWithMapView:(ALTileMapView *)map {
	if ((self = [super initWithFrame:map.bounds])) {
		_map = map;
		map.delegate = self;
		self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		self.backgroundColor = UIColor.clearColor;
		_entries = [NSMutableDictionary dictionary];
		_levels = @[];
		_visibleIds = [NSSet set];
		_visibleClusters = @[];

		_canvas = [[ALPinCanvas alloc] initWithFrame:self.bounds];
		_canvas.owner = self;
		_canvas.opaque = NO;
		_canvas.backgroundColor = UIColor.clearColor;
		_canvas.userInteractionEnabled = NO;
		[self addSubview:_canvas];

		_popup = [[ALPinPopupView alloc] init];
		_popup.hidden = YES;
		__weak typeof(self) ws = self;
		_popup.onPrev = ^{ [ws navStep:-1]; };
		_popup.onNext = ^{ [ws navStep:1]; };
		_popup.onDetails = ^{
			if (ws.currentId) [ws.delegate pinOverlay:ws showDetailForIdentifier:ws.currentId];
		};
		[self addSubview:_popup];
	}
	return self;
}

// Only the popup takes touches; everything else falls through to the map's gestures.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
	if (self.popup.hidden) return nil;
	UIView *hit = [self.popup hitTest:[self convertPoint:point toView:self.popup] withEvent:event];
	return hit;
}

- (void)willMoveToWindow:(UIWindow *)window {
	[super willMoveToWindow:window];
	if (!window) [self stopEasing];
}

#pragma mark - Map delegate

- (void)mapViewCameraDidChange:(ALTileMapView *)map {
	// Follow the camera without redrawing: scale about the view centre, then shift.
	double S = map.pointsPerWorld;
	double k = self.renderScale > 0 ? S / self.renderScale : 1;
	double tx = (self.renderCenter.x - map.centerWorld.x) * S;
	double ty = (self.renderCenter.y - map.centerWorld.y) * S;
	self.canvas.transform = CGAffineTransformMake(k, 0, 0, k, tx, ty);
	[self positionPopup];
}

- (void)mapViewCameraDidSettle:(ALTileMapView *)map {
	[self render];
}

- (void)mapView:(ALTileMapView *)map didTapAtPoint:(CGPoint)p {
	NSString *bestId = nil; ALPinCluster *bestCluster = nil; BOOL bestUser = NO;
	double bestD = kTapRadius;
	for (NSString *pid in self.visibleIds) {
		CGPoint q = [map pointForWorldPoint:self.entries[pid].cur];
		double d = hypot(q.x - p.x, q.y - p.y);
		if (d <= bestD) { bestD = d; bestId = pid; }
	}
	for (ALPinCluster *cl in self.visibleClusters) {
		CGPoint q = [map pointForWorldPoint:CGPointMake(cl.x, cl.y)];
		double d = hypot(q.x - p.x, q.y - p.y);
		// Bubbles are bigger than dots, so the first one may be hit beyond kTapRadius.
		if (d <= cl.bubbleSize / 2 + 6 && (d < bestD || (!bestId && !bestCluster))) {
			bestD = d; bestCluster = cl; bestId = nil;
		}
	}
	if (self.hasUser && !bestId && !bestCluster) {
		CGPoint q = [map pointForWorldPoint:self.userWorld];
		bestUser = hypot(q.x - p.x, q.y - p.y) <= kTapRadius;
	}

	if (bestCluster) {
		// Zoom to fit the bubble's members so they separate.
		if (bestCluster.minX == bestCluster.maxX && bestCluster.minY == bestCluster.maxY)
			[map setCenterWorld:CGPointMake(bestCluster.minX, bestCluster.minY) zoom:kNoClusterZoom animated:YES];
		else
			[map fitWorldRect:CGRectMake(bestCluster.minX, bestCluster.minY,
										 bestCluster.maxX - bestCluster.minX, bestCluster.maxY - bestCluster.minY)
					  padding:50 maxZoom:kNoClusterZoom animated:YES];
	} else if (bestId) {
		[self openPopupFor:bestId];
	} else if (bestUser) {
		self.currentId = nil;
		self.userPopup = YES;
		[self refreshPopup];
	} else {
		[self closePopup];
	}
}

#pragma mark - Data

- (void)updateUser:(CLLocation *)user pins:(NSArray<ALMapPin *> *)pins {
	self.hasUser = user != nil;
	if (user) {
		self.userCoord = user.coordinate;
		self.userWorld = ALWorldPointForCoordinate(user.coordinate);
	}
	NSMutableSet<NSString *> *seen = [NSMutableSet set];
	NSMutableDictionary<NSString *, UIColor *> *colors = [NSMutableDictionary dictionary];
	BOOL moved = NO, changed = NO;
	double minX = INFINITY, minY = INFINITY, maxX = -INFINITY, maxY = -INFINITY;
	NSUInteger fitCount = 0;

	for (ALMapPin *p in pins) {
		if (!p.identifier.length || [seen containsObject:p.identifier]) continue;
		[seen addObject:p.identifier];
		if (p.typeName && p.color) colors[p.typeName] = p.color;
		CGPoint t = ALWorldPointForCoordinate(p.coordinate);
		ALPinEntry *e = self.entries[p.identifier];
		if (e) {
			if (!CGPointEqualToPoint(e.target, t)) { e.target = t; moved = YES; }
			e.pin = p;
		} else {
			e = [[ALPinEntry alloc] init];
			e.pin = p; e.cur = t; e.target = t;
			self.entries[p.identifier] = e;
			changed = YES;
		}
		// The first fit covers pins near the user (all of them without a fix).
		if (!user || ALDistMeters(p.coordinate, user.coordinate) < 2000) {
			minX = fmin(minX, t.x); maxX = fmax(maxX, t.x);
			minY = fmin(minY, t.y); maxY = fmax(maxY, t.y);
			fitCount++;
		}
	}
	self.typeColors = colors;

	// Drop devices no longer present (e.g. after a wipe or a filter change).
	for (NSString *pid in self.entries.allKeys) {
		if ([seen containsObject:pid]) continue;
		[self.entries removeObjectForKey:pid];
		changed = YES;
		if ([pid isEqualToString:self.currentId]) [self closePopup];
	}

	// Rebuilding every level is the expensive part; skip it when the pins are the
	// same as last push (most refreshes while standing still).
	if (changed || moved) [self buildClusters];

	// Fit once; afterwards leave the user's pan/zoom alone (refresh re-fits).
	if (!self.didFit && (user || fitCount)) {
		if (user) {
			minX = fmin(minX, self.userWorld.x); maxX = fmax(maxX, self.userWorld.x);
			minY = fmin(minY, self.userWorld.y); maxY = fmax(maxY, self.userWorld.y);
			fitCount++;
		}
		self.didFit = YES;
		if (fitCount > 1 && (maxX > minX || maxY > minY))
			[self.map fitWorldRect:CGRectMake(minX, minY, maxX - minX, maxY - minY)
						   padding:40 maxZoom:kNoClusterZoom animated:NO];
		else
			[self.map setCenterWorld:CGPointMake(minX, minY) zoom:16 animated:NO];
	}
	[self render];
	if (self.currentId || self.userPopup) [self refreshPopup];
	if (moved) [self startEasing];
}

- (void)focusPin:(NSString *)identifier {
	self.navOrder = nil;
	[self goTo:identifier];
}

#pragma mark - Clustering

// Hierarchical clustering (the supercluster approach) over ALL pins, so counts don't
// depend on what's on screen. levels[kNoClusterZoom] is the individual pins; each
// lower level greedily merges the level above, absorbing items within kClusterPx (at
// that zoom) of a seed — so a bubble is always exactly the union of what it splits
// into one zoom level up.
- (void)buildClusters {
	NSMutableArray<ALPinCluster *> *leaves = [NSMutableArray arrayWithCapacity:self.entries.count];
	for (NSString *pid in self.entries) {
		ALPinEntry *e = self.entries[pid];
		ALPinCluster *c = [[ALPinCluster alloc] init];
		c.x = c.minX = c.maxX = e.target.x;
		c.y = c.minY = c.maxY = e.target.y;
		c.n = 1;
		c.leafId = pid;
		c.typeCounts = [NSMutableDictionary dictionaryWithObject:@1 forKey:e.pin.typeName ?: @""];
		[leaves addObject:c];
	}
	NSMutableArray *levels = [NSMutableArray arrayWithCapacity:kNoClusterZoom + 1];
	for (NSInteger z = 0; z <= kNoClusterZoom; z++) [levels addObject:@[]];
	levels[kNoClusterZoom] = leaves;
	for (NSInteger z = kNoClusterZoom - 1; z >= 0; z--)
		levels[z] = [self mergeLevel:levels[z + 1] radius:kClusterPx / (256.0 * pow(2.0, z))];
	self.levels = levels;
}

- (NSArray<ALPinCluster *> *)mergeLevel:(NSArray<ALPinCluster *> *)items radius:(double)r {
	// Grid index with cell size r: any neighbour within r is in the 3x3 block.
	// Cell counts stay under 2^21 per axis down to r at zoom 17, so the key is unique.
	NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *grid = [NSMutableDictionary dictionary];
	NSUInteger count = items.count;
	for (NSUInteger i = 0; i < count; i++) {
		long long gx = (long long)floor(items[i].x / r), gy = (long long)floor(items[i].y / r);
		NSNumber *key = @((gx << 21) + gy);
		NSMutableArray *cell = grid[key];
		if (!cell) { cell = [NSMutableArray array]; grid[key] = cell; }
		[cell addObject:@(i)];
	}
	BOOL *used = calloc(count ?: 1, sizeof(BOOL));
	double r2 = r * r;
	NSMutableArray<ALPinCluster *> *out = [NSMutableArray array];
	for (NSUInteger i = 0; i < count; i++) {
		if (used[i]) continue;
		used[i] = YES;
		ALPinCluster *seed = items[i];
		long long gx = (long long)floor(seed.x / r), gy = (long long)floor(seed.y / r);
		NSMutableArray<ALPinCluster *> *group = [NSMutableArray arrayWithObject:seed];
		for (long long dx = -1; dx <= 1; dx++) for (long long dy = -1; dy <= 1; dy++) {
			for (NSNumber *jn in grid[@(((gx + dx) << 21) + gy + dy)]) {
				NSUInteger j = jn.unsignedIntegerValue;
				if (used[j]) continue;
				double ddx = items[j].x - seed.x, ddy = items[j].y - seed.y;
				if (ddx * ddx + ddy * ddy <= r2) { used[j] = YES; [group addObject:items[j]]; }
			}
		}
		if (group.count == 1) { [out addObject:seed]; continue; }   // carried up unchanged
		ALPinCluster *c = [[ALPinCluster alloc] init];
		c.typeCounts = [NSMutableDictionary dictionary];
		c.minX = seed.minX; c.minY = seed.minY; c.maxX = seed.maxX; c.maxY = seed.maxY;
		double x = 0, y = 0; NSInteger n = 0;
		for (ALPinCluster *g in group) {
			n += g.n; x += g.x * g.n; y += g.y * g.n;
			for (NSString *t in g.typeCounts)
				c.typeCounts[t] = @(c.typeCounts[t].integerValue + g.typeCounts[t].integerValue);
			c.minX = fmin(c.minX, g.minX); c.minY = fmin(c.minY, g.minY);
			c.maxX = fmax(c.maxX, g.maxX); c.maxY = fmax(c.maxY, g.maxY);
		}
		c.n = n; c.x = x / n; c.y = y / n;
		[out addObject:c];
	}
	free(used);
	return out;
}

#pragma mark - Rendering

// Cull the current zoom's level to the (padded) viewport and redraw the canvas.
// Runs when the camera settles and after each data push, never per frame.
- (void)render {
	CGSize sz = self.bounds.size;
	if (sz.width <= 0 || sz.height <= 0) return;
	ALTileMapView *map = self.map;
	self.renderCenter = map.centerWorld;
	self.renderScale = map.pointsPerWorld;
	self.canvas.transform = CGAffineTransformIdentity;
	self.canvas.frame = CGRectInset(self.bounds, -sz.width * kCanvasPad, -sz.height * kCanvasPad);

	CGPoint tl = [map worldPointForPoint:self.canvas.frame.origin];
	CGPoint br = [map worldPointForPoint:CGPointMake(CGRectGetMaxX(self.canvas.frame), CGRectGetMaxY(self.canvas.frame))];
	NSInteger z = MAX(0, MIN(kNoClusterZoom, (NSInteger)floor(map.zoom)));
	NSArray<ALPinCluster *> *items = z < (NSInteger)self.levels.count ? self.levels[z] : @[];
	NSMutableSet<NSString *> *ids = [NSMutableSet set];
	NSMutableArray<ALPinCluster *> *clusters = [NSMutableArray array];
	for (ALPinCluster *it in items) {
		if (it.n == 1) {
			CGPoint t = self.entries[it.leafId].target;
			if (t.x >= tl.x && t.x <= br.x && t.y >= tl.y && t.y <= br.y) [ids addObject:it.leafId];
		} else if (!(it.maxX < tl.x || it.minX > br.x || it.maxY < tl.y || it.minY > br.y)) {
			[clusters addObject:it];
		}
	}
	self.visibleIds = ids;
	self.visibleClusters = clusters;
	[self.canvas setNeedsDisplay];
	[self positionPopup];
}

- (void)drawCanvasRect:(CGRect)rect size:(CGSize)size {
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	double S = self.renderScale;
	CGPoint rc = self.renderCenter;
	CGPoint (^pt)(CGPoint) = ^CGPoint(CGPoint w) {
		return CGPointMake((w.x - rc.x) * S + size.width / 2, (w.y - rc.y) * S + size.height / 2);
	};

	// Device dots, then cluster bubbles above them, then the user on top.
	CGContextSetLineWidth(ctx, 1.5);
	CGContextSetStrokeColorWithColor(ctx, UIColor.whiteColor.CGColor);
	for (NSString *pid in self.visibleIds) {
		ALPinEntry *e = self.entries[pid];
		CGPoint p = pt(e.cur);
		CGRect r = CGRectMake(p.x - kDotRadius, p.y - kDotRadius, 2 * kDotRadius, 2 * kDotRadius);
		if (!CGRectIntersectsRect(CGRectInset(r, -2, -2), rect)) continue;
		CGContextSetFillColorWithColor(ctx, [e.pin.color colorWithAlphaComponent:0.95].CGColor);
		CGContextFillEllipseInRect(ctx, r);
		CGContextStrokeEllipseInRect(ctx, r);
	}

	NSDictionary *textAttrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightBold],
								 NSForegroundColorAttributeName: UIColor.whiteColor };
	for (ALPinCluster *cl in self.visibleClusters) {
		CGFloat size = cl.bubbleSize;
		CGPoint p = pt(CGPointMake(cl.x, cl.y));
		CGRect r = CGRectMake(p.x - size / 2, p.y - size / 2, size, size);
		if (!CGRectIntersectsRect(r, rect)) continue;
		// Coloured by the most common type among its members.
		NSString *best = nil; NSInteger bestN = 0;
		for (NSString *t in cl.typeCounts)
			if (cl.typeCounts[t].integerValue > bestN) { bestN = cl.typeCounts[t].integerValue; best = t; }
		UIColor *color = self.typeColors[best] ?: UIColor.grayColor;
		CGContextSetFillColorWithColor(ctx, [color colorWithAlphaComponent:0.9].CGColor);
		CGContextFillEllipseInRect(ctx, r);
		CGContextSetLineWidth(ctx, 2);
		CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.8].CGColor);
		CGContextStrokeEllipseInRect(ctx, CGRectInset(r, 1, 1));
		NSString *label = [NSString stringWithFormat:@"%ld", (long)cl.n];
		CGSize ts = [label sizeWithAttributes:textAttrs];
		[label drawAtPoint:CGPointMake(p.x - ts.width / 2, p.y - ts.height / 2) withAttributes:textAttrs];
	}

	if (self.hasUser) {
		CGPoint p = pt(self.userWorld);
		CGRect r = CGRectMake(p.x - kDotRadius, p.y - kDotRadius, 2 * kDotRadius, 2 * kDotRadius);
		CGContextSetFillColorWithColor(ctx, ALHex(0xad0149, 1).CGColor);
		CGContextFillEllipseInRect(ctx, r);
		CGContextSetLineWidth(ctx, 2);
		CGContextSetStrokeColorWithColor(ctx, ALHex(0xff6464, 1).CGColor);
		CGContextStrokeEllipseInRect(ctx, r);
	}
}

#pragma mark - Easing

// Smoothly ease visible dots toward their targets. The link only runs while
// something is still moving, then stops (no idle 60fps redraws).
- (void)startEasing {
	if (self.easeLink) return;
	self.easeLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(easeTick:)];
	[self.easeLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopEasing {
	[self.easeLink invalidate];
	self.easeLink = nil;
}

- (void)easeTick:(CADisplayLink *)link {
	BOOL moving = NO;
	const double snap = 3e-10;   // ~1e-7 degrees in world units
	for (ALPinEntry *e in self.entries.allValues) {
		CGPoint c = e.cur, t = e.target;
		if (CGPointEqualToPoint(c, t)) continue;
		if (![self.visibleIds containsObject:e.pin.identifier]) { e.cur = t; continue; }  // hidden: just jump
		c.x += (t.x - c.x) * 0.18;
		c.y += (t.y - c.y) * 0.18;
		if (fabs(t.x - c.x) < snap) c.x = t.x;
		if (fabs(t.y - c.y) < snap) c.y = t.y;
		e.cur = c;
		moving = YES;
	}
	if (moving) {
		[self.canvas setNeedsDisplay];
		[self positionPopup];   // keep an open popup on its dot
	} else {
		[self stopEasing];
	}
}

#pragma mark - Popup

// Center on a pin (zoomed in past clustering) and open its popup.
- (void)goTo:(NSString *)identifier {
	ALPinEntry *e = self.entries[identifier];
	if (!e) return;
	e.cur = e.target;
	self.navigating = YES;
	[self.map setCenterWorld:e.cur zoom:MAX(self.map.zoom, kNoClusterZoom) animated:NO];
	[self openPopupFor:identifier];
	self.navigating = NO;
}

- (void)openPopupFor:(NSString *)identifier {
	self.currentId = identifier;
	self.userPopup = NO;
	if (!self.navigating) self.navOrder = nil;   // tapped directly: a new walk starts here
	[self refreshPopup];
	[self autoPanPopup];
}

- (void)closePopup {
	self.currentId = nil;
	self.userPopup = NO;
	self.popup.hidden = YES;
}

// Popup Prev/Next: step to the next/previous closest pin to where the walk began.
- (void)navStep:(NSInteger)step {
	ALPinEntry *cur = self.entries[self.currentId];
	if (!cur) return;
	if (!self.navOrder || ![self.navOrder[self.navIdx] isEqualToString:self.currentId]) {
		CLLocationCoordinate2D from = cur.pin.coordinate;
		NSString *curId = self.currentId;
		NSMutableArray<NSDictionary *> *list = [NSMutableArray array];
		for (NSString *pid in self.entries)
			[list addObject:@{ @"id": pid, @"d": @(ALDistMeters(from, self.entries[pid].pin.coordinate)) }];
		[list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
			NSComparisonResult r = [a[@"d"] compare:b[@"d"]];
			if (r != NSOrderedSame) return r;
			if ([a[@"id"] isEqualToString:curId]) return NSOrderedAscending;
			if ([b[@"id"] isEqualToString:curId]) return NSOrderedDescending;
			return NSOrderedSame;
		}];
		self.navOrder = [list valueForKey:@"id"];
		self.navDist = [list valueForKey:@"d"];
		self.navIdx = 0;
	}
	NSInteger idx = MAX(0, MIN((NSInteger)self.navOrder.count - 1, self.navIdx + step));
	if (idx == self.navIdx) return;
	self.navIdx = idx;
	[self goTo:self.navOrder[idx]];
}

- (NSInteger)stackedCount:(ALPinEntry *)e {
	NSInteger n = 0;
	for (ALPinEntry *o in self.entries.allValues)
		if (ALDistMeters(e.pin.coordinate, o.pin.coordinate) < kStackMeters) n++;
	return n;
}

// Rebuilds the open popup's content (it scans every pin for the stacked count, so
// only while open).
- (void)refreshPopup {
	if (self.userPopup) {
		NSAttributedString *you = [[NSAttributedString alloc] initWithString:@"You" attributes:@{
			NSFontAttributeName: [UIFont systemFontOfSize:14 weight:UIFontWeightBold],
			NSForegroundColorAttributeName: UIColor.whiteColor }];
		[self.popup setText:you buttons:NO prevEnabled:NO nextEnabled:NO];
		self.popup.hidden = !self.hasUser;
		[self positionPopup];
		return;
	}
	ALPinEntry *e = self.entries[self.currentId];
	if (!e) { [self closePopup]; return; }
	ALMapPin *p = e.pin;

	UIFont *body = [UIFont systemFontOfSize:13];
	UIFont *mono = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
	UIColor *white = UIColor.whiteColor, *dim = [UIColor colorWithWhite:1 alpha:0.7];
	NSMutableAttributedString *s = [[NSMutableAttributedString alloc] init];
	void (^line)(NSString *, UIFont *, UIColor *) = ^(NSString *text, UIFont *font, UIColor *color) {
		if (s.length) [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
		[s appendAttributedString:[[NSAttributedString alloc] initWithString:text ?: @""
			attributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: color }]];
	};

	static NSDateFormatter *df;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ df = [[NSDateFormatter alloc] init]; df.dateFormat = @"d MMM yyyy HH:mm:ss"; });

	line(p.name, [UIFont systemFontOfSize:14 weight:UIFontWeightBold], white);
	line([@"Last Seen: " stringByAppendingString:[df stringFromDate:[NSDate dateWithTimeIntervalSince1970:p.lastSeen]]],
		 mono, dim);
	line(p.identifier, mono, dim);
	line([NSString stringWithFormat:@"%@ · %ld dBm", p.typeName, (long)p.rssi], body, white);
	line([NSString stringWithFormat:@"%ld obs · ~%ld m · %@", (long)p.observations, lround(p.radius), p.method],
		 body, white);
	NSInteger stacked = [self stackedCount:e];
	if (stacked > 1)
		line([NSString stringWithFormat:@"%ld dots stacked here", (long)stacked], body, ALHex(0xffd60a, 1));
	BOOL walking = self.navOrder && [self.navOrder[self.navIdx] isEqualToString:p.identifier];
	if (walking && self.navIdx > 0)
		line([NSString stringWithFormat:@"#%ld nearest · %ld m from start", (long)self.navIdx + 1,
			  lround(self.navDist[self.navIdx].doubleValue)], body, dim);

	BOOL atStart = !walking || self.navIdx == 0;
	BOOL atEnd = walking ? self.navIdx >= (NSInteger)self.navOrder.count - 1 : self.entries.count < 2;
	[self.popup setText:s buttons:YES prevEnabled:!atStart nextEnabled:!atEnd];
	self.popup.hidden = NO;
	[self positionPopup];
}

- (void)positionPopup {
	if (self.popup.hidden) return;
	CGPoint w;
	if (self.userPopup) w = self.userWorld;
	else if (self.entries[self.currentId]) w = self.entries[self.currentId].cur;
	else return;
	[self.popup placeAtAnchor:[self.map pointForWorldPoint:w]];
}

// Pan the map so a just-opened popup is fully inside the safe area.
- (void)autoPanPopup {
	if (self.popup.hidden || self.bounds.size.width <= 0) return;
	CGRect safe = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
	safe = CGRectInset(safe, 8, 8);
	CGRect f = self.popup.frame;
	CGFloat dx = 0, dy = 0;
	if (CGRectGetMinX(f) < CGRectGetMinX(safe)) dx = CGRectGetMinX(safe) - CGRectGetMinX(f);
	else if (CGRectGetMaxX(f) > CGRectGetMaxX(safe)) dx = CGRectGetMaxX(safe) - CGRectGetMaxX(f);
	if (CGRectGetMinY(f) < CGRectGetMinY(safe)) dy = CGRectGetMinY(safe) - CGRectGetMinY(f);
	else if (CGRectGetMaxY(f) > CGRectGetMaxY(safe)) dy = CGRectGetMaxY(safe) - CGRectGetMaxY(f);
	if (dx != 0 || dy != 0) [self.map panContentBy:CGPointMake(dx, dy) animated:YES];
}

@end
