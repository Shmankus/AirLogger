#import "ALHistoryViewController.h"
#import "ALDatabase.h"
#import "ALDevice.h"
#import "ALDeviceCell.h"
#import "ALDetailViewController.h"

@interface ALHistoryViewController () <UISearchResultsUpdating, UISearchBarDelegate>
@property (nonatomic, strong) NSArray<ALDevice *> *all;       // every stored device
@property (nonatomic, strong) NSArray<ALDevice *> *filtered;  // after search + scope
@property (nonatomic, strong) UISearchController *search;
@end

@implementation ALHistoryViewController

- (instancetype)init {
	return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"All Devices";
	self.navigationController.navigationBar.prefersLargeTitles = YES;
	[self.tableView registerClass:[ALDeviceCell class] forCellReuseIdentifier:@"dev"];

	self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
	self.search.searchResultsUpdater = self;
	self.search.obscuresBackgroundDuringPresentation = NO;
	self.search.searchBar.placeholder = @"Search name or address";
	self.search.searchBar.scopeButtonTitles = @[@"All", @"Wi-Fi", @"BLE", @"BT"];
	self.search.searchBar.delegate = self;
	self.navigationItem.searchController = self.search;
	self.navigationItem.hidesSearchBarWhenScrolling = NO;

	self.navigationItem.leftBarButtonItem =
		[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
													  target:self action:@selector(confirmWipe)];

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
		[devs addObject:d];
	}
	[devs sortUsingComparator:^NSComparisonResult(ALDevice *a, ALDevice *b) {
		return [b.lastSeen compare:a.lastSeen]; // most recent first
	}];
	self.all = devs;
	[self.refreshControl endRefreshing];
	[self applyFilter];
}

- (void)applyFilter {
	NSString *q = self.search.searchBar.text.lowercaseString;
	NSInteger scope = self.search.searchBar.selectedScopeButtonIndex; // 0 all,1 wifi,2 ble,3 bt

	NSArray *scopeNames = @[@"All", @"Wi-Fi", @"BLE", @"BT"];
	self.title = [NSString stringWithFormat:@"%@ Devices",
				  scopeNames[(scope >= 0 && scope < 4) ? scope : 0]];

	NSMutableArray *out = [NSMutableArray array];
	for (ALDevice *d in self.all) {
		if (scope == 1 && d.type != ALDeviceTypeWiFi) continue;
		if (scope == 2 && d.type != ALDeviceTypeBLE) continue;
		if (scope == 3 && d.type != ALDeviceTypeClassicBT) continue;
		if (q.length &&
			![d.name.lowercaseString containsString:q] &&
			![d.identifier.lowercaseString containsString:q]) continue;
		[out addObject:d];
	}
	self.filtered = out;
	[self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)sc { [self applyFilter]; }
- (void)searchBar:(UISearchBar *)sb selectedScopeButtonIndexDidChange:(NSInteger)i { [self applyFilter]; }

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
