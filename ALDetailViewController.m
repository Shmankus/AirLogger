//
//  ALDetailViewController.m — AirLogger
//
//  Per-device detail screen. Shows a header (icon, name, type, signal) and
//  grouped field sections: Identity, Signal, Speed Test (Wi-Fi, if one was run),
//  Access Points (for grouped Wi-Fi), Advertisement, and Timing.
//

#import "ALDetailViewController.h"
#import "ALDeviceCell.h"
#import "ALDatabase.h"

@interface ALDetailViewController ()
@property (nonatomic, strong) ALDevice *device;
@property (nonatomic, strong) NSArray<NSDictionary *> *groups; // @{title, rows:[[k,v]]}
@end

@implementation ALDetailViewController

- (instancetype)initWithDevice:(ALDevice *)device {
	if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
		_device = device;
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = self.device.displayName;
	self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;

	NSDateFormatter *df = [[NSDateFormatter alloc] init];
	df.dateFormat = @"HH:mm:ss";

	BOOL grouped = self.device.children.count > 0;

	NSMutableArray *identity = [NSMutableArray array];
	[identity addObject:@[@"Type", [ALDevice nameForType:self.device.type]]];
	[identity addObject:@[@"Name", self.device.displayName]];
	if (!grouped) [identity addObject:@[@"Identifier", self.device.identifier ?: @"—"]];

	NSMutableArray *signal = [NSMutableArray array];
	NSString *rssiText = grouped ? @"strongest" : @"RSSI";
	[signal addObject:@[rssiText, (self.device.rssi == 0 ? @"—" : [NSString stringWithFormat:@"%ld dBm", (long)self.device.rssi])]];
	[signal addObject:@[@"Sightings", [NSString stringWithFormat:@"%lu", (unsigned long)self.device.sightings]]];

	// Latest speed test for this AP, or for a grouped network the most recent
	// across its APs (noting which one it was run on).
	NSMutableArray *speed = [NSMutableArray array];
	if (self.device.type == ALDeviceTypeWiFi) {
		NSDictionary *latest = nil;
		NSArray<ALDevice *> *aps = grouped ? self.device.children : @[self.device];
		for (ALDevice *ap in aps) {
			NSDictionary *t = [[ALDatabase shared] speedTestForIdentifier:ap.identifier];
			if (t && (!latest || [t[@"ts"] doubleValue] > [latest[@"ts"] doubleValue])) latest = t;
		}
		if (latest) {
			NSDateFormatter *when = [[NSDateFormatter alloc] init];
			when.dateStyle = NSDateFormatterMediumStyle;
			when.timeStyle = NSDateFormatterShortStyle;
			[speed addObject:@[@"Download", [NSString stringWithFormat:@"%.1f Mbps", [latest[@"down"] doubleValue]]]];
			[speed addObject:@[@"Upload", [NSString stringWithFormat:@"%.1f Mbps", [latest[@"up"] doubleValue]]]];
			[speed addObject:@[@"Tested", [when stringFromDate:[NSDate dateWithTimeIntervalSince1970:[latest[@"ts"] doubleValue]]]]];
			if (grouped) [speed addObject:@[@"Access point", latest[@"identifier"]]];
		}
	}

	NSMutableArray *accessPoints = [NSMutableArray array];
	for (ALDevice *c in self.device.children) {
		NSString *v = (c.rssi == 0 ? @"— dBm" : [NSString stringWithFormat:@"%ld dBm", (long)c.rssi]);
		if (c.info[@"Channel"]) v = [v stringByAppendingFormat:@"  ·  ch %@", c.info[@"Channel"]];
		[accessPoints addObject:@[c.identifier ?: @"—", v]];
	}

	NSMutableArray *details = [NSMutableArray array];
	NSArray *keys = [self.device.info.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
	for (NSString *k in keys) {
		if ([k isEqualToString:@"BSSID"] || [k isEqualToString:@"UUID"] ||
			[k isEqualToString:@"Access Points"]) continue; // shown elsewhere
		[details addObject:@[k, [self.device.info[k] description]]];
	}

	NSMutableArray *timing = [NSMutableArray array];
	[timing addObject:@[@"First seen", [df stringFromDate:self.device.firstSeen]]];
	[timing addObject:@[@"Last seen", [df stringFromDate:self.device.lastSeen]]];

	NSMutableArray *groups = [NSMutableArray array];
	[groups addObject:@{@"title": @"Identity", @"rows": identity}];
	[groups addObject:@{@"title": @"Signal", @"rows": signal}];
	if (speed.count) [groups addObject:@{@"title": @"Speed Test", @"rows": speed}];
	if (accessPoints.count) [groups addObject:@{
		@"title": [NSString stringWithFormat:@"Access Points (%lu)", (unsigned long)accessPoints.count],
		@"rows": accessPoints}];
	if (details.count) [groups addObject:@{@"title": @"Advertisement", @"rows": details}];
	[groups addObject:@{@"title": @"Timing", @"rows": timing}];
	self.groups = groups;

	[self buildHeader];
}

- (void)buildHeader {
	UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 116)];

	UIView *badge = [[UIView alloc] init];
	badge.backgroundColor = [ALDeviceCell colorForType:self.device.type];
	badge.layer.cornerRadius = 16;
	badge.layer.cornerCurve = kCACornerCurveContinuous;
	badge.translatesAutoresizingMaskIntoConstraints = NO;
	[header addSubview:badge];

	UIImageView *icon = [[UIImageView alloc] init];
	icon.tintColor = [UIColor whiteColor];
	icon.contentMode = UIViewContentModeScaleAspectFit;
	NSString *sym = self.device.type == ALDeviceTypeWiFi ? @"wifi"
		: (self.device.type == ALDeviceTypeBLE ? @"dot.radiowaves.left.and.right" : @"antenna.radiowaves.left.and.right");
	UIImageConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightSemibold];
	icon.image = [UIImage systemImageNamed:sym withConfiguration:cfg];
	icon.translatesAutoresizingMaskIntoConstraints = NO;
	[badge addSubview:icon];

	UILabel *name = [[UILabel alloc] init];
	name.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
	name.textColor = [UIColor labelColor];
	name.text = self.device.displayName;
	name.numberOfLines = 2;
	name.translatesAutoresizingMaskIntoConstraints = NO;
	[header addSubview:name];

	UILabel *sub = [[UILabel alloc] init];
	sub.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
	sub.textColor = [UIColor secondaryLabelColor];
	sub.text = [NSString stringWithFormat:@"%@  ·  %@",
				[ALDevice nameForType:self.device.type],
				(self.device.rssi == 0 ? @"— dBm" : [NSString stringWithFormat:@"%ld dBm", (long)self.device.rssi])];
	sub.translatesAutoresizingMaskIntoConstraints = NO;
	[header addSubview:sub];

	[NSLayoutConstraint activateConstraints:@[
		[badge.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
		[badge.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
		[badge.widthAnchor constraintEqualToConstant:64],
		[badge.heightAnchor constraintEqualToConstant:64],
		[icon.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
		[icon.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],

		[name.leadingAnchor constraintEqualToAnchor:badge.trailingAnchor constant:16],
		[name.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],
		[name.bottomAnchor constraintEqualToAnchor:badge.centerYAnchor constant:0],
		[sub.leadingAnchor constraintEqualToAnchor:name.leadingAnchor],
		[sub.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:4],
		[sub.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],
	]];

	self.tableView.tableHeaderView = header;
}

- (void)viewDidLayoutSubviews {
	[super viewDidLayoutSubviews];
	UIView *h = self.tableView.tableHeaderView;
	if (h && h.frame.size.width != self.tableView.bounds.size.width) {
		CGRect f = h.frame;
		f.size.width = self.tableView.bounds.size.width;
		h.frame = f;
		self.tableView.tableHeaderView = h;
	}
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return self.groups.count; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
	return self.groups[s][@"title"];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
	return [self.groups[s][@"rows"] count];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
	NSArray *row = self.groups[ip.section][@"rows"][ip.row];
	cell.textLabel.text = row[0];
	cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
	cell.detailTextLabel.text = row[1];
	cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
	cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
	cell.detailTextLabel.numberOfLines = 0;
	cell.selectionStyle = UITableViewCellSelectionStyleNone;
	return cell;
}

@end
