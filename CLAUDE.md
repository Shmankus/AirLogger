# CLAUDE.md — AirLogger

Context for working on this project. AirLogger is a native iOS app for a **rootless
jailbroken iPhone** that scans nearby Wi-Fi and Bluetooth devices, GPS-tags each
sighting, logs to SQLite, and estimates transmitter locations on a map. Objective-C,
built with Theos.

## Features at a glance

Details for each live in the gotchas and file map below.

- **Scanning:** Wi-Fi (MobileWiFi), BLE (CoreBluetooth with the privileged-daemon flag),
  Classic Bluetooth (BluetoothManager, no RSSI). GPS-tagged into SQLite with bounded storage.
- **Current tab:** no title; Live/Session toggle in the nav bar, compact connected Wi-Fi
  card with speed test, pinned Wi-Fi / BLE / Classic type picker with counts + a small
  "N nearby now · Scanning" line; swipe to join. Counts read "N heard".
- **All tab:** full history, type picker, search, sort (Latest / RSSI / Name). Counts read "N places".
- **Detail page:** Identity (Device Kind, OS Family, Manufacturer, Saved in Settings), decoded
  fields; buttons for Join / Disconnect, Track in Status Bar, Show on Map.
- **Map:** Leaflet in a WKWebView; filters by type/band/security; detail → map focuses a
  pin, pin popup "View Details" → All tab detail.
- **Decoding:** manufacturer via OUI / Bluetooth SIG company ID (ALVendor); BLE Apple
  Continuity / Microsoft / Google / Samsung → device kind + OS, AirPods batteries, AirPlay
  IP, Find My (ALAdvDecoder); Wi-Fi beacon IEs → generation, width, streams, clients, WPS
  make/model (ALWiFiIE).
- **Wi-Fi join/leave:** open and Settings-saved networks via MobileWiFi association;
  disconnect via disassociate (ALWiFiJoin).
- **Status bar:** carrier text via the user's CarrierText tweak — nearby counts, connected
  Wi-Fi, live RSSI tracking of one device, speed-test progress (ALStatusBar).

## Target device & environment

- **Device:** iPhone 7 (arm64, A10), **iOS 15.2.1**, rootless **Dopamine** jailbreak.
- **Build host:** Linux (`shmerver`), Theos at `/opt/theos`, SDK `iPhoneOS16.5.sdk`
  (deployment target 14.0). Always `export THEOS=/opt/theos` before building.
- **App bundle id:** `com.shmank.airlogger`; installs to `/var/jb/Applications/AirLogger.app`.
- **SSH to device:** `root@<ip>` with a key (passwordless). Device config is in the
  **gitignored `Makefile.local`** (`THEOS_DEVICE_IP` / `PORT` / `USER=root`).

## Build / deploy / debug commands

```sh
export THEOS=/opt/theos
make package          # build rootless .deb into ./packages
make do               # build + install over SSH + uicache (uses Makefile.local)
make clean && make do # REQUIRED after editing entitlements.plist (see below)
```

- **Installs need root:** `dpkg` needs superuser, so `THEOS_DEVICE_USER = root`
  (installing as `mobile` fails; `mobile` has no passwordless sudo here).
- **Relaunch on device:** `ssh root@<ip> 'killall AirLogger'`, then the user taps the
  icon. `uiopen --bundleid com.shmank.airlogger` launches it, **but only foregrounds /
  runs the UI if the screen is unlocked** — a locked-screen launch won't run
  `viewDidLoad`/scanning, so UI testing must be done by the user on an unlocked device.

## Hard-won gotchas (do not relearn these)

- **Swift/SwiftUI is NOT possible** on the Linux build host — no Swift compiler can
  cross-compile to iOS/Darwin here. Objective-C / UIKit only. (SwiftUI would need macOS.)
