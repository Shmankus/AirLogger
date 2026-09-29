//
//  ALBluetoothScanner.m — AirLogger
//
//  Bluetooth scanner. Discovers classic Bluetooth devices via the private
//  BluetoothManager framework (requires the privileged bluetooth.* entitlements),
//  and BLE advertisements via CoreBluetooth using the privileged-daemon options.
//

#import "ALBluetoothScanner.h"
#import "ALLog.h"
#import "ALVendor.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import <dlfcn.h>
#import <objc/message.h>

@interface ALBluetoothScanner () <CBCentralManagerDelegate>
@property (nonatomic, strong) CBCentralManager *central;
@property (nonatomic, strong) id btManager; // private BluetoothManager (classic)
@property (nonatomic, strong) NSTimer *hbTimer;
@property (nonatomic) NSUInteger bleSeen;
@end

@implementation ALBluetoothScanner

// bluetoothd treats this ad-hoc-signed app's session as backgrounded (FG:0), and
// a background scan with no service filter gets no results. Sessions flagged as a
// privileged daemon (DMN:1) are exempt from that. The keys are private CoreBluetooth
// exports, so resolve them at runtime.
static NSString *ALCBKey(const char *sym) {
	NSString *__unsafe_unretained *p = (NSString *__unsafe_unretained *)dlsym(RTLD_DEFAULT, sym);
	return p ? *p : nil;
}

- (NSDictionary *)centralInitOptions {
	NSString *k = ALCBKey("CBManagerIsPrivilegedDaemonKey");
	ALLog(@"BLE: CBManagerIsPrivilegedDaemonKey = %@", k);
	return k ? @{ k: @YES } : nil;
}

- (NSDictionary *)scanOptions {
	NSMutableDictionary *o = [@{ CBCentralManagerScanOptionAllowDuplicatesKey: @YES } mutableCopy];
	NSString *k = ALCBKey("CBCentralManagerScanOptionIsPrivilegedDaemonKey");
	if (k) o[k] = @YES;
	return o;
}

- (void)start {
	// --- BLE via public CoreBluetooth --- (reuse the central across pause/resume)
	if (!self.central) {
		self.central = [[CBCentralManager alloc] initWithDelegate:self queue:nil options:[self centralInitOptions]];
	} else if (self.central.state == CBManagerStatePoweredOn && !self.central.isScanning) {
		[self.central scanForPeripheralsWithServices:nil options:[self scanOptions]];
	}

	// Live heartbeat so the status reflects the real scan state, not just discoveries.
	if (!self.hbTimer) {
		self.hbTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
														target:self
													  selector:@selector(heartbeat)
													  userInfo:nil
													   repeats:YES];
	}

	// --- Classic BT via private BluetoothManager (best-effort) ---
	[self startClassic];
}

- (void)heartbeat {
	NSInteger auth = -1;
	if (@available(iOS 13.0, *)) auth = (NSInteger)CBCentralManager.authorization;
	self.bleStatus = [NSString stringWithFormat:@"state=%ld auth=%ld scanning=%d seen=%lu",
					  (long)self.central.state, (long)auth,
					  self.central.isScanning, (unsigned long)self.bleSeen];
}

- (void)stop {
	[self.hbTimer invalidate];
	self.hbTimer = nil;
	[self.central stopScan];
	if (self.btManager) {
		[[NSNotificationCenter defaultCenter] removeObserver:self];
		[self sendBool:NO selector:@selector(setDeviceScanningEnabled:)];
	}
}

// BluetoothManager's setters take a BOOL, not an object. performSelector:withObject:
// would pass a pointer that gets read as an arbitrary BOOL (e.g. @YES read as NO,
// which switched Bluetooth off on resume), so call through a correctly typed msgSend.
- (void)sendBool:(BOOL)value selector:(SEL)sel {
	if (![self.btManager respondsToSelector:sel]) return;
	((void (*)(id, SEL, BOOL))objc_msgSend)(self.btManager, sel, value);
}

