#import <Foundation/Foundation.h>

// Simple file logger. Writes to the app container's Documents/airlogger.log,
// because iOS has no `log` CLI to read os_log/NSLog over SSH.
static inline void ALLog(NSString *fmt, ...) {
	va_list args;
	va_start(args, fmt);
	NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
	va_end(args);

	static NSDateFormatter *df;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		df = [[NSDateFormatter alloc] init];
		df.dateFormat = @"HH:mm:ss.SSS";
	});

	NSString *line = [NSString stringWithFormat:@"%@  %@\n", [df stringFromDate:[NSDate date]], msg];

	// /var/mobile/Library/AirLogger is writable (the sandbox denies our container).
	static NSString *path;
	static dispatch_once_t once2;
	dispatch_once(&once2, ^{
		[[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Library/AirLogger"
								  withIntermediateDirectories:YES attributes:nil error:nil];
		path = @"/var/mobile/Library/AirLogger/airlogger.log";
	});
	FILE *f = fopen(path.UTF8String, "a");
	if (f) { fputs(line.UTF8String, f); fclose(f); }
	NSLog(@"[AirLogger] %@", msg);
}
