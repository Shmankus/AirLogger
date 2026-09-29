//
//  ALDatabase.m — AirLogger
//
//  SQLite store (singleton) for GPS-tagged sightings, at
//  /var/mobile/Library/AirLogger/ (the app's sandbox container isn't writable,
//  and this path survives reinstalls). Handles throttled, movement-gated writes
//  with a per-device row cap (see the storage policy below), and the
//  aggregate queries that back the map (best/observed locations) and the
//  history list (allDevices), plus wipe.
//

#import "ALDatabase.h"
#import <sqlite3.h>

// Per-device storage policy:
//  - A new geotagged row is only inserted once we've moved kMinMoveMeters (or the
//    fix's accuracy radius, if worse) from that device's latest geotagged row.
//    While stationary, that row is refreshed in place (ts/name/info, smoothed rssi),
//    so sitting at a desk costs one row per device, not one every 5s.
//  - Sightings without a fix collapse into a single row per device.
//  - Cap of kMaxSightingsPerDevice geotagged rows per device. Wi-Fi APs rarely
//    move, so they keep the kKeepRecentWiFi newest rows plus the strongest of the
//    rest (strong = close = most accurate). Bluetooth devices move with people,
//    so they simply keep the newest rows.
static const int kMaxSightingsPerDevice = 50;
static const int kKeepRecentWiFi = 10;
static const double kMinMoveMeters = 10.0;

@implementation ALDatabase {
	sqlite3 *_db;
	dispatch_queue_t _q;
	NSMutableDictionary<NSString *, NSDate *> *_lastWrite; // per-identifier throttle
}

+ (instancetype)shared {
	static ALDatabase *s;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [[ALDatabase alloc] init]; });
	return s;
}

- (instancetype)init {
	if ((self = [super init])) {
		_q = dispatch_queue_create("com.shmank.airlogger.db", DISPATCH_QUEUE_SERIAL);
		_lastWrite = [NSMutableDictionary dictionary];
		[self open];
	}
	return self;
}

- (NSString *)path {
	// The sandbox denies our container, but this system path is writable and
	// survives app reinstalls.
	return @"/var/mobile/Library/AirLogger/airlogger.sqlite";
}

