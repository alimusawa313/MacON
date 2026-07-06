# MacON — a local Bitbucket runner POOL for your Mac

Turns this Mac into a shared self-hosted CI runner host for your team. It manages
**many runner agents at once** — typically one per Bitbucket repo/workspace — each
polling its own repo. When a teammate's pipeline runs a step tagged
`self.hosted` + `macos`, it executes here on your Mac. Like Bitrise, but local and
shared. MacON also cleans up build caches so the Mac doesn't fill up.

## How sharing works (important)

Bitbucket runners **poll outward**: the agent connects *from* your Mac *to*
Bitbucket. Bitbucket never connects into your Mac. So there is **no inbound server,
no open ports, nothing exposed to the internet.** For a teammate to use your Mac:

1. They add a runner in **their** repo (Settings → Runners → macOS/Linux shell) and
   send you the generated start command.
2. You add a runner in MacON (＋), paste that command, give it its own working
   directory, and Start it.
3. Their pipeline steps tagged `self.hosted` + `macos` now run on your Mac.

### ⚠️ Trust model: team only

A CI runner executes whatever is in the repo's pipeline — **arbitrary commands on
your Mac, as you** (your files, keychain, signing certs, SSH keys). There is no
isolation between a job and your account on a bare shell runner. Only add runners
for **repos and people you trust.** To safely let untrusted people share the Mac
you'd need per-job VM isolation (e.g. [Tart](https://tart.run)) — a different, much
larger setup.

## One-time setup on the Mac

```sh
xcode-select --install
sudo xcodebuild -license accept
brew install temurin        # Java — the runner agent needs it
brew install fastlane       # optional, common for iOS signing
```

## Using the pool

- **Add runner** (＋) → paste the start command → pick a **unique working
  directory** per runner so checkouts never collide → **Start**.
- **Start All / Stop All** and a live `X/Y running` count are in the sidebar and the
  ⚡ menu-bar icon.
- Each runner has its own live log, status dot, and controls.

## Route pipeline steps to this Mac

In each repo's `bitbucket-pipelines.yml`, tag steps:

```yaml
runs-on:
  - self.hosted
  - macos
```

See [bitbucket-pipelines.yml](bitbucket-pipelines.yml) for a sample. A real-world
example wired to the PlanPal iOS app lives in `planpal-ios-learner-2/`.

## Self-cleaning (two safe layers)

- **Per-runner, on stop** — empties only *that* runner's working directory. Safe to
  run while other runners are busy.
- **Shared machine caches** — DerivedData, SwiftPM caches, Archives, unavailable
  simulators live in `~/Library` and are shared by every runner, so MacON only
  cleans them via *Settings → Clean Caches Now*, and **only when all runners are
  stopped** (wiping DerivedData mid-build would corrupt an active job).
- **In-pipeline** — the `after-script` in your `bitbucket-pipelines.yml` can also
  clean at the end of each job (the safest moment).

## Two modes

MacON now has two independent ways to run CI on this Mac:

### 1. Bitbucket Runners (this Mac executes Bitbucket Pipelines jobs)
The pool described above. Bitbucket is the brain (parses YAML, schedules, shows
logs, gates PRs); your Mac is the hands. Needs `bitbucket-pipelines.yml` in the repo.

### 2. Local Pipelines (this Mac IS the CI — no Bitbucket Pipelines at all)
MacON polls a repo/branch, and when a new commit lands it clones that commit,
runs your build command here, and posts pass/fail back to the commit. No
`bitbucket-pipelines.yml`, no Atlassian runner, no inbound server.

Setup:
1. **Settings → Bitbucket account**: your Atlassian email + an API token (stored in
   the macOS Keychain). Used for polling, HTTPS clone, and status posting.
2. **Add pipeline** (＋ under *Local Pipelines*) → set workspace, repo slug, branch,
   a checkout directory, and the **build command** (your whole pipeline as shell,
   e.g. `bundle install && bundle exec fastlane test device:"iPhone 17 Pro"`).
3. **Start Watching** (polls every N seconds) or **Run Now** (build head immediately).

Build status shows up on Bitbucket commits/PRs as a check named after the pipeline.
Trade-off vs. mode 1: you own the pipeline definition, secrets (local env/keychain),
and there's a small poll delay — but nothing Bitbucket-Pipelines-side is involved.

## Notes / gotchas

- **Sandbox is off.** A sandboxed app can't spawn `xcodebuild` or delete caches, so
  App Sandbox is disabled for this target. Hardened Runtime stays on.
- **Stay logged in.** Simulators and code signing need your GUI login session —
  keep the Mac logged in and awake for CI to work.
- **No build isolation.** Shell runners execute on the bare host; `clean` before
  each build and let MacON wipe caches between sessions.
- **Signing headless.** If signing fails, unlock the login keychain in a pre-step
  (`security unlock-keychain`) or use fastlane `match` with a dedicated keychain.
- **Survive reboots.** Add the app to *System Settings → General → Login Items*.
