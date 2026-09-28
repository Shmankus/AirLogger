#import "ALWiFiScanner.h"
#import "ALLog.h"
#import <dlfcn.h>

// Modern MobileWiFi API (iOS 13+). The legacy Apple80211* C API is gone.
typedef void * WiFiManagerRef;
typedef void * WiFiDeviceClientRef;
typedef void * WiFiNetworkRef;

typedef WiFiManagerRef (*WiFiManagerClientCreate_f)(CFAllocatorRef, int);
typedef void          (*WiFiManagerClientScheduleWithRunLoop_f)(WiFiManagerRef, CFRunLoopRef, CFStringRef);
typedef CFArrayRef    (*WiFiManagerClientCopyDevices_f)(WiFiManagerRef);
typedef void          (*WiFiScanCallback)(WiFiDeviceClientRef, CFArrayRef, int, void *);
typedef void          (*WiFiDeviceClientScanAsync_f)(WiFiDeviceClientRef, CFDictionaryRef, WiFiScanCallback, void *);
typedef CFStringRef   (*WiFiNetworkGetSSID_f)(WiFiNetworkRef);
typedef int           (*WiFiNetworkGetRSSI_f)(WiFiNetworkRef);
typedef int           (*WiFiNetworkGetChannel_f)(WiFiNetworkRef);
typedef CFTypeRef     (*WiFiNetworkGetProperty_f)(WiFiNetworkRef, CFStringRef);
typedef CFDataRef     (*WiFiNetworkCopyBSSIDData_f)(WiFiNetworkRef);

@interface ALWiFiScanner ()
- (void)handleResults:(NSArray *)networks error:(int)error;
@end

static void ALWiFiScanCallback(WiFiDeviceClientRef device, CFArrayRef results, int error, void *token) {
	@autoreleasepool {
		ALWiFiScanner *self = (__bridge ALWiFiScanner *)token;
		[self handleResults:(__bridge NSArray *)results error:error];
	}
}

@implementation ALWiFiScanner {
	void *_lib;
	WiFiManagerRef _manager;
	CFArrayRef _devices;
	WiFiDeviceClientRef _device;
	NSTimer *_timer;

	WiFiManagerClientCreate_f               _create;
	WiFiManagerClientScheduleWithRunLoop_f  _schedule;
	WiFiManagerClientCopyDevices_f          _copyDevices;
	WiFiDeviceClientScanAsync_f             _scanAsync;
	WiFiNetworkGetSSID_f                    _getSSID;
	WiFiNetworkGetRSSI_f                    _getRSSI;
	WiFiNetworkGetChannel_f                 _getChannel;
	WiFiNetworkGetProperty_f                _getProperty;
	WiFiNetworkCopyBSSIDData_f              _copyBSSID;
}

- (instancetype)init {
	if ((self = [super init])) {
		_lib = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_LAZY);
		if (!_lib) {
			self.status = @"MobileWiFi dlopen failed";
			return self;
		}
		_create      = (WiFiManagerClientCreate_f)              dlsym(_lib, "WiFiManagerClientCreate");
		_schedule    = (WiFiManagerClientScheduleWithRunLoop_f) dlsym(_lib, "WiFiManagerClientScheduleWithRunLoop");
		_copyDevices = (WiFiManagerClientCopyDevices_f)         dlsym(_lib, "WiFiManagerClientCopyDevices");
		_scanAsync   = (WiFiDeviceClientScanAsync_f)            dlsym(_lib, "WiFiDeviceClientScanAsync");
		_getSSID     = (WiFiNetworkGetSSID_f)                   dlsym(_lib, "WiFiNetworkGetSSID");
		_getRSSI     = (WiFiNetworkGetRSSI_f)                   dlsym(_lib, "WiFiNetworkGetRSSI");
		_getChannel  = (WiFiNetworkGetChannel_f)               dlsym(_lib, "WiFiNetworkGetChannel");
		_getProperty = (WiFiNetworkGetProperty_f)              dlsym(_lib, "WiFiNetworkGetProperty");
		_copyBSSID   = (WiFiNetworkCopyBSSIDData_f)            dlsym(_lib, "WiFiNetworkCopyBSSIDData");

		ALLog(@"WiFi: create=%p sched=%p copyDev=%p scan=%p getSSID=%p",
			  _create, _schedule, _copyDevices, _scanAsync, _getSSID);

		if (!(_create && _copyDevices && _scanAsync)) {
			self.status = @"WiFiManager symbols missing";
			return self;
		}

		_manager = _create(kCFAllocatorDefault, 0);
		if (_manager && _schedule) {
			_schedule(_manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
		}
		_devices = _manager ? _copyDevices(_manager) : NULL;
		if (_devices && CFArrayGetCount(_devices) > 0) {
			_device = (WiFiDeviceClientRef)CFArrayGetValueAtIndex(_devices, 0);
		}
		ALLog(@"WiFi: manager=%p devices=%ld device=%p",
			  _manager, _devices ? CFArrayGetCount(_devices) : -1, _device);
		self.status = _device ? @"ready" : @"no wifi device";
	}
	return self;
}