- (void)open {
	NSString *dir = [self.path stringByDeletingLastPathComponent];
	[[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

	if (sqlite3_open(self.path.UTF8String, &_db) != SQLITE_OK) {
		NSLog(@"[AirLogger] db open failed: %s", sqlite3_errmsg(_db));
		_db = NULL;
		return;
	}
	const char *ddl =
		"CREATE TABLE IF NOT EXISTS sightings ("
		"  id INTEGER PRIMARY KEY AUTOINCREMENT,"
		"  ts REAL NOT NULL,"
		"  type INTEGER NOT NULL,"
		"  identifier TEXT NOT NULL,"
		"  name TEXT,"
		"  rssi INTEGER,"
		"  channel TEXT,"
		"  info TEXT,"
		"  lat REAL, lon REAL, h_acc REAL"
		");"
		"CREATE INDEX IF NOT EXISTS idx_ident ON sightings(identifier);";
	char *errmsg = NULL;
	if (sqlite3_exec(_db, ddl, NULL, NULL, &errmsg) != SQLITE_OK) {
		NSLog(@"[AirLogger] db ddl failed: %s", errmsg);
		sqlite3_free(errmsg);
	}
	[self trimAll];
}

// Deletes geotagged rows beyond the cap, for one identifier (or all if nil).
// Keep order per device: Wi-Fi keeps its kKeepRecentWiFi newest rows, then the
// strongest of the rest; other types keep their newest. Call on _q (or in open).
- (void)trimGeotagged:(NSString *)identifier {
	char *sql = sqlite3_mprintf(
		"DELETE FROM sightings WHERE id IN (SELECT id FROM ("
		"  SELECT id, ROW_NUMBER() OVER (PARTITION BY identifier ORDER BY"
		"    type = 0 AND rn_recent > %d, CASE WHEN type = 0 THEN rssi END DESC, rn_recent) rn_keep"
		"  FROM (SELECT id, identifier, type, rssi,"
		"    ROW_NUMBER() OVER (PARTITION BY identifier ORDER BY ts DESC, id DESC) rn_recent"
		"    FROM sightings WHERE lat IS NOT NULL AND (%Q IS NULL OR identifier = %Q))"
		") WHERE rn_keep > %d);",
		kKeepRecentWiFi, identifier.UTF8String, identifier.UTF8String, kMaxSightingsPerDevice);
	char *errmsg = NULL;
	if (sqlite3_exec(_db, sql, NULL, NULL, &errmsg) != SQLITE_OK) {
		NSLog(@"[AirLogger] db trim failed: %s", errmsg);
		sqlite3_free(errmsg);
	}
	sqlite3_free(sql);
}

// One-time pass at open: enforce the policy on rows logged before it existed.
- (void)trimAll {
	[self trimGeotagged:nil];
	// Fix-less sightings collapse to one row per device.
	sqlite3_exec(_db,
		"DELETE FROM sightings WHERE id IN ("
		"  SELECT id FROM (SELECT id, ROW_NUMBER() OVER (PARTITION BY identifier ORDER BY ts DESC, id DESC) rn"
		"  FROM sightings WHERE lat IS NULL) WHERE rn > 1);", NULL, NULL, NULL);
}

// Latest row for identifier, geotagged or fix-less. Returns 0 if none. Call on _q.
- (sqlite3_int64)latestRowFor:(NSString *)identifier geotagged:(BOOL)geo lat:(double *)lat lon:(double *)lon {
	const char *sql = geo
		? "SELECT id, lat, lon FROM sightings WHERE identifier=? AND lat IS NOT NULL ORDER BY ts DESC, id DESC LIMIT 1;"
		: "SELECT id, 0, 0 FROM sightings WHERE identifier=? AND lat IS NULL ORDER BY ts DESC, id DESC LIMIT 1;";
	sqlite3_stmt *st = NULL;
	sqlite3_int64 rowid = 0;
	if (sqlite3_prepare_v2(_db, sql, -1, &st, NULL) != SQLITE_OK) return 0;
	sqlite3_bind_text(st, 1, identifier.UTF8String, -1, SQLITE_TRANSIENT);
	if (sqlite3_step(st) == SQLITE_ROW) {
		rowid = sqlite3_column_int64(st, 0);
		if (lat) *lat = sqlite3_column_double(st, 1);
		if (lon) *lon = sqlite3_column_double(st, 2);
	}
	sqlite3_finalize(st);
	return rowid;
}

- (void)recordDevice:(ALDevice *)d location:(CLLocation *)loc {
	if (!_db || d.identifier.length == 0) return;

	// Throttle: at most one write per identifier per 5s.
	NSDate *last = _lastWrite[d.identifier];
	if (last && [[NSDate date] timeIntervalSinceDate:last] < 5.0) return;
	_lastWrite[d.identifier] = [NSDate date];

	NSInteger type = d.type;
	NSString *identifier = [d.identifier copy];
	NSString *name = [d.name copy];
	NSInteger rssi = d.rssi;
	NSString *channel = [(d.info[@"Channel"] ?: d.info[@"Channels"]) copy];

	NSString *infoJSON = nil;
	if (d.info.count) {
		NSData *j = [NSJSONSerialization dataWithJSONObject:d.info options:0 error:nil];
		if (j) infoJSON = [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding];
	}
	BOOL hasLoc = (loc != nil && loc.horizontalAccuracy >= 0);
	CLLocation *here = hasLoc ? [loc copy] : nil;

	dispatch_async(_q, ^{
		double now = [[NSDate date] timeIntervalSince1970];

		// Stationary (or no fix): refresh the existing row instead of adding one.
		double plat = 0, plon = 0;
		sqlite3_int64 prev = [self latestRowFor:identifier geotagged:hasLoc lat:&plat lon:&plon];
		BOOL moved = YES;
		if (prev && hasLoc) {
			CLLocation *anchor = [[CLLocation alloc] initWithLatitude:plat longitude:plon];
			moved = [here distanceFromLocation:anchor] >= MAX(kMinMoveMeters, here.horizontalAccuracy);
		}
		if (prev && (!hasLoc || !moved)) {
			// The anchor's lat/lon stay put so slow GPS drift can't creep without
			// ever triggering an insert; rssi is smoothed rather than overwritten.
			const char *sql = "UPDATE sightings SET ts=?, name=COALESCE(?, name), "
							  "rssi=CAST(ROUND(COALESCE(rssi, ?3) * 0.7 + ?3 * 0.3) AS INTEGER), "
							  "channel=COALESCE(?, channel), info=COALESCE(?, info) WHERE id=?;";
			sqlite3_stmt *st = NULL;
			if (sqlite3_prepare_v2(self->_db, sql, -1, &st, NULL) != SQLITE_OK) return;
			sqlite3_bind_double(st, 1, now);
			if (name) sqlite3_bind_text(st, 2, name.UTF8String, -1, SQLITE_TRANSIENT); else sqlite3_bind_null(st, 2);
			sqlite3_bind_int(st, 3, (int)rssi);
			if (channel) sqlite3_bind_text(st, 4, channel.UTF8String, -1, SQLITE_TRANSIENT); else sqlite3_bind_null(st, 4);
			if (infoJSON) sqlite3_bind_text(st, 5, infoJSON.UTF8String, -1, SQLITE_TRANSIENT); else sqlite3_bind_null(st, 5);
			sqlite3_bind_int64(st, 6, prev);
			sqlite3_step(st);
			sqlite3_finalize(st);
			return;
		}

		const char *sql = "INSERT INTO sightings (ts,type,identifier,name,rssi,channel,info,lat,lon,h_acc) "
						  "VALUES (?,?,?,?,?,?,?,?,?,?);";
		sqlite3_stmt *st = NULL;
		if (sqlite3_prepare_v2(self->_db, sql, -1, &st, NULL) != SQLITE_OK) return;
		sqlite3_bind_double(st, 1, now);
		sqlite3_bind_int(st, 2, (int)type);
		sqlite3_bind_text(st, 3, identifier.UTF8String, -1, SQLITE_TRANSIENT);
		if (name) sqlite3_bind_text(st, 4, name.UTF8String, -1, SQLITE_TRANSIENT); else sqlite3_bind_null(st, 4);
		sqlite3_bind_int(st, 5, (int)rssi);
		if (channel) sqlite3_bind_text(st, 6, channel.UTF8String, -1, SQLITE_TRANSIENT); else sqlite3_bind_null(st, 6);
		if (infoJSON) sqlite3_bind_text(st, 7, infoJSON.UTF8String, -1, SQLITE_TRANSIENT); else sqlite3_bind_null(st, 7);
		if (hasLoc) {
			sqlite3_bind_double(st, 8, here.coordinate.latitude);
			sqlite3_bind_double(st, 9, here.coordinate.longitude);
			sqlite3_bind_double(st, 10, here.horizontalAccuracy);
		} else { sqlite3_bind_null(st, 8); sqlite3_bind_null(st, 9); sqlite3_bind_null(st, 10); }
		sqlite3_step(st);
		sqlite3_finalize(st);
		if (hasLoc) [self trimGeotagged:identifier];
	});
}

- (NSArray<NSDictionary *> *)bestLocationsPerDevice {
	if (!_db) return @[];
	NSMutableArray *out = [NSMutableArray array];
	dispatch_sync(_q, ^{
		// For each identifier, the row (with a fix) that has the strongest RSSI.
		const char *sql =
			"SELECT s.identifier, s.name, s.type, s.rssi, s.lat, s.lon FROM sightings s "
			"JOIN (SELECT identifier, MAX(rssi) mr FROM sightings WHERE lat IS NOT NULL GROUP BY identifier) b "
			"ON s.identifier = b.identifier AND s.rssi = b.mr "
			"WHERE s.lat IS NOT NULL GROUP BY s.identifier;";
		sqlite3_stmt *st = NULL;
		if (sqlite3_prepare_v2(self->_db, sql, -1, &st, NULL) != SQLITE_OK) return;
		while (sqlite3_step(st) == SQLITE_ROW) {
			const char *ident = (const char *)sqlite3_column_text(st, 0);
			const char *name = (const char *)sqlite3_column_text(st, 1);
			[out addObject:@{
				@"identifier": ident ? @(ident) : @"",
				@"name": name ? @(name) : @"",
				@"type": @(sqlite3_column_int(st, 2)),
				@"rssi": @(sqlite3_column_int(st, 3)),
				@"lat": @(sqlite3_column_double(st, 4)),
				@"lon": @(sqlite3_column_double(st, 5)),
			}];
		}
		sqlite3_finalize(st);
	});
	return out;
}

- (NSArray<NSDictionary *> *)geotaggedObservations {
	if (!_db) return @[];
	NSMutableArray *out = [NSMutableArray array];
	dispatch_sync(_q, ^{
		const char *sql = "SELECT identifier,name,type,rssi,lat,lon,ts FROM sightings WHERE lat IS NOT NULL;";
		sqlite3_stmt *st = NULL;
		if (sqlite3_prepare_v2(self->_db, sql, -1, &st, NULL) != SQLITE_OK) return;
		while (sqlite3_step(st) == SQLITE_ROW) {
			const char *ident = (const char *)sqlite3_column_text(st, 0);
			const char *name = (const char *)sqlite3_column_text(st, 1);
			[out addObject:@{
				@"identifier": ident ? @(ident) : @"",
				@"name": name ? @(name) : @"",
				@"type": @(sqlite3_column_int(st, 2)),
				@"rssi": @(sqlite3_column_int(st, 3)),
				@"lat": @(sqlite3_column_double(st, 4)),
				@"lon": @(sqlite3_column_double(st, 5)),
				@"ts": @(sqlite3_column_double(st, 6)),
			}];
		}
		sqlite3_finalize(st);
	});
	return out;
}

- (void)wipe {
	if (!_db) return;
	dispatch_sync(_q, ^{
		char *err = NULL;
		sqlite3_exec(self->_db, "DELETE FROM sightings;", NULL, NULL, &err);
		if (err) sqlite3_free(err);
		sqlite3_exec(self->_db, "VACUUM;", NULL, NULL, NULL);
	});
	[_lastWrite removeAllObjects]; // let devices log again immediately
}

- (NSArray<NSDictionary *> *)allDevices {
	if (!_db) return @[];
	NSMutableArray *out = [NSMutableArray array];
	dispatch_sync(_q, ^{
		const char *sql =
			"SELECT s.identifier, s.type, MAX(s.rssi) best, COUNT(*) cnt, MAX(s.ts) last, "
			"(SELECT name FROM sightings s2 WHERE s2.identifier=s.identifier AND name IS NOT NULL ORDER BY ts DESC LIMIT 1) nm, "
			"(SELECT info FROM sightings s3 WHERE s3.identifier=s.identifier ORDER BY ts DESC LIMIT 1) inf, "
			"(SELECT channel FROM sightings s4 WHERE s4.identifier=s.identifier ORDER BY ts DESC LIMIT 1) ch "
			"FROM sightings s GROUP BY s.identifier;";
		sqlite3_stmt *st = NULL;
		if (sqlite3_prepare_v2(self->_db, sql, -1, &st, NULL) != SQLITE_OK) return;
		while (sqlite3_step(st) == SQLITE_ROW) {
			const char *ident = (const char *)sqlite3_column_text(st, 0);
			const char *nm = (const char *)sqlite3_column_text(st, 5);
			const char *inf = (const char *)sqlite3_column_text(st, 6);
			const char *ch = (const char *)sqlite3_column_text(st, 7);
			[out addObject:@{
				@"identifier": ident ? @(ident) : @"",
				@"type": @(sqlite3_column_int(st, 1)),
				@"rssi": @(sqlite3_column_int(st, 2)),
				@"cnt": @(sqlite3_column_int(st, 3)),
				@"last": @(sqlite3_column_double(st, 4)),
				@"name": nm ? @(nm) : @"",
				@"info": inf ? @(inf) : @"",
				@"channel": ch ? @(ch) : @"",
			}];
		}
		sqlite3_finalize(st);
	});
	return out;
}

- (NSUInteger)totalSightings {
	if (!_db) return 0;
	__block NSUInteger n = 0;
	dispatch_sync(_q, ^{
		sqlite3_stmt *st = NULL;
		if (sqlite3_prepare_v2(self->_db, "SELECT COUNT(*) FROM sightings;", -1, &st, NULL) == SQLITE_OK) {
			if (sqlite3_step(st) == SQLITE_ROW) n = (NSUInteger)sqlite3_column_int64(st, 0);
		}
		sqlite3_finalize(st);
	});
	return n;
}

@end
