<p align="center">
  <img src="docs/otter-icon.png" width="200" alt="Otter app icon">
</p>

# 🦦 Otter

A lightweight native macOS menu bar app that quietly keeps your network drives connected.

Otter automatically reconnects SMB shares after sleep, network changes, VPN reconnects, or unexpected disconnects, so Finder, Plex, backup jobs, and other apps always have access to the volumes they expect.

Built entirely in Swift, Otter is designed to feel at home on macOS: fast, efficient, and unobtrusive.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="website/assets/otter-app-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="website/assets/otter-app-light.png">
    <img src="website/assets/otter-app-light.png" width="640" alt="Otter Manage Shares window showing share status and network conditions">
  </picture>
</p>

## Why "Otter"?

Otters are small, quick, and famously good at not letting important things drift away. This app does the same for your network volumes: it keeps a quiet paw on the shares you care about and nudges them back into place when sleep, Wi-Fi, or VPN tides pull them loose.

## Features

- 🦦 Native Swift & SwiftUI
- 📁 Automatic SMB share reconnection
- 🌙 Recovers after sleep and wake
- 🌐 Responds to network and VPN changes
- 📶 Per-share Wi-Fi and VPN rules
- 🛰️ Optional "connect when reachable" mode — mounts whenever the server answers
- 🧭 VPN IP fallback for `.local` or hostname-based shares when mDNS is not available over VPN
- 🔌 Optional Wake-on-LAN — wakes a sleeping server before retrying a mount
- ⚡ Lightweight with minimal resource usage
- 🔐 Keeps credentials in macOS Keychain — Otter never stores passwords in its settings or files
- 🚀 Launch at login
- 🪟 Choose whether Otter appears only in the menu bar, temporarily in the Dock, or always in both places
- 🔄 Automatic updates via Sparkle
- 🔔 Optional notifications for connection changes and problems
- 📊 Simple menu bar status
- 🍎 Designed to feel like a built-in macOS utility

No scripts. No daemons. No fuss.

Just an otter that never lets go.

## How it works

Otter watches for the moments shares tend to drop—wake from sleep, network path changes, volumes mounting or unmounting—and checks that each configured share is still where it should be. If one is missing, it remounts it using the native macOS NetFS APIs, with retry backoff when the server isn't reachable yet. Shares with Wake-on-LAN enabled send a magic packet before retrying an unreachable server. A low-frequency fallback check catches anything the system events miss.

Adding a share is easiest from Finder: mount it once the normal way, then let Otter import it with one click.

## Using Otter

1. Mount an SMB share in Finder.
2. Open Otter from the menu bar and choose **Add Share**.
3. Pick the mounted Finder share, then save it.
4. Optional: add a network condition, Wake-on-LAN details, or "connect when reachable" behavior.

Conditions are per share. When the network condition is on, Otter registers the network the share was configured on (its IPv4 subnet, plus the Wi-Fi name when available) and only connects while your Mac is back on that registered network — over Wi-Fi or Ethernet — or while a VPN is active. On any other network, Otter disconnects the share.

For hostname-based shares, Otter can cache the server's local IP address while you are on the local network. If your VPN cannot resolve Bonjour or `.local` names later, Otter can try that cached IP instead. To let macOS authenticate the IP-based fallback, Otter may create a scoped alias of the Finder-saved credential in macOS Keychain. Otter removes its alias when the cached IP changes or the share is deleted. This works best when the server has a static IP address.

## Requirements

- macOS 26.0 or later
- Matching by Wi-Fi name needs Location Services access (macOS only exposes Wi-Fi network names to apps with location permission — Otter will ask when needed). Subnet-based matching works without it.
- Local Network access may be requested so Otter can check server reachability

## Building

Open `Otter.xcodeproj` in Xcode and run the `Otter` scheme. The only dependency is [Sparkle](https://sparkle-project.org), fetched automatically via Swift Package Manager.

Run the tests with:

```sh
xcodebuild test -project Otter.xcodeproj -scheme Otter -destination 'platform=macOS'
```

## License

Otter is open source under the [MIT License](LICENSE). You're free to use, modify, and redistribute it — just keep the copyright notice, which credits the original app.
