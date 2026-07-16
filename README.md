# MacOn

**Your Mac is the CI runner. Your phone is the remote.**

MacOn turns the Mac on your desk into a full local iOS CI runner — it watches a
Bitbucket or GitHub repo, builds every commit or PR through a `macon.yml`
pipeline, tests across simulators, and ships to TestFlight — with no metered
build minutes, no queue, and your code never leaving your machine. A companion
iPhone/iPad app then lets you monitor, stream, control, wake, and unlock that
Mac from anywhere.

Free and open source. Website: **[macon.devopsinstitute.id](https://macon.devopsinstitute.id)**

---

## What's in this repo

| Part | What it is |
|------|-----------|
| **MacOn.app** | The macOS app — configure pipelines, secrets, watch state, screen sharing, remote access, and power/access, all in a soft 3D "clay world" UI. |
| **`macon` CLI** | The same runner, headless, via Homebrew — for scripts, servers, and always-on machines. |
| **MaconKit** | The shared Swift package: the pipeline engine, git providers, the companion server, and the CLI. |

The [companion app](https://github.com/alimusawa313/MacON_Companion) lives in its
own repo.

## Install

**The app** — grab the latest [release](https://github.com/alimusawa313/MacON/releases) (macOS 14+).

**The CLI** — via Homebrew:

```sh
brew tap alimusawa313/macon https://github.com/alimusawa313/homebrew-macon
brew install macon
macon init          # check the toolchain + install what's missing
```

## Quick start

```sh
# poll a branch and build every new commit
macon watch --workspace acme --repo app --branch main

# or GitHub, instant, via webhook
macon watch --provider github --workspace org --repo app --webhook --port 8787

# build the current head once and exit 0/1 by result
macon trigger "My App" --follow
```

A pipeline lives in your repo as `macon.yml`:

```yaml
name: My App iOS CI
workflows:
  _setup:
    steps:
      - { name: Gems, script: bundle install }
      - { name: SwiftLint, script: swiftlint lint --strict }
  test:
    before_run: [_setup]
    steps:
      - name: UI Tests
        matrix:                      # fan out across device × OS
          device: ["iPhone 17 Pro", "iPad Air 11-inch (M4)"]
          os: ["26.4", "26.5"]
        script: bundle exec fastlane test device:"$MACON_MATRIX_DEVICE" os:"$MACON_MATRIX_OS"
  beta:
    before_run: [test]
    steps:
      - { name: TestFlight, script: bundle exec fastlane beta }
triggers:
  - { pull_request: "*", workflow: test }
  - { branch: main,      workflow: beta }
```

## Features

**CI, on your Mac**
- Watch Bitbucket or GitHub — a branch or open PRs, by polling or instant webhooks.
- Bitrise-style `macon.yml`: `before_run` chains, triggers, env, `run_if`, always-run steps.
- A test matrix that fans a step out across device × OS combinations.
- Builds any Apple platform (iOS, iPadOS, watchOS, tvOS, visionOS, macOS) and ships to TestFlight via fastlane.
- Runs as a `launchd` service that starts at login and restarts on crash.
- Scriptable: `status`, `trigger`, `logs`, `cancel`, `--json`, and a Prometheus `/metrics` endpoint.

**Remote powers (paired device, all opt-in)**
- Serve the companion over the LAN, or anywhere via a free Cloudflare tunnel.
- Screen sharing (hardware H.264) and remote control (cursor, keyboard, trackpad).
- **CompactOS** — fit a single app's window to the device and stream just that.
- **Power & Access** — keep the Mac awake, wake the display, and unlock the login screen with a Keychain-stored password.
- Optional **iCloud (CloudKit)** sync so a paired device auto-follows a rotated tunnel URL.
- A **privacy curtain** that walls off the physical screen while you drive it remotely.

**The look** — the app (and the [website](https://macon.devopsinstitute.id)) wear a
soft 3D clay world rendered with SceneKit, re-skinnable across a dozen themes.

## Security

A team-only trust model. Every remote power is **off by default** and gated behind
an explicit toggle. Secrets and the unlock password live in the macOS Keychain,
never in a repo; your code is only checked out on your own machine. A tunnel URL
alone grants nothing — pairing codes and device tokens are always required.

## Docs

Full guide at **[macon.devopsinstitute.id/docs](https://macon.devopsinstitute.id/docs)**;
the flag-by-flag CLI reference is [`MaconKit/CLI.md`](MaconKit/CLI.md).

## License

Open source, by [Ali Haidar](https://www.linkedin.com/in/ali-haidar-8484b8208).
