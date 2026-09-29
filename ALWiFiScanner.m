//
//  ALWiFiScanner.m — AirLogger
//
//  Wi-Fi scanner. Drives the private MobileWiFi (WiFiManagerClient /
//  WiFiDeviceClient) API — resolved at runtime with dlopen/dlsym — to run
//  periodic async scans and report SSID, BSSID, RSSI, channel, band, and
//  security for each nearby access point.
//

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
typedef CFNumberRef   (*WiFiNetworkGetChannel_f)(WiFiNetworkRef); // a CFNumber, NOT an int
typedef CFTypeRef     (*WiFiNetworkGetProperty_f)(WiFiNetworkRef, CFStringRef);
typedef CFDataRef     (*WiFiNetworkCopyBSSIDData_f)(WiFiNetworkRef);
typedef bool          (*WiFiNetworkBool_f)(WiFiNetworkRef);
typedef WiFiNetworkRef (*WiFiDeviceClientCopyCurrentNetwork_f)(WiFiDeviceClientRef);

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
	WiFiDeviceClientCopyCurrentNetwork_f    _copyCurrent;
	WiFiNetworkBool_f _isWEP, _isWPA, _isSAE, _isEAP, _isWAPI, _isHidden;
	BOOL _stopped;
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
		_copyCurrent = (WiFiDeviceClientCopyCurrentNetwork_f)  dlsym(_lib, "WiFiDeviceClientCopyCurrentNetwork");
		_isWEP       = (WiFiNetworkBool_f) dlsym(_lib, "WiFiNetworkIsWEP");
		_isWPA       = (WiFiNetworkBool_f) dlsym(_lib, "WiFiNetworkIsWPA");
		_isSAE       = (WiFiNetworkBool_f) dlsym(_lib, "WiFiNetworkIsSAE");
		_isEAP       = (WiFiNetworkBool_f) dlsym(_lib, "WiFiNetworkIsEAP");
		_isWAPI      = (WiFiNetworkBool_f) dlsym(_lib, "WiFiNetworkIsWAPI");
		_isHidden    = (WiFiNetworkBool_f) dlsym(_lib, "WiFiNetworkIsHidden");

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
	_stopped = NO;
	[self scanOnce];
	[_timer invalidate]; // start may be called while already running
	_timer = [NSTimer scheduledTimerWithTimeInterval:6.0
											  target:self
											selector:@selector(scanOnce)
											userInfo:nil
											 repeats:YES];
}

- (void)stop {
	_stopped = YES;   // ignore any async scan callback that lands after this
	[_timer invalidate];
	_timer = nil;
}

- (void)scanOnce {
	if (_stopped || !self.available) return;
	NSDictionary *opts = @{};
	_scanAsync(_device, (__bridge CFDictionaryRef)opts, ALWiFiScanCallback, (__bridge void *)self);
}

- (void)handleResults:(NSArray *)networks error:(int)error {
	if (_stopped) return;
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
		ALDevice *dev = [self deviceFromNetwork:net];
		if (self.onDevice) self.onDevice(dev);
	}
}

- (ALDevice *)currentNetwork {
	if (!_device || !_copyCurrent) return nil;
	WiFiNetworkRef net = _copyCurrent(_device);
	if (!net) return nil;
	ALDevice *dev = [self deviceFromNetwork:net];
	CFRelease(net);
	return dev;
}

- (ALDevice *)deviceFromNetwork:(WiFiNetworkRef)net {
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
	if (_getRSSI) dev.rssi = _getRSSI(net);
	dev.info[@"BSSID"] = bssid;

	// The channel comes back as a CFNumber. It used to be read as a plain int,
	// which stored the object's address and made every channel and band garbage.
	int channel = 0;
	CFTypeRef ch = _getProperty ? _getProperty(net, CFSTR("CHANNEL")) : NULL;
	if (!ch && _getChannel) ch = _getChannel(net);
	if (ch && CFGetTypeID(ch) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)ch, kCFNumberIntType, &channel);
	if (channel > 0) {
		dev.info[@"Channel"] = [NSString stringWithFormat:@"%d", channel];
		// 2.4 GHz is channels 1-14, anything higher is 5 GHz. (6 GHz reuses the same
		// channel numbers, but this device's radio can't see 6 GHz anyway.)
		dev.info[@"Band"] = (channel <= 14) ? @"2.4 GHz" : @"5 GHz";
	}

	// Security type from the dedicated MobileWiFi predicates.
	NSString *sec = @"Open";
	if (_isSAE && _isSAE(net))       sec = @"WPA3";
	else if (_isWPA && _isWPA(net))  sec = @"WPA/WPA2";
	else if (_isWEP && _isWEP(net))  sec = @"WEP";
	else if (_isWAPI && _isWAPI(net)) sec = @"WAPI";
	if (_isEAP && _isEAP(net))       sec = [sec stringByAppendingString:@" (Enterprise)"];
	dev.info[@"Security"] = sec;

	if (_isHidden && _isHidden(net)) dev.info[@"Hidden"] = @"Yes";

	// SNR from RSSI - noise floor.
	if (_getProperty) {
		CFTypeRef nz = _getProperty(net, CFSTR("NOISE"));
		if (nz && CFGetTypeID(nz) == CFNumberGetTypeID()) {
			int noise = 0; CFNumberGetValue(nz, kCFNumberIntType, &noise);
			if (noise) dev.info[@"SNR"] = [NSString stringWithFormat:@"%ld dB", (long)(dev.rssi - noise)];
		}
	}

	return dev;
}

- (void)dealloc {
	[self stop];
	if (_devices) CFRelease(_devices);
	// Intentionally do NOT dlclose(_lib): MobileWiFi may still hold run-loop
	// sources/callbacks, and unloading it out from under them crashes.
}

@end
