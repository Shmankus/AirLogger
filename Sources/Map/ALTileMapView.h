//
//  ALTileMapView.h — AirLogger
//
//  Native slippy map: OSM raster tiles (dark-filtered) with pan / pinch / double-tap
//  zoom. Replaces the Leaflet WKWebView, which can't run where WebKit's WebContent
//  process won't launch for jailbreak-installed apps (iOS 17 + Dopamine).
//

#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

// World coordinates are normalized Web Mercator: (0,0) = top-left, (1,1) = bottom-right.
// At zoom z the world is 256 * 2^z points wide (same scale as Leaflet's).
CGPoint ALWorldPointForCoordinate(CLLocationCoordinate2D c);

@class ALTileMapView;

@protocol ALTileMapViewDelegate <NSObject>
@optional
// Every step of a gesture or animation — keep this cheap.
- (void)mapViewCameraDidChange:(ALTileMapView *)map;
// A pan/zoom finished or the camera was set (Leaflet's `moveend`).
- (void)mapViewCameraDidSettle:(ALTileMapView *)map;
- (void)mapView:(ALTileMapView *)map didTapAtPoint:(CGPoint)point;
@end

@interface ALTileMapView : UIView
@property (nonatomic, weak) id<ALTileMapViewDelegate> delegate;
@property (nonatomic, readonly) CGPoint centerWorld;
@property (nonatomic, readonly) double zoom;
@property (nonatomic, readonly) double pointsPerWorld;   // 256 * 2^zoom

- (void)setCenterWorld:(CGPoint)center zoom:(double)zoom animated:(BOOL)animated;
// Fits a world rect inside the safe area minus `padding`, snapped down to a whole zoom.
- (void)fitWorldRect:(CGRect)rect padding:(CGFloat)padding maxZoom:(double)maxZoom animated:(BOOL)animated;
// Moves the map content by `delta` points (positive x = content moves right).
- (void)panContentBy:(CGPoint)delta animated:(BOOL)animated;

- (CGPoint)pointForWorldPoint:(CGPoint)w;
- (CGPoint)worldPointForPoint:(CGPoint)p;
@end
