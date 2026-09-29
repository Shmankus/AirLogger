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
#import "ALVendor.h"
#import "ALWiFiIE.h"
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
typedef void          (*WiFiAssociateCallback)(WiFiDeviceClientRef, WiFiNetworkRef, CFDictionaryRef, int, void *);
typedef void          (*WiFiDeviceClientAssociateAsync_f)(WiFiDeviceClientRef, WiFiNetworkRef, WiFiAssociateCallback, void *);
typedef CFArrayRef    (*WiFiManagerClientCopyNetworks_f)(WiFiManagerRef); // saved networks
typedef void          (*WiFiDeviceClientDisassociate_f)(WiFiDeviceClientRef);

static const NSTimeInterval kSavedRefresh = 30.0;

// Hold periodic scans this long after starting a join; off-channel scans
// during association can make it fail.
static const NSTimeInterval kJoinScanHold = 10.0;

@interface ALWiFiScanner ()
- (void)handleResults:(NSArray *)networks error:(int)error;
@end

static void ALWiFiScanCallback(WiFiDeviceClientRef device, CFArrayRef results, int error, void *token) {
	@autoreleasepool {
		ALWiFiScanner *self = (__bridge ALWiFiScanner *)token;
		[self handleResults:(__bridge NSArray *)results error:error];
	}
}

// The callback's signature is reverse-engineered, so it's only logged (context
// is NULL, nothing is dereferenced); ALWiFiJoin verifies via currentNetwork.
static void ALWiFiAssociateCallback(WiFiDeviceClientRef device, WiFiNetworkRef network,
									CFDictionaryRef info, int error, void *ctx) {
	ALLog(@"WiFi: associate callback network=%p info=%p err=%d", network, info, error);
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
	WiFiDeviceClientAssociateAsync_f        _associate;
	WiFiManagerClientCopyNetworks_f         _copyNetworks;
	WiFiDeviceClientDisassociate_f          _disassociate;
	BOOL _stopped;

	NSDictionary<NSString *, id> *_savedBySSID;  // SSID -> saved WiFiNetworkRef
	NSDate *_savedLoadedAt;

	NSDictionary<NSString *, id> *_lastNetworks; // BSSID -> WiFiNetworkRef from the last scan
	id _joiningNetwork;                          // kept alive while an association runs
	NSDate *_holdScansUntil;
}

+ (instancetype)shared {
	static ALWiFiScanner *s;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [[self alloc] init]; });
	return s;
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
		_associate   = (WiFiDeviceClientAssociateAsync_f) dlsym(_lib, "WiFiDeviceClientAssociateAsync");
		_copyNetworks = (WiFiManagerClientCopyNetworks_f) dlsym(_lib, "WiFiManagerClientCopyNetworks");
		_disassociate = (WiFiDeviceClientDisassociate_f)  dlsym(_lib, "WiFiDeviceClientDisassociate");

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
	if (_holdScansUntil && _holdScansUntil.timeIntervalSinceNow > 0) return; // joining
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

	NSMutableDictionary<NSString *, id> *byBSSID = [NSMutableDictionary dictionary];
	for (id obj in networks) {
		WiFiNetworkRef net = (__bridge WiFiNetworkRef)obj;
		if (!net) continue;
		ALDevice *dev = [self deviceFromNetwork:net];
		byBSSID[dev.identifier] = obj; // retains the network for a later join
		if (self.onDevice) self.onDevice(dev);
	}
	_lastNetworks = byBSSID;
}

- (BOOL)associateWithBSSIDs:(NSArray<NSString *> *)bssids {
	if (!_associate || !_device) return NO;
	id best = nil;
	int bestRSSI = 0;
	for (NSString *b in bssids) {
		id net = _lastNetworks[b];
		if (!net) continue;
		int r = _getRSSI ? _getRSSI((__bridge WiFiNetworkRef)net) : 0;
		if (!best || r > bestRSSI) { best = net; bestRSSI = r; }
	}
	if (!best) return NO;

	_joiningNetwork = best;
	_holdScansUntil = [NSDate dateWithTimeIntervalSinceNow:kJoinScanHold];
	ALLog(@"WiFi: associating with %@ (rssi %d)",
		  [self deviceFromNetwork:(__bridge WiFiNetworkRef)best].identifier, bestRSSI);
	_associate(_device, (__bridge WiFiNetworkRef)best, ALWiFiAssociateCallback, NULL);
	return YES;
}

#pragma mark - Saved networks

- (NSDictionary<NSString *, id> *)savedNetworks {
	if (_savedLoadedAt && -_savedLoadedAt.timeIntervalSinceNow < kSavedRefresh) return _savedBySSID;
	_savedLoadedAt = [NSDate date];
	if (!_copyNetworks || !_manager) return _savedBySSID;

	CFArrayRef list = _copyNetworks(_manager);
	NSMutableDictionary *bySSID = [NSMutableDictionary dictionary];
	for (id obj in (__bridge NSArray *)list) {
		CFStringRef s = _getSSID ? _getSSID((__bridge WiFiNetworkRef)obj) : NULL;
		if (s && CFStringGetLength(s)) bySSID[(__bridge NSString *)s] = obj;
	}
	if (list) CFRelease(list);
	if (!_savedBySSID) ALLog(@"WiFi: %lu saved network(s)", (unsigned long)bySSID.count);
	_savedBySSID = bySSID;
	return _savedBySSID;
}

- (BOOL)isSavedSSID:(NSString *)ssid {
	return ssid.length && [self savedNetworks][ssid] != nil;
}

- (BOOL)associateWithSavedSSID:(NSString *)ssid {
	id net = ssid.length ? [self savedNetworks][ssid] : nil;
	if (!_associate || !_device || !net) return NO;
	_joiningNetwork = net;
	_holdScansUntil = [NSDate dateWithTimeIntervalSinceNow:kJoinScanHold];
	ALLog(@"WiFi: associating with saved network '%@'", ssid);
	_associate(_device, (__bridge WiFiNetworkRef)net, ALWiFiAssociateCallback, NULL);
	return YES;
}

- (BOOL)disassociate {
	if (!_disassociate || !_device) return NO;
	ALLog(@"WiFi: disassociating");
	_disassociate(_device);
	return YES;
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
	// MobileWiFi's BSSID string drops leading zeros ("…:63:4"); pad it so one AP
	// always gets the same identifier and the OUI lookup works.
	if (bssid.length) bssid = [ALVendor normalizeMAC:bssid];
	if (!bssid.length) bssid = ssid.length ? [@"ssid:" stringByAppendingString:ssid] : @"(unknown)";

	ALDevice *dev = [[ALDevice alloc] init];
	dev.type = ALDeviceTypeWiFi;
	dev.identifier = bssid;
	dev.name = ssid;
	if (_getRSSI) dev.rssi = _getRSSI(net);
	dev.info[@"BSSID"] = bssid;
	NSString *vendor = [ALVendor vendorForMAC:bssid];
	if (vendor) dev.info[@"Manufacturer"] = vendor;
	else if ([ALVendor isRandomizedMAC:bssid]) dev.info[@"Manufacturer"] = @"Unknown (randomized address)";

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

	// Raw beacon elements: Wi-Fi generation, width, clients, WPS make/model, ...
	if (_getProperty) {
		CFTypeRef ie = _getProperty(net, CFSTR("IE"));
		if (ie && CFGetTypeID(ie) == CFDataGetTypeID() && CFDataGetLength(ie) > 0)
			[ALWiFiIE parseIE:(__bridge NSData *)ie into:dev.info];
	}

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
