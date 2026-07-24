//
//  PlaywrightInstaller.swift
//  MacON
//
//  Optional one-click setup for browser control — no terminal. Uses the Mac's
//  own Node.js to install Playwright + a Chromium into ~/Library/Application
//  Support/MacON/playwright, writes the bridge script BrowserBridge talks to,
//  and proves it launches. Entirely optional: without it the agent drives the
//  browser through the accessibility tree as before. Node is the one thing we
//  don't install (it's a system-wide dev tool); we detect it, including
//  nvm/fnm/asdf installs, and tell the user if it's missing.
//

import Foundation
import Observation

@MainActor
@Observable
final class PlaywrightInstaller {

    enum Stage: Equatable {
        case idle
        case installing        // npm install playwright
        case downloadingBrowser // playwright install chromium (~120 MB)
        case testing
        case done
        case failed(String)
    }

    private(set) var stage: Stage = .idle

    var busy: Bool {
        switch stage {
        case .installing, .downloadingBrowser, .testing: return true
        default: return false
        }
    }

    struct Fail: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    static let installDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacON/playwright", isDirectory: true)

    /// Installed = the bridge script and Playwright's node_modules are present.
    static var isInstalled: Bool {
        let dir = installDir
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("bridge.js").path)
            && FileManager.default.fileExists(atPath: dir.appendingPathComponent("node_modules/playwright").path)
            && nodePath() != nil
    }

    /// Node is a prerequisite we detect rather than install.
    static var nodeAvailable: Bool { nodePath() != nil }

    // MARK: Node discovery

    private static var cachedNode: String??      // outer optional = "resolved yet"

    /// Absolute path to `node`, checking the usual spots then a login shell
    /// (so nvm/fnm/asdf installs are found). Cached.
    static func nodePath() -> String? {
        if let cached = cachedNode { return cached }
        let fm = FileManager.default
        let direct = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        if let hit = direct.first(where: { fm.isExecutableFile(atPath: $0) }) {
            cachedNode = hit; return hit
        }
        // Ask a login shell — picks up version managers that live in the profile.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "command -v node"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do {
            try p.run(); p.waitUntilExit()
            let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let resolved = (!path.isEmpty && fm.isExecutableFile(atPath: path)) ? path : nil
            cachedNode = resolved
            return resolved
        } catch {
            cachedNode = .some(nil)
            return nil
        }
    }

    private static func binDir() -> String? {
        nodePath().map { ($0 as NSString).deletingLastPathComponent }
    }

    // MARK: Install

    func install() {
        guard !busy else { return }
        Task { await run() }
    }

    private func run() async {
        do {
            guard let node = Self.nodePath(), let binDir = Self.binDir() else {
                throw Fail("Node.js isn't installed. Install it from nodejs.org (or `brew install node`), then try again.")
            }
            let npm = binDir + "/npm"
            guard FileManager.default.isExecutableFile(atPath: npm) else {
                throw Fail("Found Node but not npm alongside it — reinstall Node.js.")
            }
            let dir = Self.installDir
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("profile"),
                                                    withIntermediateDirectories: true)

            // A minimal package.json so npm installs locally into our dir.
            let pkg = #"{"name":"macon-browser","private":true,"version":"1.0.0"}"#
            try pkg.write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
            try Self.bridgeScript.write(to: dir.appendingPathComponent("bridge.js"),
                                        atomically: true, encoding: .utf8)

            let env = ["PATH": binDir + ":/usr/bin:/bin:/usr/sbin:/sbin"]

            stage = .installing
            try await shell(npm, ["install", "playwright", "--no-audit", "--no-fund", "--loglevel=error"],
                            cwd: dir, env: env)

            stage = .downloadingBrowser
            let pw = dir.appendingPathComponent("node_modules/.bin/playwright").path
            try await shell(pw, ["install", "chromium"], cwd: dir, env: env)

            stage = .testing
            // Prove Playwright resolves and can launch, without opening a window.
            let test = "const {chromium}=require('playwright');(async()=>{const b=await chromium.launch();await b.close();console.log('ok');})().catch(e=>{console.error(e);process.exit(1);});"
            try await shell(node, ["-e", test], cwd: dir,
                            env: ["PATH": env["PATH"]!, "NODE_PATH": dir.appendingPathComponent("node_modules").path])
            stage = .done
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    func uninstall() {
        BrowserBridge.shared.stop()
        try? FileManager.default.removeItem(at: Self.installDir)
        stage = .idle
    }

    /// Run a process to completion; throw its stderr tail on non-zero exit.
    private func shell(_ launch: String, _ args: [String], cwd: URL, env: [String: String]) async throws {
        try await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: launch)
            p.arguments = args
            p.currentDirectoryURL = cwd
            p.environment = env
            p.standardOutput = Pipe()
            let errPipe = Pipe()
            p.standardError = errPipe
            try p.run()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()   // drains until exit
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                let tail = String(data: errData.suffix(400), encoding: .utf8) ?? ""
                let name = (launch as NSString).lastPathComponent
                throw Fail("\(name) failed (\(p.terminationStatus)). \(tail)")
            }
        }.value
    }

    // MARK: The bridge script

    /// Node program BrowserBridge drives: reads one JSON command per stdin
    /// line, keeps a visible Chromium open (persistent profile so logins
    /// stick), and replies with a page snapshot. All logging goes to stderr so
    /// stdout stays pure NDJSON.
    static let bridgeScript = #"""
