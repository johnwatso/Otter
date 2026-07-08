<p align="center">
  <img src="docs/otter-icon.png" width="200" alt="Otter app icon">
</p>

# 🦦 Otter

A lightweight native macOS menu bar app that quietly keeps your network drives connected.

Otter automatically reconnects SMB shares after sleep, network changes, VPN reconnects, or unexpected disconnects—so Finder, Plex, backup jobs, and other apps always have access to the volumes they expect.

Built entirely in Swift, Otter is designed to feel at home on macOS: fast, efficient, and unobtrusive.

## Features

- 🦦 Native Swift & SwiftUI
- 📁 Automatic SMB share reconnection
- 🌙 Recovers after sleep and wake
- 🌐 Responds to network and VPN changes
- 📶 Per-share rules — connect or disconnect based on Wi-Fi network or VPN
- ⚡ Lightweight with minimal resource usage
- 🔐 Uses macOS Keychain for credentials — Otter never stores them
- 🚀 Launch at login
- 🔔 Optional notifications for connection changes and problems
- 📊 Simple menu bar status
- 🍎 Designed to feel like a built-in macOS utility

No scripts. No daemons. No fuss.

Just an otter that never lets go.

## How it works

Otter watches for the moments shares tend to drop—wake from sleep, network path changes, volumes mounting or unmounting—and checks that each configured share is still where it should be. If one is missing, it remounts it using the native macOS NetFS APIs, with retry backoff when the server isn't reachable yet. A low-frequency fallback check catches anything the system events miss.

Adding a share is easiest from Finder: mount it once the normal way, then let Otter import it with one click.

## Requirements

- macOS 26.0 or later
- Wi-Fi based rules need Location Services access (macOS only exposes Wi-Fi network names to apps with location permission — Otter will ask when needed)

## Building

Open `Otter.xcodeproj` in Xcode and run the `Otter` scheme. No external dependencies.
