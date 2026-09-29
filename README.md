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
> research and learning. It does not connect to, deauthenticate, or interfere with any
> network or device.

## Screenshots

<!-- Add real screenshots here, e.g.:
| Device list | Detail | Map |
|---|---|---|
| ![list](docs/list.png) | ![detail](docs/detail.png) | ![map](docs/map.png) |
-->
_Add screenshots here — e.g. the Current scan list, the All/search tab, a device's detail view, and the map._

## Features

- **Live Wi‑Fi scanning** — SSID, BSSID, RSSI, channel, **band** (2.4/5/6 GHz),
  **security** (WPA3/WPA/WEP/WAPI/Open, plus Enterprise), **SNR**, and hidden‑network flag
  for every nearby access point.
- **Bluetooth scanning** — discoverable classic Bluetooth devices via the private
  `BluetoothManager` framework, with device class, connected/paired state, product name,
  vendor/product IDs, and battery where exposed (BLE via `CoreBluetooth` is stubbed; see
  *Limitations*).
- **Three tabs** — **Current** (what's around you right now), **All** (the full stored
  history with text search over name/BSSID and a Wi‑Fi/BLE/BT filter), and **Map**.
- **SSID grouping** — access points that share a network name collapse into one row in
  the list, with every individual BSSID still available in the detail view.
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
  joined to (SSID, BSSID, band, channel, signal) with a **Speed Test** button. It measures
  download and upload over Wi‑Fi only (Cloudflare's public speed‑test endpoints, ~8 s per
  direction), and the latest result is saved with that access point and shown on its
  detail page in All Devices.
- **Join open networks** — passwordless Wi‑Fi gets a green unlocked‑padlock badge in the
  lists; swipe an open network in the Current tab (or tap **Join Network** on its detail
  page) to join it via `NEHotspotConfiguration`, with iOS's own confirmation prompt.
- **Interactive dark map** — an OpenStreetMap slippy map (Leaflet) with color‑coded,
  tappable pins that update live and animate smoothly toward refined positions.
- **Background operation** — keeps scanning and logging with the screen off via the
  Core Location background mode.

## How it works

The interesting engineering here is getting a sandboxed, ad‑hoc‑signed app to reach
capabilities iOS normally reserves for system processes, and working around the pieces of
the OS that simply aren't present on this device.

| Area | Approach |
|---|---|
| **Wi‑Fi scanning** | Apple removed the legacy `Apple80211*` C API; the current interface is the private `WiFiManagerClient` / `WiFiDeviceClient` family in `MobileWiFi.framework`. Symbols are discovered from the SDK's `.tbd` stub and resolved at runtime with `dlopen`/`dlsym`, so nothing is link‑time bound to a private framework. Scanning is async (`WiFiDeviceClientScanAsync`) with results parsed via `WiFiNetworkGetSSID/RSSI/Channel`. |
| **Bluetooth** | The private `BluetoothManager` framework is driven for classic‑device discovery. Getting `bluetoothd` to deliver results to a sideloaded app required granting the privileged `com.apple.bluetooth.internal` / `com.apple.bluetooth.system` entitlements (embedded with `ldid`), which the jailbroken AMFI accepts. |
| **Persistence** | The app's own sandbox container is not writable under its entitlement set, so the SQLite database lives at a writable system path (`/var/mobile/Library/AirLogger/`) — which also lets it survive reinstalls and be inspected over SSH. Growth is bounded per device: rows are added only after ~10 m of movement (stationary sightings update the latest row in place, with smoothed RSSI), and a per‑type eviction policy caps each device at 50 located rows. |
| **Mapping** | `MKMapView` renders nothing on this device (the Maps app and its tile engine were removed, so MapKit never initializes a map session). The map is instead a `WKWebView` running **Leaflet**, pulling OSM tiles directly over HTTPS — bypassing MapKit entirely — and made dark with a CSS invert filter. Native code pushes fresh position estimates into the page via JavaScript, so pan/zoom and tiles are preserved between updates. |
| **Location estimation** | Observations are projected into a local metric frame; the estimate is an RSSI‑weighted centroid, or a recency‑weighted least‑squares multilateration (solved via the normal equations) when the geometry supports it, bounded by a sanity cap. |

## Requirements

- A jailbroken iOS device (developed against iOS 15.2.1, rootless Dopamine; arm64 / A10+).
- [Theos](https://theos.dev) with an iOS SDK.
- `ldid` (bundled with Theos) for entitlement signing.

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
ALWiFiScanner           Wi-Fi scanning via the private MobileWiFi API (dlopen/dlsym)
ALBluetoothScanner      Classic Bluetooth via BluetoothManager; CoreBluetooth (BLE) scaffold
ALLocationProvider      Core Location wrapper (foreground + background)
ALDatabase              SQLite store for GPS-tagged sightings + latest speed test per AP
ALDevice                Unified device model
ALDeviceCell            Custom list cell (type icon, signal pill)
ALRootViewController    "Current" tab — live device list, grouped by radio type, plus
                        the connected Wi-Fi card and speed-test button
ALHistoryViewController "All" tab — full stored history with search + type filter
ALDetailViewController  Per-device field breakdown (incl. last speed test for Wi-Fi)
ALSpeedTest             Wi-Fi download/upload throughput test (Cloudflare endpoints)
ALWiFiJoin              Open-network detection + joining via NEHotspotConfiguration
ALMapViewController     "Map" tab — WKWebView + Leaflet map, position estimation
Resources/map.html      The Leaflet map page (edit freely; data arrives via updateData())
```

## Limitations & honest notes

- **BLE scanning is not functional.** iOS's `bluetoothd` refuses to deliver CoreBluetooth
  advertisement callbacks to this ad‑hoc‑signed, sideloaded app even with the radio
  authorized — so the BLE path is present but returns nothing. Classic Bluetooth (via the
  privileged `BluetoothManager` interface) works.
- **Position estimates are approximate.** RSSI is noisy and affected by walls, orientation,
  and multipath. Estimates are best‑effort and improve dramatically with wider, more varied
  movement; a device only ever seen from one spot cannot be triangulated. This is a
  fundamental property of single‑receiver RSSI localization, not a bug.
- **Depends on private APIs and jailbreak entitlements**, so it is device/OS‑specific by
  nature and is not an App Store application.

## Tech stack

Objective‑C · UIKit · Core Location · SQLite · WebKit + Leaflet · OpenStreetMap ·
private `MobileWiFi` / `BluetoothManager` frameworks · Theos · ldid

## Acknowledgements

- [Leaflet](https://leafletjs.com/) and [OpenStreetMap](https://www.openstreetmap.org/) for the map.
- [Theos](https://theos.dev) and the iOS jailbreak community for the toolchain and framework documentation.

## License

MIT — see [LICENSE](LICENSE). _(Add a LICENSE file if you haven't yet.)_
