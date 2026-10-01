//
//  ALPinOverlayView.h — AirLogger
//
//  Device pins on an ALTileMapView (native port of what map.html did): dots drawn
//  on one canvas, hierarchical clusters, viewport culling, eased movement, and a
//  popup with Prev/Next and "View Details". Becomes the map view's delegate.
//

#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import "ALTileMapView.h"

// One device's estimated position, as computed by ALMapViewController.
@interface ALMapPin : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *typeName;
@property (nonatomic, copy) NSString *method;      // "multilateration" / "centroid"
@property (nonatomic, strong) UIColor *color;
@property (nonatomic) CLLocationCoordinate2D coordinate;
@property (nonatomic) NSInteger rssi;
@property (nonatomic) NSInteger observations;
@property (nonatomic) double radius;               // metres
@property (nonatomic) double lastSeen;             // unix time
@end

@class ALPinOverlayView;

@protocol ALPinOverlayDelegate <NSObject>
- (void)pinOverlay:(ALPinOverlayView *)overlay showDetailForIdentifier:(NSString *)identifier;
@end

@interface ALPinOverlayView : UIView <ALTileMapViewDelegate>
- (instancetype)initWithMapView:(ALTileMapView *)map;
@property (nonatomic, weak) id<ALPinOverlayDelegate> delegate;
// NO = fit the view to the pins (near the user) on the next update.
@property (nonatomic) BOOL didFit;
- (void)updateUser:(CLLocation *)user pins:(NSArray<ALMapPin *> *)pins;
// Centers on a pin (zoomed in past clustering) and opens its popup.
- (void)focusPin:(NSString *)identifier;
@end