#pragma mark - BLE

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
	// states: 0 unknown, 1 resetting, 2 unsupported, 3 unauthorized, 4 poweredOff, 5 poweredOn
	ALLog(@"BLE: centralManagerDidUpdateState = %ld", (long)central.state);
	if (@available(iOS 13.0, *)) {
		ALLog(@"BLE: authorization = %ld", (long)CBCentralManager.authorization);
	}
	NSInteger auth = -1;
	if (@available(iOS 13.0, *)) auth = (NSInteger)CBCentralManager.authorization;
	if (central.state == CBManagerStatePoweredOn) {
		NSDictionary *opts = [self scanOptions];
		ALLog(@"BLE: scan options %@", opts);
		[central scanForPeripheralsWithServices:nil options:opts];
		ALLog(@"BLE: scanForPeripherals started, isScanning=%d", central.isScanning);
		self.bleStatus = [NSString stringWithFormat:@"scanning (auth=%ld)", (long)auth];
	} else {
		ALLog(@"BLE: not powered on (state %ld) - need powered-on + permission.", (long)central.state);
		NSString *meaning = @"?";
		switch (central.state) {
			case 0: meaning = @"unknown"; break;
			case 1: meaning = @"resetting"; break;
			case 2: meaning = @"unsupported"; break;
			case 3: meaning = @"UNAUTHORIZED"; break;
			case 4: meaning = @"poweredOff"; break;
			case 5: meaning = @"poweredOn"; break;
		}
		self.bleStatus = [NSString stringWithFormat:@"state=%ld %@ (auth=%ld)", (long)central.state, meaning, (long)auth];
	}
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
	 advertisementData:(NSDictionary<NSString *, id> *)adv
				  RSSI:(NSNumber *)RSSI {

	ALDevice *d = [[ALDevice alloc] init];
	d.type = ALDeviceTypeBLE;
	d.identifier = peripheral.identifier.UUIDString;
	d.name = adv[CBAdvertisementDataLocalNameKey] ?: peripheral.name;
	d.rssi = RSSI.integerValue;

	NSString *localName = adv[CBAdvertisementDataLocalNameKey];
	if (localName) d.info[@"Local Name"] = localName;

	NSNumber *connectable = adv[CBAdvertisementDataIsConnectable];
	if (connectable) d.info[@"Connectable"] = connectable.boolValue ? @"Yes" : @"No";

	NSNumber *txPower = adv[CBAdvertisementDataTxPowerLevelKey];
	if (txPower) d.info[@"Tx Power"] = [NSString stringWithFormat:@"%@ dBm", txPower];

	NSData *mfg = adv[CBAdvertisementDataManufacturerDataKey];
	if (mfg.length) {
		d.info[@"Manufacturer Data"] = [self hex:mfg];
		if (mfg.length >= 2) {
			const uint8_t *b = mfg.bytes;
			uint16_t companyID = b[0] | (b[1] << 8); // little-endian
			d.info[@"Company ID"] = [NSString stringWithFormat:@"0x%04X", companyID];
			NSString *company = [ALVendor companyNameForID:companyID];
			if (company) d.info[@"Manufacturer"] = company;
		}
	}

	NSArray *uuids = adv[CBAdvertisementDataServiceUUIDsKey];
	if (uuids.count) {
		NSMutableArray *s = [NSMutableArray array];
		for (CBUUID *u in uuids) [s addObject:u.UUIDString];
		d.info[@"Service UUIDs"] = [s componentsJoinedByString:@", "];
	}

	NSDictionary *svcData = adv[CBAdvertisementDataServiceDataKey];
	if (svcData.count) {
		NSMutableArray *s = [NSMutableArray array];
		[svcData enumerateKeysAndObjectsUsingBlock:^(CBUUID *k, NSData *v, BOOL *stop) {
			[s addObject:[NSString stringWithFormat:@"%@=%@", k.UUIDString, [self hex:v]]];
		}];
		d.info[@"Service Data"] = [s componentsJoinedByString:@"\n"];
	}

	d.info[@"UUID"] = d.identifier;

	self.bleSeen++;
	if (self.bleSeen <= 5 || self.bleSeen % 25 == 0)
		ALLog(@"BLE: discovered #%lu name=%@ rssi=%ld", (unsigned long)self.bleSeen, d.displayName, (long)d.rssi);

	if (self.onDevice) self.onDevice(d);
}

#pragma mark - Classic

