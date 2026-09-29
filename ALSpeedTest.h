#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, ALSpeedTestPhase) {
	ALSpeedTestPhaseDownload,
	ALSpeedTestPhaseUpload,
};

@interface ALSpeedTest : NSObject
// Live progress: current phase and its running throughput in Mbps. Main queue.
@property (nonatomic, copy) void (^onProgress)(ALSpeedTestPhase phase, double mbps);
// Finished (or failed): Mbps for each direction, or error. Main queue.
@property (nonatomic, copy) void (^onComplete)(double downMbps, double upMbps, NSError *error);
@property (nonatomic, readonly) BOOL running;
- (void)start;
- (void)cancel;
@end
