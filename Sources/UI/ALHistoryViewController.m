//
//  ALHistoryViewController.m — AirLogger
//
//  "All" tab. Lists every device ever stored (ALDatabase allDevices). No title:
//  a type picker (All / Wi-Fi / BLE / Classic) is the nav bar's title view, with
//  the search bar (name or identifier) under it, and a sort menu (Name / RSSI /
//  Latest) on the right. Hosts the database-wipe (trash) button.
//

#import "ALHistoryViewController.h"
#import "ALDatabase.h"
#import "ALDevice.h"
#import "ALDeviceCell.h"
#import "ALDetailViewController.h"
#import "ALVendor.h"
#import "ALAdvDecoder.h"

typedef NS_ENUM(NSInteger, ALHistorySort) {
	ALHistorySortLatest = 0, // most recently seen first
	ALHistorySortRSSI,       // strongest ever first; no-RSSI (classic) last
	ALHistorySortName,       // A→Z; unnamed last
};

static NSString *const kSortDefaultsKey = @"ALHistorySort";

// Type picker segments. Segment index - 1 == ALDeviceType (0 = All).
static NSString *const kTypeSegmentTitles[] = { @"All", @"Wi-Fi", @"BLE", @"Classic" };
static const NSInteger kTypeSegmentCount = 4;

@interface ALHistoryViewController () <UISearchResultsUpdating>
@property (nonatomic, strong) NSArray<ALDevice *> *all;       // every stored device
@property (nonatomic, strong) NSArray<ALDevice *> *filtered;  // after search + scope
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, strong) UISegmentedControl *typeControl;
@property (nonatomic) ALHistorySort sort;
@end

@implementation ALHistoryViewController

- (instancetype)init {
	return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
	[self.tableView registerClass:[ALDeviceCell class] forCellReuseIdentifier:@"dev"];
	// Pull the "N devices" header up against the search bar: grouped tables pad
	// ~35pt above the first section when there's no table header, iOS 15 adds
	// sectionHeaderTopPadding, and the header itself is tall (see heightForHeader).
	self.tableView.tableHeaderView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, CGFLOAT_MIN)];
	if (@available(iOS 15.0, *)) self.tableView.sectionHeaderTopPadding = 0;

	NSMutableArray *typeTitles = [NSMutableArray array];
	for (NSInteger i = 0; i < kTypeSegmentCount; i++) [typeTitles addObject:kTypeSegmentTitles[i]];
	self.typeControl = [[UISegmentedControl alloc] initWithItems:typeTitles];
	self.typeControl.selectedSegmentIndex = 0;
	self.typeControl.frame = CGRectMake(0, 0, 260, 30);
	[self.typeControl addTarget:self action:@selector(applyFilter) forControlEvents:UIControlEventValueChanged];
	self.navigationItem.titleView = self.typeControl;

	self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
	self.search.searchResultsUpdater = self;
	self.search.obscuresBackgroundDuringPresentation = NO;
	self.search.searchBar.placeholder = @"Search name";
	self.navigationItem.searchController = self.search;
	self.navigationItem.hidesSearchBarWhenScrolling = NO;

	self.navigationItem.leftBarButtonItem =
		[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
													  target:self action:@selector(confirmWipe)];

	NSInteger saved = [[NSUserDefaults standardUserDefaults] integerForKey:kSortDefaultsKey];
	self.sort = (saved >= ALHistorySortLatest && saved <= ALHistorySortName) ? saved : ALHistorySortLatest;
	self.navigationItem.rightBarButtonItem =
		[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"] menu:[self sortMenu]];

	UIRefreshControl *rc = [[UIRefreshControl alloc] init];
	[rc addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
	self.refreshControl = rc;
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self reload];
}

- (void)reload {
	NSMutableArray *devs = [NSMutableArray array];
	for (NSDictionary *r in [[ALDatabase shared] allDevices]) {
		ALDevice *d = [[ALDevice alloc] init];
		d.type = (ALDeviceType)[r[@"type"] integerValue];
		d.identifier = r[@"identifier"];
		d.name = [r[@"name"] length] ? r[@"name"] : nil;
		d.rssi = [r[@"rssi"] integerValue];
		d.sightings = [r[@"cnt"] unsignedIntegerValue];
		d.fromHistory = YES;
		NSDate *last = [NSDate dateWithTimeIntervalSince1970:[r[@"last"] doubleValue]];
		d.lastSeen = last;
		d.firstSeen = last;
		NSString *infoStr = r[@"info"];
		if (infoStr.length) {
			id parsed = [NSJSONSerialization JSONObjectWithData:[infoStr dataUsingEncoding:NSUTF8StringEncoding]
														options:0 error:nil];
			if ([parsed isKindOfClass:[NSDictionary class]]) [d.info addEntriesFromDictionary:parsed];
		}
		if ([r[@"channel"] length]) d.info[@"Channel"] = r[@"channel"];
		// Rows logged before manufacturer lookup existed: derive it now.
		if (!d.info[@"Manufacturer"]) {
			NSString *m = nil;
			if (d.type == ALDeviceTypeBLE) {
				unsigned cid = 0;
				NSScanner *sc = [NSScanner scannerWithString:d.info[@"Company ID"] ?: @""];
				if ([sc scanHexInt:&cid]) m = [ALVendor companyNameForID:(uint16_t)cid];
			} else {
				m = [ALVendor vendorForMAC:d.identifier];
			}
			if (m) d.info[@"Manufacturer"] = m;
		}
		// Likewise device kind / OS family etc. from the stored raw advertisement.
		if (d.type == ALDeviceTypeBLE && !d.info[@"Device Kind"]) [ALAdvDecoder decodeStoredInfo:d.info];
		[devs addObject:d];
	}
	self.all = devs;
	[self.refreshControl endRefreshing];
	[self applyFilter];
}

