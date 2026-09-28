#import "ALDatabase.h"
#import <sqlite3.h>

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
}

- (void)recordDevice:(ALDevice *)d location:(CLLocation *)loc {
	if (!_db || d.identifier.length == 0) return;

	// Throttle: at most one row per identifier per 5s.
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
	double lat = loc ? loc.coordinate.latitude : 0;
	double lon = loc ? loc.coordinate.longitude : 0;
	double acc = loc ? loc.horizontalAccuracy : -1;
	BOOL hasLoc = (loc != nil && loc.horizontalAccuracy >= 0);

	dispatch_async(_q, ^{
		const char *sql = "INSERT INTO sightings (ts,type,identifier,name,rssi,channel,info,lat,lon,h_acc) "
						  "VALUES (?,?,?,?,?,?,?,?,?,?);";
		sqlite3_stmt *st = NULL;
		if (sqlite3_prepare_v2(self->_db, sql, -1, &st, NULL) != SQLITE_OK) return;
		sqlite3_bind_double(st, 1, [[NSDate date] timeIntervalSince1970]);
		sqlite3_bind_int(st, 2, (int)type);
		sqlite3_bind_text(st, 3, identifier.UTF8String, -1, SQLITE_TRANSIENT);
		if (name) sqlite3_bind_text(st, 4, name.UTF8String, -1, SQLITE_TRANSIENT); else sqlite3_bind_null(st, 4);
		sqlite3_bind_int(st, 5, (int)rssi);
		if (channel) sqlite3_bind_text(st, 6, channel.UTF8String, -1, SQLITE_TRANSIENT); else sqlite3_bind_null(st, 6);
		if (infoJSON) sqlite3_bind_text(st, 7, infoJSON.UTF8String, -1, SQLITE_TRANSIENT); else sqlite3_bind_null(st, 7);
		if (hasLoc) { sqlite3_bind_double(st, 8, lat); sqlite3_bind_double(st, 9, lon); sqlite3_bind_double(st, 10, acc); }
		else { sqlite3_bind_null(st, 8); sqlite3_bind_null(st, 9); sqlite3_bind_null(st, 10); }
		sqlite3_step(st);
		sqlite3_finalize(st);
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