- **Wi-Fi:** the legacy `Apple80211*` C API is **gone on iOS 15**. Use the
  `WiFiManagerClient` / `WiFiDeviceClient` family in `MobileWiFi.framework`, resolved with
  `dlopen`/`dlsym` (symbol names came from the SDK's `MobileWiFi.tbd`). Scanning is async:
  `WiFiManagerClientCreate` → `ScheduleWithRunLoop` → `CopyDevices` → `WiFiDeviceClientScanAsync`
  with a callback; parse results with `WiFiNetworkGetSSID/RSSI/Channel`.
- **Bluetooth needs privileged entitlements:** `bluetoothd` silently refuses to deliver
  scan results to a sideloaded app until it carries **`com.apple.bluetooth.internal`** and
  **`com.apple.bluetooth.system`** (plus `com.apple.bluetooth.access`). The jailbroken AMFI
  accepts arbitrary ldid entitlements. Classic Bluetooth (private `BluetoothManager`) then works.
- **Never call private BOOL setters via `performSelector:withObject:`.** It passes an object
  pointer where a `BOOL` is expected, so the callee reads an arbitrary value — `setPowered:@YES`
  was read as NO and switched Bluetooth off on resume. Use a typed call:
  `((void (*)(id, SEL, BOOL))objc_msgSend)(obj, sel, YES)` (see `ALBluetoothScanner.sendBool:`).
- **`WiFiNetworkGetChannel` returns a `CFNumberRef`, not an `int`.** Reading it as `int`
  stored the low bits of the object's address, so every Wi-Fi channel/band logged before
  the fix is garbage (e.g. `-1303352152`). Read `WiFiNetworkGetProperty(net, "CHANNEL")`
  as a CFNumber. Any `WiFiNetworkGet*` with a surprising value: suspect a CF return type.
- **BLE (CoreBluetooth) needs the privileged-daemon flag.** `bluetoothd` can't tie this
  ad-hoc-signed app's session (`AirLogger.<hash>.unsigned-central-...`) to the foreground
  app, so it treats it as backgrounded (`FG:0` in its `ScanParams` log) — and a background
  scan with no service filter gets nothing. Fix: create the `CBCentralManager` with
  `CBManagerIsPrivilegedDaemonKey: @YES` and scan with
  `CBCentralManagerScanOptionIsPrivilegedDaemonKey: @YES` (private exports, resolved via
  `dlsym`; honored thanks to the `bluetooth.internal`/`system` entitlements). The session
  then shows `DMN:1` and `didDiscoverPeripheral` delivers with real RSSI.
- **Debugging daemons:** `oslog` (rootless package) is installed on the device:
  `oslog --debug -p bluetoothd`. Strip ANSI colours before grepping.
- **MobileWiFi's `BSSID` string isn't zero-padded** (`18:90:88:9f:63:4`). `ALWiFiScanner`
  runs it through `ALVendor normalizeMAC:`; `ALDatabase normalizeBSSIDs` rewrites old rows
  (and speedtests) at open. Compare/store MACs only in normalized form.
- **NEHotspotConfiguration fails with error 11 (`NEHotspotConfigurationErrorUnknown`,
  "<unknown>")** for this app even with the HotspotConfiguration entitlement — likely the
  same ad-hoc-signing identity problem as BLE. Joining uses MobileWiFi's private
  `WiFiDeviceClientAssociateAsync` instead — **verified** joining a saved WPA network
  (wifid applied the stored password to the scan-result network; callback came back
  `(device, network, info=NULL, err=0, ctx)`). Joining via the saved record and leaving
  via `WiFiDeviceClientDisassociate` (~1s, no auto-rejoin within 3s) are verified too.
  Open-network joins use the same call but haven't been tested in the field yet.
- **Classic Bluetooth has no RSSI.** `BluetoothDevice` has no `RSSI` method (KVC throws,
  `safeValue` returns nil), and MobileBluetooth has no `BTDeviceGetRSSI`; classic rows are
  always stored with rssi 0.
- **The app CANNOT write its own sandbox container** (`Documents`/`tmp` are denied under
  this entitlement set). Writable system paths (`/var/mobile/...`, `/var/tmp`, `/tmp`) work.
  So the **SQLite DB and log live at `/var/mobile/Library/AirLogger/`** — also survives
  reinstalls and is SSH-inspectable.
- **iOS has no `log` CLI** (that's macOS-only). Debug via file logging: `ALLog()` in
  `ALLog.h` appends to `/var/mobile/Library/AirLogger/airlogger.log`. Read it over SSH.
- **Entitlements only re-embed on a relink.** Theos signs during the link step, so editing
  `entitlements.plist` without a source change is a no-op — run `make clean && make do`.
  Verify with `ldid -e /var/jb/Applications/AirLogger.app/AirLogger`.
- **`platform-application` entitlement is intentionally NOT used** — it doesn't help and
  isn't needed (Bluetooth works via the `bluetooth.*` entitlements alone).
- **MapKit renders nothing** on this device: Maps.app and its tile engine were removed, so
  `MKMapView` never starts a map session (grey tiles, `loadTileAtPath` never called). The
  map is therefore a **`WKWebView` running Leaflet** pulling OSM tiles over HTTPS.
  - Dark theme = OSM tiles + CSS `filter: invert(1) hue-rotate(180deg) ...`
    (**CartoDB dark tiles now require an API key** — don't use them).
  - The app **does** have outbound network (verified) — WKWebView loads Leaflet from a CDN
    and tiles from OSM fine.
  - Leaflet `bringToFront()` on a canvas-rendered marker throws `t.parentNode` — avoid it.
    The map uses `preferCanvas` (device dots on one canvas); the user's dot lives in its own
    SVG pane (`user`, z-index 650) so it stays on top without `bringToFront`.
  - **Rendering cost is bounded on purpose** (it was hurting framerate/battery): only pins
    inside the viewport (+25%) get a marker, below zoom 18 nearby pins merge into a counted
    cluster bubble (tap → zoom in), and the easing `requestAnimationFrame` loop runs only
    while a dot is still moving. `render()` runs on `moveend` and after each `updateData`,
    never per frame — keep per-frame work out of the page.
  - **Clustering is hierarchical over all pins** (`buildClusters`, supercluster-style: each
    zoom level greedily merges the level above within 50px), and culling happens *after*.
    An earlier version grid-binned only the on-screen pins, so counts changed while panning
    and a bubble could hold dots visually nearer another — don't cluster post-cull.
  - `map.html` start-location placeholders are `__LAT__` / `__LON__` (valid JS identifiers),
    NOT `{{LAT}}` mustache tokens — an HTML/JS formatter rewrites `{{ }}` into `{ }` object
    literals, which is a parse error that kills the whole script (updateData undefined).
    ALMapViewController.loadPage does the string replacement before loadHTMLString.
- **Current list reloads every 1s**, which would snap an open swipe action shut. Swipe
  state is tracked via `willBeginEditingRowAtIndexPath` / `didEndEditingRowAtIndexPath`
  (`swipeOpen`) and `rebuildAndReload` skips while it's set — keep that if adding actions.
- **Resources are copied to the bundle root.** `Resources/Info.plist` → `.app/Info.plist`,
  `Resources/map.html` → `.app/map.html` (found via `pathForResource:@"map"`).
- **Never tear down scanners while running.** Pausing must keep the `ALWiFiScanner` /
  `ALBluetoothScanner` instances alive (stop their timers only, don't `nil` them).
  Deallocating the Wi-Fi scanner while an async `WiFiDeviceClientScanAsync` callback is
  in flight — its token is a non-retaining bridge — is a use-after-free, and `dlclose`-ing
  MobileWiFi in dealloc while it holds run-loop sources also crashes. Fixed by reusing
  scanner instances across pause/resume, a `_stopped` guard that drops late callbacks, and
  NOT calling `dlclose`.
- **The Current list shows one type at a time.** A Wi-Fi / BLE / Classic segmented control
  (`typeControl`, segment index == `ALDeviceType` == index into `self.sections`) picks the
  type; segment titles carry per-type counts, refreshed in `updateSummary`. Only titles
  that changed are re-set, since `rebuildAndReload` runs every second.

## Available device fields (discovered via introspection)

How to enumerate what's available on a given OS: for the **C API** Wi-Fi objects, call
`CFCopyDescription()` on a scan result (prints the backing dict) and grep the SDK's
`MobileWiFi.tbd` for `WiFiNetwork*` symbols; for the **Objective-C** private classes,
use `class_copyMethodList` / `class_copyPropertyList` at runtime and read each value.

- **Wi-Fi** (property keys via `WiFiNetworkGetProperty`, and dedicated predicates):
  `BSSID`, `SSID_STR`, `RSSI`, `CHANNEL`, `CHANNEL_FLAGS`, `CAPABILITIES`, `AGE`, `NOISE`
  (→ SNR), `BEACON_INT`, `AP_MODE`, `RATES`, `IE`, `80211D_IE` (country code). Security via
  `WiFiNetworkIsWEP/IsWPA/IsSAE`(WPA3)`/IsEAP`(enterprise)`/IsWAPI/IsHidden`; band from the
  channel number (1-14 = 2.4 GHz, else 5 GHz; the iPhone 7 radio can't see 6 GHz) or `WiFiNetworkGetOperatingBand`.
- **Bluetooth** (`BluetoothDevice` methods): `name`, `address`, `majorClass`/
  `minorClass` (+`majorClassName`/`minorClassName`), `connected`, `paired`, `batteryLevel`
  (+`supportsBatteryLevel`), `vendorId`, `productId`, `productName`, `isAppleAudioDevice`,
  `isAccessory`, `connectedServices`. `BluetoothManager` also offers `connectedDevices`,
  `pairedDevices`, `bluetoothState`, `localAddress`.

## Architecture / file map

Sources live in `Sources/<Category>/`. The Makefile compiles `Sources/*/*.m` and puts
every folder on the include path, so imports stay flat (`#import "ALDevice.h"`) and a new
file only needs to be dropped in the right folder — no Makefile edit.

```
Sources/App/            main.m, ALAppDelegate, ALLog.h         entry, tabs, cross-tab nav, logging
Sources/UI/             ALRootViewController, ALHistoryViewController, ALDetailViewController,
                        ALMapViewController, ALDeviceCell      screens + list cell
Sources/Scanning/       ALWiFiScanner, ALBluetoothScanner, ALLocationProvider   radios + GPS
Sources/Processing/     ALAdvDecoder, ALWiFiIE, ALVendor       decoding + manufacturer lookup
Sources/Data/           ALDatabase, ALDevice                   SQLite store + device model
Sources/Actions/        ALWiFiJoin, ALSpeedTest, ALStatusBar   join/leave, speed test, status bar
Resources/              Info.plist, icon, map.html, oui.txt, company_ids.txt (bundle root)
```

Per class:

```
main.m                  entry point
ALAppDelegate           UITabBarController: Current (live) / All (history) / Map tabs;
                        cross-tab nav: +showOnMap: (detail → Map, focus pin) and
                        +showDetailForIdentifier: (map popup → All tab → detail page)
ALWiFiScanner           Wi-Fi via MobileWiFi (dlopen); async scan every ~6s; currentNetwork
                        (WiFiDeviceClientCopyCurrentNetwork) parsed like scan results
ALBluetoothScanner      Classic BT via BluetoothManager; BLE via CoreBluetooth with the
                        privileged-daemon init/scan options
ALLocationProvider      Core Location singleton; background updates enabled
ALDatabase              SQLite singleton at /var/mobile/Library/AirLogger/airlogger.sqlite;
                        bestLocationsPerDevice / geotaggedObservations / allDevices / wipe;
                        speedtests table (record/speedTestForIdentifier)
ALDevice                unified device model (type, id, name, rssi, info, children)
ALDeviceCell            custom list cell (type icon + signal pill)
ALRootViewController    "Current" tab: live scan list; no nav title — the Live (last 30s,
                        kLiveWindow) / Session toggle is the nav bar titleView. Header is a
                        compact "Connected Wi-Fi" card (refreshed every 5s) with a
                        speedometer Speed Test button. The Wi-Fi / BLE / Classic type
                        picker + a small "N nearby now · Scanning" line live in a floating
                        typeBar (inset-grouped headers don't stick, so it's a table subview
                        pinned under the nav bar by layoutTypeBar over an empty section
                        header spacer); SSID grouping
ALHistoryViewController "All" tab: full DB history via allDevices; no nav title — a type
                        picker (All / Wi-Fi / BLE / Classic; segment index - 1 ==
                        ALDeviceType) is the titleView, with a UISearchController (text
                        search) under it; sort menu (Latest / RSSI / Name, remembered in
                        NSUserDefaults; RSSI puts classic's rssi 0 last); trash = wipe DB
ALDetailViewController  per-device field breakdown (incl. per-AP list for grouped Wi-Fi,
                        and a Speed Test section: latest across the group's APs);
                        "Show on Map" row if the device has a geotag (grouped Wi-Fi
                        uses its strongest geotagged AP, since pins are per BSSID)
ALWiFiJoin              open-network helpers: isOpen (Security == "Open"; groups need all
                        APs open) / canJoin (+ named, not hidden) / join: first
                        MobileWiFi WiFiDeviceClientAssociateAsync on the strongest AP's
                        network object from the last scan (ALWiFiScanner shared
                        associateWithBSSIDs:, scans held 10s), else NEHotspotConfiguration;
                        result verified by polling currentNetwork for 8s. Secured networks
                        saved in Settings (WiFiManagerClientCopyNetworks, matched by SSID,
                        cached 30s) are joinable too: scan-result association first (wifid
                        should use the stored password), then the saved record itself; the
                        cell shows a blue key for them. leave: WiFiDeviceClientDisassociate,
                        then polls until off the SSID and re-checks 3s later (auto-join
                        can pull a saved network straight back — reported as a failure);
                        "already disconnected" if the phone wasn't on it. Posts
                        ALWiFiJoinStateChangedNotification after every join/leave; the
                        detail page rebuilds its Join / Disconnect row from it. Used by the cell's
                        green lock.open badge, the detail page's "Join Network" row, and
                        the Current list's trailing "Join" swipe action
ALSpeedTest             download then upload vs speed.cloudflare.com (__down / __up, no
                        key); each phase time-boxed at 8s, Mbps measured from first byte;
                        allowsCellularAccess = NO so it always measures Wi-Fi
                        (__down caps at <100,000,000 bytes — larger returns HTTP 403;
                        non-2xx responses fail the test rather than scoring ~0 Mbps)
ALVendor                manufacturer lookups → info["Manufacturer"]: MAC OUI (Wi-Fi BSSID,
                        classic address; skipped for randomized/locally-administered MACs)
                        and BLE Company ID. Tables are "KEY\tName" files in Resources:
                        oui.txt (/24 entries from Wireshark's `manuf`) and company_ids.txt
                        (Bluetooth SIG company_identifiers.yaml); preloaded off-main at
                        launch. The All tab derives it for rows stored before it existed
ALAdvDecoder            BLE advertisement → "Device Kind" / "OS Family" + extras. Apple
                        Continuity TLVs (type,len,value; except 0x01 overflow, which has
                        no length byte): 0x07 AirPods (prefix 0x01 = model + batteries,
                        prefix 0x00 = model + the buds' classic BT address), 0x09
                        AirPlay (IP + port), 0x10 Nearby Info (activity), 0x12 Find My,
                        iBeacon, etc. Microsoft CDP beacon device type (Windows/Xbox/...),
                        Samsung/Google markers, known 16-bit service UUIDs. decodeStoredInfo
                        re-decodes rows from their stored hex (All tab, old rows)
ALWiFiIE                parses the scan result's "IE" property (raw CFData, [id][len][data],
                        SSID/rates stripped): Wi-Fi generation (HT/VHT/HE/EHT), channel
                        width, spatial streams, BSS Load (clients, utilization), country,
                        WPS attributes (make, model, device name, primary device type →
                        Device Kind), Wi-Fi Direct / Hotspot 2.0, vendor-element OUIs
ALStatusBar             status-bar carrier text via the user's CarrierText tweak
                        (com.shmank.carriertext): writes CarrierText into
                        /var/jb/var/mobile/Library/Preferences/com.shmank.carriertext.plist
                        (other keys: LoopTexts/LoopDelay) + notify_post
                        "com.shmank.carriertext/changed" (verified: the sandbox allows this
                        write); falls back to spawning the `carriertext` CLI if the write
                        is refused. Needs the tweak installed — without CarrierText.dylib
                        the status bar just shows the real carrier. Modes: nearby counts,
                        connected Wi-Fi, tracking one device's live RSSI (from the detail
                        page), plus speed-test transients. Picked from the Current tab's
                        left bar button; off sets the text to "" (like `carriertext set ""`,
                        carrier name hidden). Not persisted; if the app is killed while on,
                        the last text stays until changed with `carriertext`
ALMapViewController     WKWebView + Leaflet; computes position estimates, pushes via JS
Resources/map.html      Leaflet page; native calls window.updateData({u,pins}) every ~3s;
                        clusters all pins per zoom (buildClusters), draws the viewport (render());
                        focusPin(id) zooms to 18 (unclustered), centers + opens a popup; popup
                        shows "N dots stacked here" (pins within 3 m overlap even at max
                        zoom — why a "6" bubble can open to one visible dot) and Prev/Next,
                        which walk all pins by distance from the dot the walk started on
                        (order fixed while walking; a direct tap starts a new walk);
                        popup content is only built while open; "View Details"
                        posts the id to the `detail` message handler. A focused pin
                        (focusId) bypasses the map filters until refresh/filter change
ALLog.h                 file logger (no `log` CLI on iOS)
entitlements.plist      wifi.* + bluetooth.access/internal/system +
                        com.apple.developer.networking.HotspotConfiguration (joining)
```

## Data & estimation

- **DB schema** (`sightings`): `id, ts, type, identifier, name, rssi, channel, info(json),
  lat, lon, h_acc`. Inspect over SSH:
  `sqlite3 /var/mobile/Library/AirLogger/airlogger.sqlite "SELECT ..."`.
- **Storage policy** (`ALDatabase.recordDevice:` + `trimGeotagged:`), all types:
  - Writes throttled to once per identifier per 5s.
  - A new geotagged row is inserted only after moving `kMinMoveMeters` (10 m, or the fix's
    accuracy if worse) from that device's latest geotagged row. While stationary, that row
    is refreshed in place: ts/name/info updated, rssi EMA-smoothed (0.7 old / 0.3 new),
    lat/lon kept anchored so GPS drift can't creep. Idling at a desk = one row per device.
  - Fix-less sightings collapse to one row per device and don't count toward the cap.
  - Cap of 50 geotagged rows per identifier (`kMaxSightingsPerDevice`). Wi-Fi keeps its 10
    newest (`kKeepRecentWiFi`) plus the strongest of the rest (APs don't move; strong = close
    = accurate). Bluetooth keeps its newest (devices move with people).
  - `open` applies the cap/collapse once to pre-existing data (`trimAll`).
  - Consequence: `cnt` in `allDevices` means "places seen", not raw sightings. The UI
    labels it that way: devices loaded from the DB set `ALDevice.fromHistory`, so
    `sightingsText` reads "2 places" (All tab) vs "300 heard" (Current tab, which counts
    every live callback — BLE with duplicates allowed reports several per second).
- **Speed tests** (`speedtests`): `identifier (BSSID, PK), ssid, down_mbps, up_mbps, ts` —
  latest result per AP only (`INSERT OR REPLACE`). Wiped along with sightings. While a test
  runs, Wi-Fi scanning is held (`[wifi stop]`) because off-channel scans drag throughput
  down; it resumes on completion if the app is in scanning mode. A successful test also logs
  the AP as a sighting (only if its RSSI is < 0 — a 0 dBm row would skew the map estimate).
- **`type`** enum: 0 = Wi-Fi, 1 = BLE, 2 = Classic BT.
- **Identifier** is the stable key: BSSID (Wi-Fi), UUID (BLE), MAC (classic). Wi-Fi is
  grouped by SSID in the list only; the map keeps one pin per BSSID.
- **Position estimate** (in `ALMapViewController.computePinsJSON`): project observations to
  a local metric frame, compute an RSSI-weighted and recency-weighted centroid (τ≈1 day for
  Wi-Fi, 600s for BT: `kRecencyTauWiFi`/`kRecencyTauBT`), and upgrade to recency-weighted least-squares **multilateration** when `n>=3` and a
  distance cap holds. Path-loss model: `d = 10^((TxRef - rssi)/(10·n))`, `TxRef=-45`, `n=2.7`.
  It's approximate by nature (single-receiver RSSI). Note: the user removed stricter
  geometry guards in favor of the looser `n>=3` behavior, accepting that a strong nearby AP
  can be misplaced.
- **Recency-weight underflow (fixed — don't reintroduce).** The multilateration weights
  each observation by `exp(-age/τ)`. With data more than ~1 h old those weights underflow
  toward zero, shrinking the normal-equations matrix until its determinant falls below the
  `1e-3` cutoff, so *every* device silently falls back to the centroid. Fix: normalize the
  weights by their max before the solve (scaling all weights by a constant yields the same
  WLS solution but a sane determinant). Any future weighting change must keep the matrix
  well-scaled, or use a relative determinant threshold.
- **Map filters** (`ALMapViewController`): a `UIMenu` on the filter bar button filters pins
  by Type (Wi-Fi/BLE/Classic Bluetooth), Band (2.4/5/6 GHz), and Security (Open/WEP/WPA·WPA2/WPA3),
  applied natively in `computePinsJSON` before pushing. Band/security come from each
  device's stored `info` JSON via `allDevices`; security match is prefix-based.

## Conventions

- Objective-C, ARC (`-fobjc-arc`), `AL` class prefix, tabs for indentation.
- Match the surrounding style; keep private frameworks accessed via `dlopen`/runtime, never
  link-time.
- Never commit the SQLite DB or logs (they contain SSIDs + GPS traces) — `.gitignore`
  covers `*.sqlite`/`*.log`. Device IP stays in `Makefile.local` (gitignored).
