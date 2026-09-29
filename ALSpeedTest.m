//
//  ALSpeedTest.m — AirLogger
//
//  Wi-Fi throughput test against Cloudflare's public speed-test endpoints
//  (speed.cloudflare.com, no API key). Runs a download phase, then an upload
//  phase; each is time-boxed so slow links finish promptly and fast links
//  aren't limited by payload size. Throughput is measured from the first byte
//  moved, so connection setup/latency doesn't drag the number down. Cellular
//  is disallowed so the result always reflects the Wi-Fi link.
//

#import "ALSpeedTest.h"
#import "ALLog.h"

static const NSTimeInterval kPhaseSeconds = 8.0;           // max duration per direction
// Big enough that most links hit the time limit first; if a fast link finishes the
// payload early, the rate is still measured correctly. Cloudflare rejects
// __down requests of 100,000,000 bytes or more with a 403, so stay under that.
static const long long kDownloadBytes = 90LL * 1000 * 1000;
static const NSUInteger kUploadBytes = 25 * 1000 * 1000;

@interface ALSpeedTest () <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionTask *task;
@property (nonatomic, strong) NSTimer *deadline;
@property (nonatomic) ALSpeedTestPhase phase;
@property (nonatomic) BOOL running;
@property (nonatomic) long long bytes;       // moved in the current phase
@property (nonatomic) CFAbsoluteTime firstByte; // 0 until the first byte moves
@property (nonatomic) double downMbps;
@end

@implementation ALSpeedTest

- (void)start {
	if (self.running) return;
	self.running = YES;
	self.downMbps = 0;
	NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
	cfg.allowsCellularAccess = NO;
	cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
	cfg.timeoutIntervalForRequest = 15;
	self.session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:[NSOperationQueue mainQueue]];
	[self beginPhase:ALSpeedTestPhaseDownload];
}

- (void)cancel {
	if (!self.running) return;
	[self finishWithError:[NSError errorWithDomain:@"ALSpeedTest" code:-1
										  userInfo:@{NSLocalizedDescriptionKey: @"Cancelled"}]];
}

- (void)beginPhase:(ALSpeedTestPhase)phase {
	self.phase = phase;
	self.bytes = 0;
	self.firstByte = 0;

	NSURLSessionTask *task;
	if (phase == ALSpeedTestPhaseDownload) {
		NSString *url = [NSString stringWithFormat:@"https://speed.cloudflare.com/__down?bytes=%lld", kDownloadBytes];
		task = [self.session dataTaskWithURL:[NSURL URLWithString:url]];
	} else {
		NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://speed.cloudflare.com/__up"]];
		req.HTTPMethod = @"POST";
		[req setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
		task = [self.session uploadTaskWithRequest:req fromData:[NSMutableData dataWithLength:kUploadBytes]];
	}
	self.task = task;
	[task resume];

	// Time-box the phase: when it expires, score what moved so far and move on.
	[self.deadline invalidate];
	self.deadline = [NSTimer scheduledTimerWithTimeInterval:kPhaseSeconds target:self
												   selector:@selector(phaseDeadline) userInfo:nil repeats:NO];
}

- (double)currentMbps {
	if (!self.firstByte) return 0;
	double secs = CFAbsoluteTimeGetCurrent() - self.firstByte;
	return secs > 0.05 ? (self.bytes * 8.0 / secs) / 1e6 : 0;
}

- (void)countBytes:(long long)n {
	if (!self.firstByte) { self.firstByte = CFAbsoluteTimeGetCurrent(); return; } // first chunk only starts the clock
	self.bytes += n;
	if (self.onProgress) self.onProgress(self.phase, [self currentMbps]);
}

- (void)phaseDeadline {
	NSURLSessionTask *t = self.task;
	[self endPhase];
	[t cancel]; // its didCompleteWithError: is ignored since self.task has moved on
}

// Records the current phase's result and starts the next one (or finishes).
- (void)endPhase {
	[self.deadline invalidate]; self.deadline = nil;
	double mbps = [self currentMbps];
	if (self.phase == ALSpeedTestPhaseDownload) {
		self.downMbps = mbps;
		[self beginPhase:ALSpeedTestPhaseUpload];
	} else {
		ALLog(@"SpeedTest: down=%.1f up=%.1f Mbps", self.downMbps, mbps);
		[self finishWithDown:self.downMbps up:mbps error:nil];
	}
}

- (void)finishWithError:(NSError *)error {
	ALLog(@"SpeedTest: failed: %@", error.localizedDescription);
	[self finishWithDown:0 up:0 error:error];
}

- (void)finishWithDown:(double)down up:(double)up error:(NSError *)error {
	[self.deadline invalidate]; self.deadline = nil;
	NSURLSessionTask *t = self.task;
	self.task = nil;
	[t cancel];
	[self.session invalidateAndCancel];
	self.session = nil;
	self.running = NO;
	if (self.onComplete) self.onComplete(down, up, error);
}

#pragma mark - NSURLSession

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)data {
	if (t != self.task) return;
	[self countBytes:(long long)data.length];
}

- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t
   didSendBodyData:(int64_t)sent totalBytesSent:(int64_t)total totalBytesExpectedToSend:(int64_t)expected {
	if (t != self.task) return;
	[self countBytes:sent];
}

- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)error {
	if (t != self.task) return; // a phase we already scored and cancelled
	if (error) { [self finishWithError:error]; return; }
	// A rejected request "completes" normally with a tiny error body, which would
	// otherwise be scored as a finished transfer at ~0 Mbps.
	NSInteger status = [t.response isKindOfClass:[NSHTTPURLResponse class]]
		? ((NSHTTPURLResponse *)t.response).statusCode : 0;
	if (status < 200 || status >= 300) {
		NSString *msg = [NSString stringWithFormat:@"%@ rejected (HTTP %ld)",
						 self.phase == ALSpeedTestPhaseDownload ? @"Download" : @"Upload", (long)status];
		[self finishWithError:[NSError errorWithDomain:@"ALSpeedTest" code:status
											  userInfo:@{NSLocalizedDescriptionKey: msg}]];
		return;
	}
	[self endPhase]; // payload finished before the deadline
}

@end
