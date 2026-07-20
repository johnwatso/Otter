# Managed deployment

Otter can receive read-only shares and monitoring settings from a macOS MDM custom preferences payload. Use the application preference domain `io.github.johnwatso.Otter` and set a dictionary named `ManagedConfiguration`.

Managed shares appear alongside user-created shares with a **Managed** label. Users can mount, disconnect, retry, and temporarily pause them, but cannot edit or delete their managed configuration. Runtime state such as pause state and Otter's learned fallback address remains local to the Mac. If monitoring values are supplied, their controls are also read-only.

Credentials must not be included in the payload or SMB URL. During setup, use Otter's **Browse Shares** or **Test Setup** action and let macOS save the account in Keychain.

## Payload schema

The payload format is version 1:

```json
{
  "formatVersion": 1,
  "shares": [
    {
      "id": "92C3AA5A-B63D-4CEE-9689-C378B913631A",
      "displayName": "Production Files",
      "urlString": "smb://files.example.com/Production",
      "mountPath": "/Volumes/Production",
      "keepMounted": true,
      "mountAtLaunch": true,
      "autoConnectWhenReachable": true,
      "wakeOnLAN": {
        "isEnabled": false,
        "macAddress": "",
        "broadcastAddress": "255.255.255.255",
        "port": 9
      },
      "rules": {
        "wifiNetworkName": "",
        "registeredSubnets": [],
        "vpnRuleEnabled": true,
        "vpnName": "Company VPN"
      }
    }
  ],
  "monitoring": {
    "fallbackCheckInterval": 60,
    "recoverUnresponsiveMounts": false
  }
}
```

Use a stable, unique UUID for every share. A managed share replaces locally stored runtime data with the same UUID while preserving that runtime data. `monitoring` is optional; omit it to leave those preferences under user control.

`urlString` must be an SMB URL with a server and share path. Usernames and passwords in the URL cause the managed configuration to be rejected. A VPN connection path is valid only when `vpnRuleEnabled` is `true` and `vpnName` names the VPN Otter should connect or ask the user to open. For app-managed VPNs, a live tunnel triggers a reachability check because macOS does not expose the exact profile name to other apps. If the selected profile cannot be confirmed and the server is unavailable, Otter waits quietly so a different active VPN does not create a false connection error.

## Configuration profile example

The relevant `mcx_preference_settings` portion of a `com.apple.ManagedClient.preferences` payload is shown below. Most MDM products expose the same values through a Custom Settings editor instead of requiring a hand-written profile.

```xml
<key>PayloadContent</key>
<dict>
  <key>io.github.johnwatso.Otter</key>
  <dict>
    <key>Forced</key>
    <array>
      <dict>
        <key>mcx_preference_settings</key>
        <dict>
          <key>ManagedConfiguration</key>
          <dict>
            <key>formatVersion</key>
            <integer>1</integer>
            <key>shares</key>
            <array>
              <dict>
                <key>id</key>
                <string>92C3AA5A-B63D-4CEE-9689-C378B913631A</string>
                <key>displayName</key>
                <string>Production Files</string>
                <key>urlString</key>
                <string>smb://files.example.com/Production</string>
                <key>mountPath</key>
                <string>/Volumes/Production</string>
                <key>keepMounted</key>
                <true/>
                <key>mountAtLaunch</key>
                <true/>
                <key>autoConnectWhenReachable</key>
                <true/>
                <key>wakeOnLAN</key>
                <dict>
                  <key>isEnabled</key><false/>
                  <key>macAddress</key><string></string>
                  <key>broadcastAddress</key><string>255.255.255.255</string>
                  <key>port</key><integer>9</integer>
                </dict>
                <key>rules</key>
                <dict>
                  <key>wifiNetworkName</key><string></string>
                  <key>registeredSubnets</key><array/>
                  <key>vpnRuleEnabled</key><true/>
                  <key>vpnName</key><string>Company VPN</string>
                </dict>
              </dict>
            </array>
            <key>monitoring</key>
            <dict>
              <key>fallbackCheckInterval</key><real>60</real>
              <key>recoverUnresponsiveMounts</key><false/>
            </dict>
          </dict>
        </dict>
      </dict>
    </array>
  </dict>
</dict>
```

After the profile is installed or changed, relaunch Otter to load the updated managed configuration.
