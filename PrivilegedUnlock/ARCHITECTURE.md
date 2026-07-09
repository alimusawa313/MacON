# Privileged Unlock — architecture (scaffold)

> **Status: scaffold on the `dev` branch.** The Swift sources here compile against
> MaconKit, but the feature does **not** run until you create the signed targets,
> request the entitlements, and install the daemon (see `SETUP.md`). It is
> deliberately kept off `main`.

## Goal

From the iPad, when the Mac is asleep or sitting at the **lock screen / login
window**: wake it, see the login screen, and type the password to log in.

## Why the normal app can't do it

The user-space `MacON.app` (where the companion server lives today) is suspended
at the login window, and macOS **Secure Event Input** rejects synthetic `CGEvent`
keystrokes at password fields. To cross those boundaries we need two things that
only privileged, hardware-level components can provide.

## The three pieces

```
 iPad  ──WoL magic packet──▶  Mac NIC (wakes)
 iPad  ──WSS (pair+token)──▶  macon-helper (root LaunchDaemon, always running)
                                 ├─ CompanionServer  (screen + control, from MaconKit)
                                 ├─ ScreenCapture    (captures the login window)
                                 └─ VirtualKeyboard  (IOHIDUserDevice → real HID reports)
                                                        └─ types the password at loginwindow
```

### 1. Wake-on-LAN  (iPad side — *works today*)
A magic packet (`FF*6` + MAC*16) sent to the LAN broadcast wakes a sleeping Mac
that has "Wake for network access" enabled. Implemented in the companion app
(`WakeOnLAN.swift`) — this is the one fully-working part.

### 2. `macon-helper` — a root LaunchDaemon
A background executable running as **root** in the system context, so it's alive
at the login window (unlike the user app). It hosts the same `CompanionServer`
(screen + control over WSS, token-paired) and owns the virtual keyboard. Because
it runs as root it has its **own** pairing store (under `/var/root/...`) — you
pair the iPad with the daemon separately from the app.

### 3. VirtualKeyboard — `IOHIDUserDevice`
The key trick. Secure Event Input filters *synthetic CGEvents*, but a **virtual
HID device** injects at the hardware-report layer, below that filter — so the
login window accepts it like a real USB keyboard. The daemon creates one via
`IOHIDUserDeviceCreate` (needs the `com.apple.developer.hid.virtual.device`
entitlement) and posts 8-byte boot-keyboard reports. Password characters sent
from the iPad (`text` control events) are translated to HID usages and typed.

> A DriverKit `HIDDriverKit` system extension is the heavier alternative; we use
> the userspace `IOHIDUserDevice` route because it needs only a developer-tier
> entitlement + root, not Apple DriverKit approval.

## Hard limitation: FileVault

On a FileVault Mac (the default), a **cold boot** stops at the pre-boot EFI unlock
screen where **macOS is not running** — no daemon, no network, nothing of ours
exists. You **cannot** remote-unlock FileVault pre-boot. This feature therefore
only works:
- with FileVault **off**, or
- **after** the first unlock, at the regular screen-lock loginwindow (the volume
  is already decrypted).

This is exactly the "experimental; not available in all configurations" caveat you
see on comparable apps.

## Data flow (unlock)

1. iPad sends WoL → Mac wakes to the lock screen.
2. iPad connects (WSS) to `macon-helper`, which is already paired → screen streams.
3. You focus the password field (tap/click via control), then type your password
   on the iPad keyboard → `text` events → `VirtualKeyboard` → HID reports → the
   login window authenticates → you're in.

## Security model

- The daemon is reachable only with a valid **device token** (same pairing as the
  app: single-use code, revocable).
- It can type anything a keyboard can — treat pairing like handing someone a
  physical keyboard to your locked Mac. Revoke lost devices immediately.
- Runs as root: audit the source, sign it yourself, and keep the tap on the LAN or
  behind your own tunnel.

## Files

| File | What |
|---|---|
| `MaconKit/Sources/macon-helper/main.swift` | the daemon entry point |
| `MaconKit/Sources/macon-helper/VirtualKeyboard.swift` | `IOHIDUserDevice` keyboard |
| `PrivilegedUnlock/com.macon.helper.plist` | LaunchDaemon definition |
| `PrivilegedUnlock/MaconHelper.entitlements` | required entitlements |
| `MacON_Companion/.../WakeOnLAN.swift` | iPad magic-packet sender |
| `SETUP.md` | signing + install steps you must do in Xcode/CLI |