- (void)startClassic {
	void *lib = dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_LAZY);
	Class BM = NSClassFromString(@"BluetoothManager");
	ALLog(@"Classic: BluetoothManager lib=%p class=%@", lib, BM);
	if (!BM) {
		ALLog(@"Classic: BluetoothManager unavailable (%s), dlerror=%s",
			  lib ? "loaded, no class" : "not loaded", dlerror() ?: "(none)");
		self.classicStatus = lib ? @"class missing" : @"dlopen failed";
		return;
	}
	self.classicStatus = @"BluetoothManager loaded";
	self.btManager = [BM performSelector:@selector(sharedInstance)];

	// Remove first so resuming after a pause can't register a duplicate observer.
	[[NSNotificationCenter defaultCenter] removeObserver:self
													name:@"BluetoothDeviceDiscoveredNotification"
												  object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(classicDiscovered:)
												 name:@"BluetoothDeviceDiscoveredNotification"
											   object:nil];

	// Only power the radio on if it's off; never touch it otherwise.
	BOOL powered = YES;
	if ([self.btManager respondsToSelector:@selector(powered)])
		powered = ((BOOL (*)(id, SEL))objc_msgSend)(self.btManager, @selector(powered));
	if (!powered) [self sendBool:YES selector:@selector(setPowered:)];

	// Give the radio a moment to power on, then start inquiry.
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[self sendBool:YES selector:@selector(setDeviceScanningEnabled:)];
	});
}

- (void)classicDiscovered:(NSNotification *)note {
	id dev = note.object;
	if (!dev) return;

	ALDevice *d = [[ALDevice alloc] init];
	d.type = ALDeviceTypeClassicBT;

	NSString *addr = [self safeString:dev key:@"address"];
	d.identifier = addr.length ? addr : [[NSUUID UUID] UUIDString];
	d.name = [self safeString:dev key:@"name"];

	id rssi = [self safeValue:dev key:@"RSSI"];
	if ([rssi respondsToSelector:@selector(integerValue)]) d.rssi = [rssi integerValue];

	if (addr.length) d.info[@"Address"] = addr;
	NSString *vendor = [ALVendor vendorForMAC:addr];
	if (vendor) d.info[@"Manufacturer"] = vendor;
	NSString *major = [self safeString:dev key:@"majorClassName"];
	if (major.length) d.info[@"Major Class"] = major;
	NSString *minor = [self safeString:dev key:@"minorClassName"];
	if (minor.length) d.info[@"Minor Class"] = minor;

	// Richer fields exposed by BluetoothDevice.
	id connected = [self safeValue:dev key:@"connected"];
	if (connected) d.info[@"Connected"] = [connected boolValue] ? @"Yes" : @"No";
	id paired = [self safeValue:dev key:@"paired"];
	if (paired) d.info[@"Paired"] = [paired boolValue] ? @"Yes" : @"No";
	NSString *product = [self safeString:dev key:@"productName"];
	if (product.length) d.info[@"Product"] = product;
	id vid = [self safeValue:dev key:@"vendorId"];
	if ([vid respondsToSelector:@selector(intValue)] && [vid intValue])
		d.info[@"Vendor ID"] = [NSString stringWithFormat:@"0x%04X", [vid intValue]];
	id pid = [self safeValue:dev key:@"productId"];
	if ([pid respondsToSelector:@selector(intValue)] && [pid intValue])
		d.info[@"Product ID"] = [NSString stringWithFormat:@"0x%04X", [pid intValue]];
	id appleAudio = [self safeValue:dev key:@"isAppleAudioDevice"];
	if ([appleAudio boolValue]) d.info[@"Apple Audio"] = @"Yes";
	id supportsBatt = [self safeValue:dev key:@"supportsBatteryLevel"];
	if ([supportsBatt boolValue]) {
		id batt = [self safeValue:dev key:@"batteryLevel"];
		if (batt) d.info[@"Battery"] = [batt description];
	}

	if (self.onDevice) self.onDevice(d);
}

#pragma mark - Helpers

- (id)safeValue:(id)obj key:(NSString *)key {
	@try { return [obj valueForKey:key]; }
	@catch (__unused NSException *e) { return nil; }
}

- (NSString *)safeString:(id)obj key:(NSString *)key {
	id v = [self safeValue:obj key:key];
	if ([v isKindOfClass:[NSString class]]) return v;
	if (v) return [v description];
	return nil;
}

- (NSString *)hex:(NSData *)data {
	const uint8_t *b = data.bytes;
	NSMutableString *s = [NSMutableString stringWithCapacity:data.length * 2];
	for (NSUInteger i = 0; i < data.length; i++) [s appendFormat:@"%02X", b[i]];
	return s;
}

@end
