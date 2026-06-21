# Cassini

Cassini is a local Bluetooth client for the Oura Ring 4. It pairs with a ring you own and reads its
biometrics directly over BLE — no Oura account, no cloud, no network. It's an iOS app that runs
natively on Apple Silicon Macs (via "My Mac (Designed for iPad)"), built primarily as a tool for
exploring and debugging the ring's protocol.

## What the app does

- **Pairs and onboards a ring** — establishes the BLE bond, generates an auth key on-device (stored
  in the Keychain), and runs the per-connection authentication handshake. Reconnects afterward with
  the stored key, and detects/recovers from a stale pairing.
- **Shows live metrics** — a dashboard with tiles for heart rate, SpO₂, temperature, and battery,
  updated as the ring streams data.
- **Reads the accelerometer** — realtime x/y/z motion (milli-g).
- **Is a protocol cockpit** — a debug surface for poking at the ring:
  - an **Actions** panel with a button for every command (measurement triggers, feature
    enable/disable, battery, flush/GetEvent, time-sync, factory/bond reset) plus a raw-hex sender;
  - two live, copyable logs — a **raw** log (`ms · RX/TX · hex` for every frame in and out) and a
    **translated** log that decodes each frame to a human-readable line;
  - per-frame-type counts to see at a glance what the ring is sending.

Heart rate, SpO₂, HRV, and temperature decoders are implemented; clean computed heart rate is
delivered by the ring as history records (drained via GetEvent) rather than as a live stream.

## Running it

Needs Xcode on an Apple Silicon Mac.

1. Open `Cassini.xcodeproj`.
2. Select the **Cassini** target → Signing & Capabilities → set your **Team** (running
   "Designed for iPad" on a Mac requires the Mac to be registered in your provisioning profile).
3. Choose the **My Mac (Designed for iPad)** destination and run (⌘R).
4. On first launch, pick your ring and accept the system Bluetooth pairing dialog.

The iOS Simulator has no Bluetooth, so testing against a real ring requires this destination (or a
physical iOS device).

## How it's built

- **`CassiniCore`** — a platform-agnostic Swift package with the protocol logic: frame parsing,
  command builders, the AES handshake, and the per-event decoders. Pure functions, unit-tested with
  `cd CassiniCore && swift test`.
- **`Cassini`** — the iOS app: CoreBluetooth transport, the connect/authenticate/stream
  orchestration, and the SwiftUI dashboard and debug cockpit. Depends on `CassiniCore`.