- (BOOL)available { return (_device != NULL && _scanAsync != NULL); }

- (void)start {
	if (!self.available) {
		ALLog(@"WiFi: unavailable, not starting. status=%@", self.status);
		return;
	}
	[self scanOnce];
	_timer = [NSTimer scheduledTimerWithTimeInterval:6.0
											  target:self
											selector:@selector(scanOnce)
											userInfo:nil
											 repeats:YES];
}

- (void)stop {
	[_timer invalidate];
	_timer = nil;
}

- (void)scanOnce {
	if (!self.available) return;
	NSDictionary *opts = @{};
	_scanAsync(_device, (__bridge CFDictionaryRef)opts, ALWiFiScanCallback, (__bridge void *)self);
}

- (void)handleResults:(NSArray *)networks error:(int)error {
	if (error != 0 || networks == nil) {
		self.status = [NSString stringWithFormat:@"scan err=%d", error];
		ALLog(@"WiFi: scan callback err=%d", error);
		return;
	}
	self.status = [NSString stringWithFormat:@"OK, %lu networks", (unsigned long)networks.count];
	ALLog(@"WiFi: %lu networks", (unsigned long)networks.count);

	for (id obj in networks) {
		WiFiNetworkRef net = (__bridge WiFiNetworkRef)obj;
		if (!net) continue;

		NSString *ssid = nil;
		if (_getSSID) {
			CFStringRef s = _getSSID(net);
			if (s) ssid = (__bridge NSString *)s;
		}

		NSString *bssid = nil;
		if (_getProperty) {
			CFTypeRef b = _getProperty(net, CFSTR("BSSID"));
			if (b && CFGetTypeID(b) == CFStringGetTypeID()) bssid = (__bridge NSString *)b;
		}
		if (!bssid.length && _copyBSSID) {
			CFDataRef d = _copyBSSID(net);
			if (d) {
				const uint8_t *b = CFDataGetBytePtr(d);
				CFIndex n = CFDataGetLength(d);
				if (n == 6) bssid = [NSString stringWithFormat:@"%02x:%02x:%02x:%02x:%02x:%02x",
									 b[0], b[1], b[2], b[3], b[4], b[5]];
				CFRelease(d);
			}
		}
		if (!bssid.length) bssid = ssid.length ? [@"ssid:" stringByAppendingString:ssid] : @"(unknown)";

		ALDevice *dev = [[ALDevice alloc] init];
		dev.type = ALDeviceTypeWiFi;
		dev.identifier = bssid;
		dev.name = ssid;
		if (_getRSSI)    dev.rssi = _getRSSI(net);
		if (_getChannel) dev.info[@"Channel"] = [NSString stringWithFormat:@"%d", _getChannel(net)];
		dev.info[@"BSSID"] = bssid;

		if (self.onDevice) self.onDevice(dev);
	}
}

- (void)dealloc {
	[self stop];
	if (_devices) CFRelease(_devices);
	if (_lib) dlclose(_lib);
}

@end