const { chromium } = require('playwright');
const readline = require('readline');

let context = null, page = null;

async function ensure() {
  if (!context) {
    const dir = process.env.MACON_PROFILE || '.';
    context = await chromium.launchPersistentContext(dir, {
      headless: false,
      viewport: null,
      args: ['--start-maximized'],
    });
    page = context.pages()[0] || await context.newPage();
    context.on('page', p => { page = p; });   // follow new tabs/popups
  }
  if (!page || page.isClosed()) page = await context.newPage();
  return page;
}

// Tag every visible interactive element with a stable ref and return the list,
// plus the page's URL, title and visible text — the planner's "page tree".
async function snapshot() {
  const p = await ensure();
  try { await p.waitForLoadState('domcontentloaded', { timeout: 4000 }); } catch (e) {}
  return await p.evaluate(() => {
    const out = [];
    let i = 0;
    const q = 'a,button,input,textarea,select,[role=button],[role=link],[role=textbox],[role=tab],[role=menuitem],[role=checkbox],[contenteditable=""],[contenteditable=true]';
    for (const el of document.querySelectorAll(q)) {
      const r = el.getBoundingClientRect();
      if (r.width < 2 || r.height < 2) continue;
      const style = getComputedStyle(el);
      if (style.visibility === 'hidden' || style.display === 'none') continue;
      const tag = el.tagName.toLowerCase();
      const name = (el.getAttribute('aria-label') || el.innerText || el.value ||
                    el.placeholder || el.getAttribute('name') || el.getAttribute('title') || '')
                    .replace(/\s+/g, ' ').trim().slice(0, 90);
      const field = tag === 'input' || tag === 'textarea' || tag === 'select' ||
                    el.isContentEditable;
      if (!name && !field) continue;           // nameless link/button = noise
      const ref = 'e' + (++i);
      el.setAttribute('data-macon-ref', ref);
      out.push({ ref, role: el.getAttribute('role') || tag, name });
      if (i >= 120) break;
    }
    return {
      url: location.href,
      title: document.title,
      elements: out,
      text: (document.body ? document.body.innerText : '').replace(/\n{3,}/g, '\n\n').slice(0, 4000),
    };
  });
}

async function run(cmd) {
  const p = await ensure();
  const T = { timeout: 15000 };
  switch (cmd.cmd) {
    case 'goto':
      await p.goto(cmd.url, { waitUntil: 'domcontentloaded', timeout: 30000 });
      break;
    case 'click':
      if (cmd.ref) await p.click('[data-macon-ref="' + cmd.ref + '"]', T);
      else if (cmd.text) await p.getByText(cmd.text, { exact: false }).first().click(T);
      break;
    case 'type': {
      const loc = cmd.ref ? p.locator('[data-macon-ref="' + cmd.ref + '"]') : null;
      if (loc) { await loc.click(T); await loc.fill(String(cmd.text), T); }
      else { await p.keyboard.type(String(cmd.text)); }
      if (cmd.submit) await p.keyboard.press('Enter');
      break;
    }
    case 'press':
      await p.keyboard.press(cmd.key || 'Enter');
      break;
    case 'scroll':
      await p.mouse.wheel(0, cmd.dy || 400);
      break;
    case 'back':
      await p.goBack({ waitUntil: 'domcontentloaded', timeout: 15000 });
      break;
    case 'snapshot':
      break;
    default:
      throw new Error('unknown command ' + cmd.cmd);
  }
  try { await p.waitForLoadState('networkidle', { timeout: 3000 }); } catch (e) {}
  return await snapshot();
}

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', async (line) => {
  line = line.trim();
  if (!line) return;
  let cmd;
  try { cmd = JSON.parse(line); } catch (e) { return; }
  try {
    const result = await run(cmd);
    process.stdout.write(JSON.stringify({ id: cmd.id, ok: true, result }) + '\n');
  } catch (e) {
    process.stdout.write(JSON.stringify({ id: cmd.id, ok: false, error: String(e && e.message || e) }) + '\n');
  }
});
process.stdin.on('end', async () => { try { await context?.close(); } catch (e) {} process.exit(0); });
"""#
}
