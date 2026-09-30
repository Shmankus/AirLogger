# AirLogger

A native iOS app for a **jailbroken iPhone** that passively scans the surrounding radio
environment — **Wi‑Fi** access points and **Bluetooth** devices — tags each sighting with
GPS, logs everything to a local database, and estimates each transmitter's physical
location on an interactive map.

Built as a personal reverse‑engineering / RF‑survey project (a self‑contained
[wardriving](https://en.wikipedia.org/wiki/Wardriving) tool) for an iPhone 7 running
iOS 15.2.1 with a rootless [Dopamine](https://github.com/opa334/Dopamine) jailbreak.
Written in Objective‑C against Apple's private frameworks using the
[Theos](https://theos.dev) build system.

> ⚠️ **Scope:** AirLogger only *listens* to signals every nearby device already
> broadcasts, and is intended to run on your own authorized hardware for personal
> research and learning. It never deauthenticates or interferes with any network or
> device, and only joins a Wi‑Fi network when you tap Join (open networks, or ones you've
> already saved in Settings).

## Screenshots

<!-- Add real screenshots here, e.g.:
| Device list | Detail | Map |
|---|---|---|
| ![list](docs/list.png) | ![detail](docs/detail.png) | ![map](docs/map.png) |
-->
_Add screenshots here — e.g. the Current scan list, the All/search tab, a device's detail view, and the map._

## Features

- **Live Wi‑Fi scanning** — SSID, BSSID, RSSI, channel, **band** (2.4/5 GHz),
  **security** (WPA3/WPA/WEP/WAPI/Open, plus Enterprise), **SNR**, and hidden‑network flag
  for every nearby access point.
- **Wi‑Fi beacon details** — parsed from each access point's raw 802.11 information
  elements: **Wi‑Fi generation** (4/5/6/7), channel width, spatial streams, **connected
  client count** and channel utilization (when broadcast), country, and the router's
  **WPS make, model and device type** (router, printer, TV, phone hotspot…).
- **Bluetooth LE scanning** — every advertising BLE device with live RSSI, local name,
  manufacturer data, service UUIDs/data and Tx power.
- **Classic Bluetooth scanning** — discoverable devices via the private `BluetoothManager`
  framework, with device class, connected/paired state, product name, vendor/product IDs,
  and battery where exposed.
- **Manufacturer lookup** — every device gets a vendor name: from the MAC address prefix
  (IEEE OUI list) for Wi‑Fi and Classic Bluetooth, and from the Bluetooth SIG company ID
  for BLE. Randomized addresses are recognized and skipped.
- **Device kind & OS family** — BLE advertisements are decoded into what the device is:
  Apple Continuity messages (iPhone/iPad/Mac, **AirPods model with left/right/case
  battery**, Apple Watch, **AirPlay receivers with their IP address**, Find My devices and
  AirTags, iBeacons, Handoff/AirDrop/hotspot), Microsoft beacons (Windows desktop/laptop,
  Xbox…), Google/Android and Samsung markers, and common services (Fast Pair, Tile,
  SmartTag, Eddystone, HID, heart‑rate).
- **Three tabs** — **Current** (what's around you right now: a **Live / Session** toggle
  in the nav bar and a **Wi‑Fi / BLE / Classic** picker with per‑type counts that stays
  pinned while you scroll, showing one type at a time), **All** (the full stored history
  with an **All / Wi‑Fi / BLE / Classic** picker, text search over name/address, and a
  **Latest / RSSI / Name** sort), and **Map**.
- **SSID grouping** — access points that share a network name collapse into one row in
  the list, with every individual BSSID still available in the detail view.
- **Clear counts** — the Current tab shows how many times a device was *heard* this
  session; the All tab shows how many distinct *places* it was logged at.
- **GPS‑tagged logging** — sightings are written to a local **SQLite** database with
  a timestamp and location, so history persists across app updates and reinstalls.
- **Bounded storage** — a device only gets a new row once you've moved ~10 m; while you
  stay put its existing row is refreshed in place, so leaving the app running at a desk
  doesn't pile up thousands of copies of your own network. Each device keeps at most 50
  located readings: Wi‑Fi keeps its 10 newest plus its strongest (access points don't move,
  and close readings are the most accurate), Bluetooth keeps its newest (devices travel).
- **Position estimation** — each transmitter is placed on the map using an
  RSSI‑weighted centroid, upgraded to **least‑squares multilateration** when enough
  observations from different vantage points are available. Recent readings are weighted
  more heavily — over about a day for Wi‑Fi, minutes for Bluetooth — so estimates converge
  as you move and track devices that relocate.
- **Connected network + speed test** — the Current tab shows the Wi‑Fi network you're
  joined to (SSID, band, channel, signal, last result) in a compact card with a **Speed
  Test** button; tap the card for its full details. It measures
  download and upload over Wi‑Fi only (Cloudflare's public speed‑test endpoints, ~8 s per
  direction), and the latest result is saved with that access point and shown on its
  detail page in All Devices.
- **Join and leave networks** — passwordless Wi‑Fi gets a green unlocked padlock, and
  secured networks already **saved in Settings** get a blue key; both can be joined by
  swiping in the Current tab or tapping **Join Network** on the detail page (saved ones use
  the password stored in Settings). While connected, the detail page offers **Disconnect
  from Network** instead, and reports if you'd already dropped off or iOS auto‑rejoined.
- **Interactive dark map** — an OpenStreetMap slippy map (Leaflet) with color‑coded,
  tappable pins that update live and animate smoothly toward refined positions. Dense
  areas merge into counted clusters that split apart as you zoom in, and only pins on
  screen are drawn, so it stays smooth with thousands of devices logged. Filter by
  type, band and security. **Show on Map** on a detail page jumps to that device's pin; a
  pin's popup has **View Details** to jump back, and **Prev / Next** to step through the
  nearest pins in order of distance (handy where several devices' dots overlap).
- **Status‑bar readout** — with the companion CarrierText tweak installed, the carrier
  name can show live info while you use other apps: nearby device counts (`W18 L29 C2`),
  the connected network and its signal, speed‑test progress, or **tracking** one device's
  signal strength (`▂▄▆· -58 AirPods`) to walk toward it.
- **Background operation** — keeps scanning and logging with the screen off via the
  Core Location background mode.

## How it works

The interesting engineering here is getting a sandboxed, ad‑hoc‑signed app to reach
capabilities iOS normally reserves for system processes, and working around the pieces of
the OS that simply aren't present on this device.

| Area | Approach |
|---|---|
| **Wi‑Fi scanning** | Apple removed the legacy `Apple80211*` C API; the current interface is the private `WiFiManagerClient` / `WiFiDeviceClient` family in `MobileWiFi.framework`. Symbols are discovered from the SDK's `.tbd` stub and resolved at runtime with `dlopen`/`dlsym`, so nothing is link‑time bound to a private framework. Scanning is async (`WiFiDeviceClientScanAsync`) with results parsed via `WiFiNetworkGetSSID/RSSI/Channel`. |
| **Wi‑Fi details** | Each scan result carries the AP's raw beacon information elements. These are walked as `[id][length][data]` records: HT/VHT/HE/EHT capability elements give the Wi‑Fi generation, streams and channel width; BSS Load gives client count; vendor elements expose WPS attributes (manufacturer, model, device type) and chipset OUIs. MobileWiFi's BSSID strings drop leading zeros, so they're normalized before use (and old rows are migrated). |
| **Classic Bluetooth** | The private `BluetoothManager` framework is driven for classic‑device discovery. Getting `bluetoothd` to deliver results to a sideloaded app required granting the privileged `com.apple.bluetooth.internal` / `com.apple.bluetooth.system` entitlements (embedded with `ldid`), which the jailbroken AMFI accepts. |
| **Bluetooth LE** | `bluetoothd`'s own logs (read with `oslog`) showed it treating the ad‑hoc‑signed app's session as backgrounded, and a background scan without a service filter receives nothing. Creating the `CBCentralManager` and starting the scan with CoreBluetooth's private *privileged daemon* options (resolved with `dlsym`) exempts the session, and advertisements arrive with live RSSI. They're then decoded following publicly reverse‑engineered formats (Apple Continuity, Microsoft CDP, OpenPods, OpenHaystack). |
| **Joining networks** | The public `NEHotspotConfiguration` API fails for this app with an unexplained error, so joining uses MobileWiFi's private association call on the network object from the last scan. For a network saved in Settings, the system Wi‑Fi daemon supplies the stored password itself — the app never sees it. The result is confirmed by checking the current network. |
| **Status bar** | The companion CarrierText tweak reads its text from a preferences plist and reloads on a Darwin notification. AirLogger writes that plist directly and posts the notification, re‑rendering once a second and writing only when the text changes. |
| **Persistence** | The app's own sandbox container is not writable under its entitlement set, so the SQLite database lives at a writable system path (`/var/mobile/Library/AirLogger/`) — which also lets it survive reinstalls and be inspected over SSH. Growth is bounded per device: rows are added only after ~10 m of movement (stationary sightings update the latest row in place, with smoothed RSSI), and a per‑type eviction policy caps each device at 50 located rows. |
| **Mapping** | `MKMapView` renders nothing on this device (the Maps app and its tile engine were removed, so MapKit never initializes a map session). The map is instead a `WKWebView` running **Leaflet**, pulling OSM tiles directly over HTTPS — bypassing MapKit entirely — and made dark with a CSS invert filter. Native code pushes fresh position estimates into the page via JavaScript, so pan/zoom and tiles are preserved between updates. |
| **Location estimation** | Observations are projected into a local metric frame; the estimate is an RSSI‑weighted centroid, or a recency‑weighted least‑squares multilateration (solved via the normal equations) when the geometry supports it, bounded by a sanity cap. |

## Requirements

- A jailbroken iOS device (developed against iOS 15.2.1, rootless Dopamine; arm64 / A10+).
- [Theos](https://theos.dev) with an iOS SDK.
- `ldid` (bundled with Theos) for entitlement signing.
- *Optional:* the CarrierText tweak (`com.shmank.carriertext`) for the status‑bar readout.

## Build & install

```sh
export THEOS=/opt/theos

# Set your device for over-the-air install (this file is gitignored):
cat > Makefile.local <<'EOF'
THEOS_DEVICE_IP = 192.168.x.x
THEOS_DEVICE_PORT = 22
THEOS_DEVICE_USER = root
EOF

make package   # build a rootless .deb into ./packages
make do         # build, install over SSH, and refresh the icon cache
```

The app installs to `/var/jb/Applications/AirLogger.app`. Entitlements are defined in
`entitlements.plist` and embedded at codesign time.

## Project structure

```
Sources/
  App/
    main.m                  Entry point
    ALAppDelegate           Tab bar (Current / All / Map) and cross-tab navigation
    ALLog.h                 File logger (iOS has no `log` CLI)
  UI/
    ALRootViewController    "Current" tab — live list with a Wi-Fi/BLE/Classic picker, the
                            connected Wi-Fi card, speed test, and the status-bar menu
    ALHistoryViewController "All" tab — full stored history with type picker, search + sort
    ALDetailViewController  Per-device field breakdown + Join/Disconnect, Track, Show on Map
    ALMapViewController     "Map" tab — WKWebView + Leaflet map, position estimation
    ALDeviceCell            Custom list cell (type icon, signal pill, open/saved badge)
  Scanning/
    ALWiFiScanner           Wi-Fi scanning, join (associate) and leave via the private
                            MobileWiFi API (dlopen/dlsym); saved-network lookup
    ALBluetoothScanner      Classic Bluetooth via BluetoothManager; BLE via CoreBluetooth
    ALLocationProvider      Core Location wrapper (foreground + background)
  Processing/
    ALAdvDecoder            BLE advertisement decoder (Apple, Microsoft, Google, Samsung…)
    ALWiFiIE                Parser for Wi-Fi beacon information elements (generation, WPS…)
    ALVendor                Manufacturer lookup: MAC OUI and Bluetooth SIG company IDs
  Data/
    ALDatabase              SQLite store for GPS-tagged sightings + latest speed test per AP
    ALDevice                Unified device model
  Actions/
    ALWiFiJoin              Open/saved-network detection, joining and disconnecting
    ALSpeedTest             Wi-Fi download/upload throughput test (Cloudflare endpoints)
    ALStatusBar             Live status-bar text through the CarrierText tweak
Resources/
  map.html                  The Leaflet map page (edit freely; data arrives via updateData())
  oui.txt                   MAC prefix → manufacturer (from Wireshark's manuf list)
  company_ids.txt           Bluetooth SIG company ID → name
```

The Makefile builds every `Sources/*/*.m` and adds each folder to the include path, so a
new file just goes in the right folder.

## Limitations & honest notes

- **Classic Bluetooth has no signal strength.** `BluetoothManager` doesn't expose RSSI for
  classic devices, so their map positions are a plain centroid of where they were seen.
- **BLE devices change identity.** Phones, earbuds and trackers rotate their Bluetooth
  address every ~15 minutes, and iOS gives each new address a new ID, so one phone can
  appear as several short‑lived entries.
- **Decoded device kinds are hints.** The advertisement formats are reverse‑engineered by
  the community, not documented, so unusual devices may be labelled loosely or not at all.
  Only access points are visible to Wi‑Fi scanning — not the clients connected to them.
- **Status‑bar text needs the CarrierText tweak**, a separate package; without it the
  carrier name is untouched.
- **Position estimates are approximate.** RSSI is noisy and affected by walls, orientation,
  and multipath. Estimates are best‑effort and improve dramatically with wider, more varied
  movement; a device only ever seen from one spot cannot be triangulated. This is a
  fundamental property of single‑receiver RSSI localization, not a bug.
- **Depends on private APIs and jailbreak entitlements**, so it is device/OS‑specific by
  nature and is not an App Store application.

## Tech stack

Objective‑C · UIKit · Core Location · CoreBluetooth · SQLite · WebKit + Leaflet ·
OpenStreetMap · private `MobileWiFi` / `BluetoothManager` frameworks · Theos · ldid

## Acknowledgements

- [Leaflet](https://leafletjs.com/) and [OpenStreetMap](https://www.openstreetmap.org/) for the map.
- [Theos](https://theos.dev) and the iOS jailbreak community for the toolchain and framework documentation.
- [Wireshark](https://www.wireshark.org/)'s `manuf` list and the
  [Bluetooth SIG](https://www.bluetooth.com/specifications/assigned-numbers/) assigned numbers
  for the manufacturer tables.
- The reverse‑engineering work behind the BLE decoders: furiousMAC's Apple Continuity
  research, [OpenPods](https://github.com/adolfintel/OpenPods), and
  [OpenHaystack](https://github.com/seemoo-lab/openhaystack).

## License

MIT — see [LICENSE](LICENSE). _(Add a LICENSE file if you haven't yet.)_
