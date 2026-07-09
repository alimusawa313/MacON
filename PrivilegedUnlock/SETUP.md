# Privileged Unlock — setup (what *you* must do)

The Swift sources compile as a scaffold, but running the login-window unlock needs
code signing, an Apple entitlement, and installing a root daemon. None of that can
be done from this repo automatically — here's the checklist.

> **Before you start:** this only works with **FileVault off**, or after the first
> unlock (screen-lock, not cold boot). See ARCHITECTURE.md → "Hard limitation".

## 1. Get the entitlement
In the Apple Developer portal, your Team ID needs
**`com.apple.developer.hid.virtual.device`** enabled (request it from Apple if it
isn't already available). Add it to a provisioning profile / your signing config.
`MaconHelper.entitlements` already declares it.

## 2. Build the helper binary
```sh
cd MaconKit
swift build -c release --product macon-helper
# → .build/release/macon-helper
```

## 3. Sign it (Developer ID + entitlements + hardened runtime)
```sh
codesign --force --options runtime \
  --sign "Developer ID Application: YOUR NAME (TEAMID)" \
  --entitlements ../PrivilegedUnlock/MaconHelper.entitlements \
  .build/release/macon-helper
```

## 4. Install as a root LaunchDaemon
```sh
sudo cp .build/release/macon-helper /usr/local/libexec/macon-helper
sudo cp ../PrivilegedUnlock/com.macon.helper.plist /Library/LaunchDaemons/
sudo chown root:wheel /Library/LaunchDaemons/com.macon.helper.plist
sudo chmod 644 /Library/LaunchDaemons/com.macon.helper.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.macon.helper.plist
```
Check it's running and grab the pairing code:
```sh
sudo tail -f /var/log/macon-helper.log
```

## 5. Grant Screen Recording to the daemon (for the login-window view)
The daemon needs Screen Recording permission to stream the login window. Because
it's a daemon (no UI), pre-authorize it: System Settings → Privacy & Security →
Screen Recording → add `/usr/local/libexec/macon-helper`. (Capturing the
*loginwindow* itself may still be restricted — see the TODO in `Helper.swift`;
this is the least-certain part and may require the screen-capture work to run in a
LoginWindow-session agent instead of the daemon.)

## 6. Enable Wake for network access
System Settings → Battery / Energy → **Wake for network access**, so the iPad's
Wake-on-LAN packet can wake the Mac. Note the Mac's Wi-Fi/Ethernet MAC address
(`networksetup -getmacaddress en0`) — you enter it in the app to send the packet.

## 7. Pair the iPad with the daemon
The daemon runs its **own** pairing (separate from the app) on port **8900**. On
first boot it prints a code to `/var/log/macon-helper.log`. In the companion app,
add a runner pointing at `<mac-host>:8900` and enter that code.

## Uninstall
```sh
sudo launchctl bootout system /Library/LaunchDaemons/com.macon.helper.plist
sudo rm /Library/LaunchDaemons/com.macon.helper.plist /usr/local/libexec/macon-helper
```

## Reality check
- **Keyboard injection** via `IOHIDUserDevice` is SPI. It typically works from a
  signed+entitled root process, but Apple can change this between OS versions.
- **Login-window screen capture** from a daemon is the shakiest part; if it comes
  up black, the capture needs to move into a `LimitLoadToSessionType = LoginWindow`
  agent. That refactor is noted but not scaffolded here.
- Test on a spare/VM Mac first. You're installing a root daemon that can type into
  your login window — audit every line before signing.
