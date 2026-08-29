# MeshDash

A native macOS desktop client for [Meshtastic](https://meshtastic.org). It does what
the iOS and Android apps do — messaging, node management, mapping, telemetry,
channels, and the full radio and module configuration surface — on a Mac, over
Bluetooth, your local network, or USB.

Built with SwiftUI and Swift 6 strict concurrency, against the upstream
`meshtastic/protobufs` definitions.

## Requirements

- macOS 26 or later
- Xcode 26 / Swift 6.2 toolchain

## Build and run

```bash
./Scripts/build-app.sh release
open build/MeshDash.app
```

The bundle matters: macOS only grants Bluetooth and notification access to a
signed app with an `Info.plist`, so `swift run` will not be able to reach a
radio over BLE. The script ad-hoc signs the bundle, which is enough for local
use. To sign with a real identity:

```bash
MESHDASH_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./Scripts/build-app.sh release
```

## Connecting

MeshDash speaks the Meshtastic client API over three transports, all of which
carry the same protocol:

| Transport | Discovery | Notes |
|---|---|---|
| **Bluetooth LE** | Live scan for the Meshtastic GATT service | The first connection asks for the radio's pairing code. Screenless devices use `123456`. |
| **Network (TCP)** | Bonjour `_meshtastic._tcp`, plus manual host entry | For radios joined to your WiFi or Ethernet, and for `meshtasticd`. Default port 4403. |
| **USB serial** | IORegistry scan, with USB product names | Uses the `0x94 0xC3` framed stream protocol and surfaces the device's debug log. |
| **Meshpoint gateway** | Manual address entry | Not the Meshtastic client API — see below. |

A radio you connect to is remembered, and MeshDash reconnects to it at launch
and after a dropped link, backing off between attempts.

## Meshpoint gateways

A [Meshpoint](https://meshradar.io) on the **Node** platform runs `meshtasticd`,
which serves the ordinary client API on port 4403 — connect to it from the
Network tab like any other networked radio.

A Meshpoint on the **Gateway** platform (SX1302/SX1303 concentrator: RAK V2,
SenseCap M1, RAK7248, Chameleon) is different. Its own stack owns the radio and
there is no 4403; it serves a REST and WebSocket dashboard API on port 8080
behind a JWT session. MeshDash has a dedicated transport for it that answers the
`want_config_id` handshake with synthesized `FromRadio` messages, so Messages,
Nodes, Map and Telemetry work exactly as they do with a radio — but sourced from
the concentrator, which hears everything in range rather than only what a single
transceiver picked up.

Sign in with your dashboard credentials from the Meshpoint tab of the connect
sheet. Only the session token is kept, in your login keychain; the password is
used for the one request and never stored.

Because a gateway is not a radio, some things are hidden while connected to one:

| Works | Hidden |
|---|---|
| Messages (channels and DMs), node list, map, telemetry | Traceroute |
| Identity (long/short name) | Module configuration |
| Region, preset, TX power, hop limit | Reboot, shutdown, factory reset, DFU |
| Gateway page: duty cycle, smart relay, router mode, MeshCore status | Channel editing and share links |

Two known limits: replayed message history stores the sender's display name
rather than a node id, so historical broadcasts are attributed by name lookup
(live messages carry the real sender); and telemetry history before the
connection is not backfilled — only the latest reading per node, plus everything
that arrives while connected.

## What it does

**Messaging** — channel and direct conversations, emoji tapbacks, quoted
replies, delivery state from routing ACKs (including the specific failure
reason), unread tracking, canned-message insertion, and notifications that
respect muted nodes and channels. Direct messages to a node with a public key
are end-to-end encrypted by the firmware and marked as such.

**Nodes** — the full node database with filtering and sorting, signal quality,
battery, hops away, and per-node detail covering identity, position with track
history, signal, device metrics, environment and air-quality sensors,
paxcounter readings, direct neighbours from the Neighbor Info module, and
traceroute history. Favourite, mute, ignore, remove, and request position,
node info or telemetry on demand.

**Map** — every node that reports a position, with precision circles that
reflect how much the sender deliberately fuzzed their location, movement
tracks, and shared waypoints.

**Telemetry** — charted history for all eight telemetry types the firmware
reports (device, environment, air quality, power, local stats, health, host,
traffic management), with every metric in each, persisted to disk.

**Channels** — all eight slots, key generation and validation, position
precision, MQTT uplink and downlink, and share links with a QR code you can
save. Importing a `meshtastic.org/e/#…` link applies the channel set and,
optionally, the LoRa configuration that came with it.

**Configuration** — every radio setting (Device, Position, Power, Network,
Display, LoRa, Bluetooth, Security) and all seventeen module configurations
(MQTT, Serial, External Notification, Store & Forward, Range Test, Telemetry,
Canned Messages, Audio, Remote Hardware, Neighbor Info, Ambient Lighting,
Detection Sensor, Paxcounter, Status Message, Traffic Management, TAK, Mesh
Beacon). Writes are wrapped in the firmware's begin/commit pair so the radio
reboots once rather than after every field.

**Device tools** — clock sync, ringtone, licensed-operator mode, reboot,
shutdown, OTA and DFU modes, node database reset, factory reset, and settings
backup and restore.

**Remote administration** — administering another node over the mesh, including
the session-passkey handshake the firmware requires.

**Diagnostics** — a live packet inspector for everything that does not fold into
a conversation, the device's own debug log, traceroute results with per-hop SNR
in both directions, waypoint management, and the radio's local statistics.

## Layout

```
Sources/
  MeshtasticProtobufs/   Generated from meshtastic/protobufs
  MeshtasticCore/        Transports, protocol engine, session, persistence
    Transport/           BLE, TCP, serial, stream framing, discovery
    Radio/               Client API handshake, commands, admin messages
    Session/             Live state, packet decoding, user actions
    Store/               SQLite persistence
    Model/, Util/        Domain types, display names, telemetry metrics
  MeshDashApp/           SwiftUI application
Scripts/
  build-app.sh           Build and sign MeshDash.app
  update-protobufs.sh    Regenerate the protobuf sources
  make-icon.sh           Regenerate the app icon
```

`MeshtasticCore` has no UI dependencies, so the protocol layer can be reused
outside the app.

## Regenerating the protobufs

```bash
brew install protobuf swift-protobuf
./Scripts/update-protobufs.sh          # or: ./Scripts/update-protobufs.sh v2.7.0
```

## Data

History lives in `~/Library/Application Support/MeshDash/MeshDash.sqlite`,
scoped per radio, so two radios do not blend their node databases or
conversations. Position and telemetry history is pruned to the retention window
set in Preferences; messages and nodes are kept until you delete them.

## A note on airtime

LoRa is a shared, very slow medium. Several settings in this app — shorter
broadcast intervals, higher hop limits, Router roles on a portable node, Range
Test, MQTT uplink — spend airtime that everyone on your mesh shares. The forms
say so where it matters.
