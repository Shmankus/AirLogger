//
//  ALDeviceCell.m — AirLogger
//
//  Custom table cell for a device row: colored type-icon badge, name, monospaced
//  identifier, a meta line, and a color-coded RSSI pill with sighting count.
//  Open (passwordless) Wi-Fi gets a green unlocked-padlock next to its name, and
//  secured Wi-Fi saved in Settings a blue key (both joinable from the app).
//  Also vends the shared type/RSSI color helpers used across the UI and map.
//

#import "ALDeviceCell.h"
#import "ALWiFiJoin.h"

@interface ALDeviceCell ()
@property (nonatomic, strong) UIView *iconBadge;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UIImageView *openIcon;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *metaLabel;
@property (nonatomic, strong) UIView *rssiPill;
@property (nonatomic, strong) UILabel *rssiLabel;
@property (nonatomic, strong) UILabel *sightingsLabel;
@end

@implementation ALDeviceCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
	if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
		self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

		_iconBadge = [[UIView alloc] init];
		_iconBadge.layer.cornerRadius = 9;
		_iconBadge.layer.cornerCurve = kCACornerCurveContinuous;
		_iconBadge.translatesAutoresizingMaskIntoConstraints = NO;

		_iconView = [[UIImageView alloc] init];
		_iconView.contentMode = UIViewContentModeScaleAspectFit;
		_iconView.tintColor = [UIColor whiteColor];
		_iconView.translatesAutoresizingMaskIntoConstraints = NO;
		[_iconBadge addSubview:_iconView];

		_nameLabel = [[UILabel alloc] init];
		_nameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
		_nameLabel.textColor = [UIColor labelColor];
		_nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
		[_nameLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

		_openIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"lock.open.fill"
			withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold]]];
		_openIcon.tintColor = [UIColor systemGreenColor];
		_openIcon.translatesAutoresizingMaskIntoConstraints = NO;
		[_openIcon setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

		_subtitleLabel = [[UILabel alloc] init];
		_subtitleLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
		_subtitleLabel.textColor = [UIColor secondaryLabelColor];
		_subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

		_metaLabel = [[UILabel alloc] init];
		_metaLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
		_metaLabel.textColor = [UIColor tertiaryLabelColor];
		_metaLabel.translatesAutoresizingMaskIntoConstraints = NO;

		_rssiPill = [[UIView alloc] init];
		_rssiPill.layer.cornerRadius = 8;
		_rssiPill.layer.cornerCurve = kCACornerCurveContinuous;
		_rssiPill.translatesAutoresizingMaskIntoConstraints = NO;
		[_rssiPill setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

		_rssiLabel = [[UILabel alloc] init];
		_rssiLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightBold];
		_rssiLabel.textColor = [UIColor whiteColor];
		_rssiLabel.textAlignment = NSTextAlignmentCenter;
		_rssiLabel.translatesAutoresizingMaskIntoConstraints = NO;
		[_rssiPill addSubview:_rssiLabel];

		_sightingsLabel = [[UILabel alloc] init];
		_sightingsLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
		_sightingsLabel.textColor = [UIColor tertiaryLabelColor];
		_sightingsLabel.textAlignment = NSTextAlignmentCenter;
		_sightingsLabel.translatesAutoresizingMaskIntoConstraints = NO;

		UIView *c = self.contentView;
		[c addSubview:_iconBadge];
		[c addSubview:_nameLabel];
		[c addSubview:_openIcon];
		[c addSubview:_subtitleLabel];
		[c addSubview:_metaLabel];
		[c addSubview:_rssiPill];
		[c addSubview:_sightingsLabel];

		[NSLayoutConstraint activateConstraints:@[
			[_iconBadge.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:16],
			[_iconBadge.centerYAnchor constraintEqualToAnchor:c.centerYAnchor],
			[_iconBadge.widthAnchor constraintEqualToConstant:34],
			[_iconBadge.heightAnchor constraintEqualToConstant:34],
			[_iconView.centerXAnchor constraintEqualToAnchor:_iconBadge.centerXAnchor],
			[_iconView.centerYAnchor constraintEqualToAnchor:_iconBadge.centerYAnchor],
			[_iconView.widthAnchor constraintEqualToConstant:19],
			[_iconView.heightAnchor constraintEqualToConstant:19],

			[_nameLabel.leadingAnchor constraintEqualToAnchor:_iconBadge.trailingAnchor constant:12],
			[_nameLabel.topAnchor constraintEqualToAnchor:c.topAnchor constant:10],
			[_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_rssiPill.leadingAnchor constant:-10],
			[_openIcon.leadingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor constant:5],
			[_openIcon.centerYAnchor constraintEqualToAnchor:_nameLabel.centerYAnchor],
			[_openIcon.trailingAnchor constraintLessThanOrEqualToAnchor:_rssiPill.leadingAnchor constant:-10],

			[_subtitleLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
			[_subtitleLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
			[_subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_rssiPill.leadingAnchor constant:-10],

			[_metaLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
			[_metaLabel.topAnchor constraintEqualToAnchor:_subtitleLabel.bottomAnchor constant:2],
			[_metaLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_rssiPill.leadingAnchor constant:-10],
			[_metaLabel.bottomAnchor constraintEqualToAnchor:c.bottomAnchor constant:-10],

			[_rssiPill.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-6],
			[_rssiPill.topAnchor constraintEqualToAnchor:c.topAnchor constant:12],
			[_rssiPill.widthAnchor constraintGreaterThanOrEqualToConstant:52],
			[_rssiPill.heightAnchor constraintEqualToConstant:26],
			[_rssiLabel.leadingAnchor constraintEqualToAnchor:_rssiPill.leadingAnchor constant:8],
			[_rssiLabel.trailingAnchor constraintEqualToAnchor:_rssiPill.trailingAnchor constant:-8],
			[_rssiLabel.centerYAnchor constraintEqualToAnchor:_rssiPill.centerYAnchor],

			[_sightingsLabel.centerXAnchor constraintEqualToAnchor:_rssiPill.centerXAnchor],
			[_sightingsLabel.topAnchor constraintEqualToAnchor:_rssiPill.bottomAnchor constant:3],
		]];
	}
	return self;
}

+ (UIColor *)colorForType:(ALDeviceType)type {
	switch (type) {
		case ALDeviceTypeWiFi:      return [UIColor systemBlueColor];
		case ALDeviceTypeBLE:       return [UIColor systemIndigoColor];
		case ALDeviceTypeClassicBT: return [UIColor systemTealColor];
	}
	return [UIColor systemGrayColor];
}

+ (NSString *)symbolForType:(ALDeviceType)type {
	switch (type) {
		case ALDeviceTypeWiFi:      return @"wifi";
		case ALDeviceTypeBLE:       return @"dot.radiowaves.left.and.right";
		case ALDeviceTypeClassicBT: return @"antenna.radiowaves.left.and.right";
	}
	return @"questionmark";
}

+ (UIColor *)colorForRSSI:(NSInteger)rssi {
	if (rssi == 0)        return [UIColor systemGrayColor];
	if (rssi >= -60)      return [UIColor systemGreenColor];
	if (rssi >= -72)      return [UIColor colorWithRed:0.60 green:0.73 blue:0.20 alpha:1.0];
	if (rssi >= -84)      return [UIColor systemOrangeColor];
	return [UIColor systemRedColor];
}

- (void)configureWithDevice:(ALDevice *)d {
	self.iconBadge.backgroundColor = [ALDeviceCell colorForType:d.type];
	UIImageConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
	self.iconView.image = [UIImage systemImageNamed:[ALDeviceCell symbolForType:d.type] withConfiguration:cfg];

	self.nameLabel.text = d.displayName;
	// Green open padlock = no password; blue key = saved in Settings (joinable).
	BOOL open = [ALWiFiJoin isOpen:d], saved = !open && [ALWiFiJoin isSaved:d];
	self.openIcon.hidden = !(open || saved);
	if (open || saved) {
		self.openIcon.image = [UIImage systemImageNamed:(open ? @"lock.open.fill" : @"key.fill")
			withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold]];
		self.openIcon.tintColor = open ? [UIColor systemGreenColor] : [UIColor systemBlueColor];
	}
	self.subtitleLabel.text = d.identifier;

	NSMutableArray *meta = [NSMutableArray array];
	if (d.children.count)      [meta addObject:[NSString stringWithFormat:@"%lu APs", (unsigned long)d.children.count]];
	if (d.info[@"Channels"])   [meta addObject:[NSString stringWithFormat:@"ch %@", d.info[@"Channels"]]];
	else if (d.info[@"Channel"]) [meta addObject:[NSString stringWithFormat:@"ch %@", d.info[@"Channel"]]];
	NSString *gen = d.info[@"Wi-Fi Generation"]; // "Wi-Fi 6 (802.11ax)" -> "Wi-Fi 6"
	if (gen) [meta addObject:[gen componentsSeparatedByString:@" ("].firstObject];
	if (d.info[@"Device Kind"]) [meta addObject:d.info[@"Device Kind"]];
	if (d.info[@"Manufacturer"]) [meta addObject:d.info[@"Manufacturer"]];
	else if (d.info[@"Company ID"]) [meta addObject:d.info[@"Company ID"]];
	if (d.info[@"Connectable"])[meta addObject:[@"conn: " stringByAppendingString:d.info[@"Connectable"]]];
	self.metaLabel.text = [meta componentsJoinedByString:@"  ·  "];
	self.metaLabel.hidden = (meta.count == 0);

	self.rssiPill.backgroundColor = [ALDeviceCell colorForRSSI:d.rssi];
	self.rssiLabel.text = (d.rssi == 0) ? @"—" : [NSString stringWithFormat:@"%ld", (long)d.rssi];
	self.sightingsLabel.text = [d sightingsText];
}

@end