- (void)showDetailForIdentifier:(NSString *)identifier {
	[self loadViewIfNeeded];
	[self.navigationController popToRootViewControllerAnimated:NO];
	[self reload];
	for (ALDevice *d in self.all) {
		if (![d.identifier isEqualToString:identifier]) continue;
		ALDetailViewController *vc = [[ALDetailViewController alloc] initWithDevice:d];
		[self.navigationController pushViewController:vc animated:YES];
		return;
	}
}

#pragma mark - Sort

- (UIMenu *)sortMenu {
	NSArray *titles = @[@"Latest", @"RSSI", @"Name"];
	NSArray *symbols = @[@"clock", @"antenna.radiowaves.left.and.right", @"textformat"];
	NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
	for (NSInteger m = ALHistorySortLatest; m <= ALHistorySortName; m++) {
		__weak typeof(self) weakSelf = self;
		UIAction *a = [UIAction actionWithTitle:titles[m] image:[UIImage systemImageNamed:symbols[m]]
									 identifier:nil handler:^(__kindof UIAction *action) {
			[weakSelf setSortMode:(ALHistorySort)m];
		}];
		a.state = (self.sort == m) ? UIMenuElementStateOn : UIMenuElementStateOff;
		[items addObject:a];
	}
	return [UIMenu menuWithTitle:@"Sort by" children:items];
}

- (void)setSortMode:(ALHistorySort)sort {
	self.sort = sort;
	[[NSUserDefaults standardUserDefaults] setInteger:sort forKey:kSortDefaultsKey];
	self.navigationItem.rightBarButtonItem.menu = [self sortMenu];
	[self applyFilter];
}

- (NSComparator)comparator {
	NSComparator latest = ^NSComparisonResult(ALDevice *a, ALDevice *b) {
		return [b.lastSeen compare:a.lastSeen];
	};
	switch (self.sort) {
		case ALHistorySortRSSI:
			return ^NSComparisonResult(ALDevice *a, ALDevice *b) {
				// Classic BT is stored with rssi 0 (no RSSI): don't let it rank as strongest.
				BOOL ha = a.rssi < 0, hb = b.rssi < 0;
				if (ha != hb) return ha ? NSOrderedAscending : NSOrderedDescending;
				if (a.rssi != b.rssi) return a.rssi > b.rssi ? NSOrderedAscending : NSOrderedDescending;
				return latest(a, b);
			};
		case ALHistorySortName:
			return ^NSComparisonResult(ALDevice *a, ALDevice *b) {
				if ((a.name != nil) != (b.name != nil)) return a.name ? NSOrderedAscending : NSOrderedDescending;
				NSComparisonResult r = a.name ? [a.name localizedStandardCompare:b.name] : NSOrderedSame;
				return r != NSOrderedSame ? r : [a.identifier compare:b.identifier];
			};
		case ALHistorySortLatest:
		default:
			return latest;
	}
}

#pragma mark - Filter

- (void)applyFilter {
	NSString *q = self.search.searchBar.text.lowercaseString;
	NSInteger scope = self.typeControl.selectedSegmentIndex; // 0 all, else ALDeviceType + 1

	NSMutableArray *out = [NSMutableArray array];
	for (ALDevice *d in self.all) {
		if (scope > 0 && d.type != (ALDeviceType)(scope - 1)) continue;
		if (q.length &&
			![d.name.lowercaseString containsString:q] &&
			![d.identifier.lowercaseString containsString:q]) continue;
		[out addObject:d];
	}
	[out sortUsingComparator:[self comparator]];
	self.filtered = out;
	[self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)sc { [self applyFilter]; }

- (void)confirmWipe {
	UIAlertController *a = [UIAlertController
		alertControllerWithTitle:@"Erase all data?"
						 message:@"This permanently deletes every logged sighting from the database and clears the list and map. This cannot be undone."
				  preferredStyle:UIAlertControllerStyleAlert];
	[a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[a addAction:[UIAlertAction actionWithTitle:@"Erase" style:UIAlertActionStyleDestructive
										handler:^(UIAlertAction *action) {
		[[ALDatabase shared] wipe];
		[self reload];
	}]];
	[self presentViewController:a animated:YES completion:nil];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.filtered.count; }

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s { return 30; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
	if (self.filtered.count == self.all.count)
		return [NSString stringWithFormat:@"%lu devices", (unsigned long)self.all.count];
	return [NSString stringWithFormat:@"%lu of %lu devices",
			(unsigned long)self.filtered.count, (unsigned long)self.all.count];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
	ALDeviceCell *cell = [tv dequeueReusableCellWithIdentifier:@"dev" forIndexPath:ip];
	[cell configureWithDevice:self.filtered[ip.row]];
	return cell;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip { return UITableViewAutomaticDimension; }
- (CGFloat)tableView:(UITableView *)tv estimatedHeightForRowAtIndexPath:(NSIndexPath *)ip { return 66; }

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
	[tv deselectRowAtIndexPath:ip animated:YES];
	ALDetailViewController *vc = [[ALDetailViewController alloc] initWithDevice:self.filtered[ip.row]];
	[self.navigationController pushViewController:vc animated:YES];
}

@end
