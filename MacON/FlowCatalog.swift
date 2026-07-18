//
//  FlowCatalog.swift
//  MacON
//
//  The block catalog for the Mac's own Flows editor — the same 60 blocks the
//  companion draws, with the UI metadata the palette, node cards and
//  inspector render from. The wire shapes (Flow/FlowNode/…) live in
//  FlowModel.swift; this is purely the editor's vocabulary. Param keys stay
//  single-word lowercase so nothing mangles them on the wire.
//

import AppKit
import MaconKit

// MARK: - Cloud AI providers

/// Online providers a flow can call besides local Ollama. Keys live in this
/// Mac's Keychain and are handed to FlowEngine per run (it keeps them in
/// memory only, never on disk).
enum CloudAI {
    static let claudeModels: [(id: String, label: String)] = [
        ("claude-sonnet-5", "Claude Sonnet 5"),
        ("claude-opus-4-8", "Claude Opus 4.8"),
        ("claude-haiku-4-5-20251001", "Claude Haiku 4.5"),
    ]
    static let openaiModels: [(id: String, label: String)] = [
        ("gpt-5.1", "GPT-5.1"),
        ("gpt-5.1-mini", "GPT-5.1 mini"),
        ("gpt-4o", "GPT-4o"),
    ]
    static let geminiModels: [(id: String, label: String)] = [
        ("gemini-2.5-pro", "Gemini 2.5 Pro"),
        ("gemini-2.5-flash", "Gemini 2.5 Flash"),
    ]

    static var claudeKey: String {
        get { Keychain.get(account: "flows.anthropicKey") }
        set { Keychain.set(newValue, account: "flows.anthropicKey") }
    }
    static var openaiKey: String {
        get { Keychain.get(account: "flows.openaiKey") }
        set { Keychain.set(newValue, account: "flows.openaiKey") }
    }
    static var geminiKey: String {
        get { Keychain.get(account: "flows.geminiKey") }
        set { Keychain.set(newValue, account: "flows.geminiKey") }
    }

    /// Provider → key for the blocks this graph actually uses.
    static func keys(for flow: Flow) -> [String: String] {
        var out: [String: String] = [:]
        func put(_ provider: String, _ key: String) {
            if !key.isEmpty { out[provider] = key }
        }
        if flow.nodes.contains(where: { $0.type == "ai.claude" }) { put("anthropic", claudeKey) }
        if flow.nodes.contains(where: { $0.type == "ai.openai" }) { put("openai", openaiKey) }
        if flow.nodes.contains(where: { $0.type == "ai.gemini" }) { put("gemini", geminiKey) }
        return out
    }
}

// MARK: - Block catalog

enum BlockCategory: String, CaseIterable, Identifiable {
    case trigger, ai, apps, text, files, system, web, logic
    var id: String { rawValue }

    var label: String {
        switch self {
        case .trigger: return "Triggers"
        case .ai:      return "AI"
        case .apps:    return "Apps"
        case .text:    return "Text"
        case .files:   return "Files"
        case .system:  return "System"
        case .web:     return "Web"
        case .logic:   return "Logic"
        }
    }

    var symbol: String {
        switch self {
        case .trigger: return "bolt.fill"
        case .ai:      return "brain.head.profile"
        case .apps:    return "macwindow"
        case .text:    return "textformat"
        case .files:   return "folder.fill"
        case .system:  return "gearshape.2.fill"
        case .web:     return "globe"
        case .logic:   return "arrow.triangle.branch"
        }
    }

    /// The category's clay hue — the node card face and palette chip.
    func tint(_ box: WorldPalette) -> NSColor {
        switch self {
        case .trigger: return box.warm
        case .ai:      return box.primary
        case .apps:    return box.goodDeep
        case .text:    return box.slate
        case .files:   return box.good
        case .system:  return box.bad
        case .web:     return box.primaryDeep
        case .logic:   return box.warmDeep
        }
    }
}

struct BlockParam: Identifiable {
    enum Kind {
        case text
        case multiline
        case number
        case pick([String])
        case localModel            // installed Ollama models
        case visionModel           // only vision-capable local models
        case claudeModel           // Claude picker (+ key field)
        case openaiModel           // GPT picker (+ key field)
        case geminiModel           // Gemini picker (+ key field)
    }
    let key: String                // single-word lowercase
    let label: String
    let kind: Kind
    var fallback: String = ""      // what the engine assumes when unset
    var placeholder: String = ""
    var id: String { key }
}

struct BlockSpec: Identifiable {
    let type: String
    let title: String
    let blurb: String              // one line under the name in the palette
    let category: BlockCategory
    let symbol: String
    var ports: [String] = ["out"]  // output ports; If branches true/false
    var hasInput = true            // triggers are sources
    var params: [BlockParam] = []
    var id: String { type }

    /// `{{input}}` hint shown in the inspector for template-ish params.
    static let templateHint = "{{input}} inserts the incoming text"

    // MARK: The catalog

    static let all: [BlockSpec] = [
        // Triggers
        BlockSpec(type: "trigger.manual", title: "Manual Start",
                  blurb: "Fires when you press Run",
                  category: .trigger, symbol: "play.fill", hasInput: false,
                  params: [BlockParam(key: "payload", label: "Starting text",
                                      kind: .multiline, placeholder: "Optional text the flow starts with")]),
        BlockSpec(type: "trigger.schedule", title: "Schedule",
                  blurb: "Runs every N minutes",
                  category: .trigger, symbol: "clock.fill", hasInput: false,
                  params: [BlockParam(key: "interval", label: "Every (minutes)",
                                      kind: .number, fallback: "60")]),
        BlockSpec(type: "trigger.daily", title: "Every Day At",
                  blurb: "Runs daily at a set time",
                  category: .trigger, symbol: "alarm.fill", hasInput: false,
                  params: [BlockParam(key: "time", label: "Time (24h)",
                                      kind: .text, fallback: "09:00")]),
        BlockSpec(type: "trigger.watch", title: "Watch Folder",
                  blurb: "Fires when new files appear",
                  category: .trigger, symbol: "eye.fill", hasInput: false,
                  params: [BlockParam(key: "path", label: "Folder on the Mac",
                                      kind: .text, placeholder: "~/Downloads")]),

        // AI
        BlockSpec(type: "ai.ollama", title: "Local AI",
                  blurb: "Any Ollama model, your prompt",
                  category: .ai, symbol: "cpu.fill",
                  params: [BlockParam(key: "model", label: "Model", kind: .localModel),
                           BlockParam(key: "system", label: "System prompt", kind: .multiline,
                                      placeholder: "Optional behavior instructions"),
                           BlockParam(key: "prompt", label: "Prompt", kind: .multiline,
                                      fallback: "{{input}}", placeholder: templateHint)]),
        BlockSpec(type: "ai.claude", title: "Claude",
                  blurb: "Anthropic's models, your key",
                  category: .ai, symbol: "sparkles",
                  params: [BlockParam(key: "model", label: "Model", kind: .claudeModel,
                                      fallback: "claude-sonnet-5"),
                           BlockParam(key: "system", label: "System prompt", kind: .multiline,
                                      placeholder: "Optional behavior instructions"),
                           BlockParam(key: "prompt", label: "Prompt", kind: .multiline,
                                      fallback: "{{input}}", placeholder: templateHint)]),
        BlockSpec(type: "ai.summarize", title: "Summarize",
                  blurb: "Boil the input down",
                  category: .ai, symbol: "text.line.first.and.arrowtriangle.forward",
                  params: [BlockParam(key: "model", label: "Model", kind: .localModel),
                           BlockParam(key: "length", label: "Length",
                                      kind: .pick(["short", "medium", "long"]), fallback: "short")]),
        BlockSpec(type: "ai.translate", title: "Translate",
                  blurb: "Into any language",
                  category: .ai, symbol: "character.bubble",
                  params: [BlockParam(key: "model", label: "Model", kind: .localModel),
                           BlockParam(key: "language", label: "Into", kind: .text,
                                      fallback: "English")]),
        BlockSpec(type: "ai.classify", title: "Classify",
                  blurb: "Pick one label for the input",
                  category: .ai, symbol: "tag.fill",
                  params: [BlockParam(key: "model", label: "Model", kind: .localModel),
                           BlockParam(key: "labels", label: "Labels (comma-separated)", kind: .text,
                                      fallback: "positive, negative, neutral")]),
        BlockSpec(type: "ai.extract", title: "Extract JSON",
                  blurb: "Pull structured fields out",
                  category: .ai, symbol: "curlybraces",
                  params: [BlockParam(key: "model", label: "Model", kind: .localModel),
                           BlockParam(key: "fields", label: "Fields (comma-separated)", kind: .text,
                                      fallback: "title, date, summary")]),
        BlockSpec(type: "ai.openai", title: "ChatGPT",
                  blurb: "OpenAI's models, your key",
                  category: .ai, symbol: "circle.hexagongrid.fill",
                  params: [BlockParam(key: "model", label: "Model", kind: .openaiModel,
                                      fallback: "gpt-5.1"),
                           BlockParam(key: "system", label: "System prompt", kind: .multiline,
                                      placeholder: "Optional behavior instructions"),
                           BlockParam(key: "prompt", label: "Prompt", kind: .multiline,
                                      fallback: "{{input}}", placeholder: templateHint)]),
        BlockSpec(type: "ai.gemini", title: "Gemini",
                  blurb: "Google's models, your key",
                  category: .ai, symbol: "diamond.fill",
                  params: [BlockParam(key: "model", label: "Model", kind: .geminiModel,
                                      fallback: "gemini-2.5-flash"),
                           BlockParam(key: "system", label: "System prompt", kind: .multiline,
                                      placeholder: "Optional behavior instructions"),
                           BlockParam(key: "prompt", label: "Prompt", kind: .multiline,
                                      fallback: "{{input}}", placeholder: templateHint)]),
        BlockSpec(type: "ai.rewrite", title: "Rewrite",
                  blurb: "Formal, casual, shorter…",
                  category: .ai, symbol: "wand.and.stars",
                  params: [BlockParam(key: "model", label: "Model", kind: .localModel),
                           BlockParam(key: "style", label: "Make it",
                                      kind: .pick(["shorter", "longer", "formal", "casual", "bullets"]),
                                      fallback: "shorter")]),
        BlockSpec(type: "ai.vision", title: "Describe Image",
                  blurb: "Input is an image path",
                  category: .ai, symbol: "photo.fill",
                  params: [BlockParam(key: "model", label: "Vision model", kind: .visionModel),
                           BlockParam(key: "prompt", label: "Ask about it", kind: .multiline,
                                      fallback: "Describe this image.")]),

        // Apps
        BlockSpec(type: "app.shortcut", title: "Run Shortcut",
                  blurb: "Apple Shortcuts, input piped in",
                  category: .apps, symbol: "square.2.layers.3d.fill",
                  params: [BlockParam(key: "name", label: "Shortcut name", kind: .text,
                                      placeholder: "My Shortcut")]),
        BlockSpec(type: "app.launch", title: "Launch App",
                  blurb: "Open a Mac app",
                  category: .apps, symbol: "app.fill",
                  params: [BlockParam(key: "app", label: "App name", kind: .text,
                                      placeholder: "Safari")]),
        BlockSpec(type: "app.quit", title: "Quit App",
                  blurb: "Close a Mac app",
                  category: .apps, symbol: "xmark.app.fill",
                  params: [BlockParam(key: "app", label: "App name", kind: .text)]),
        BlockSpec(type: "app.front", title: "Frontmost App",
                  blurb: "What's on the Mac now",
                  category: .apps, symbol: "macwindow.on.rectangle"),
        BlockSpec(type: "app.music", title: "Music",
                  blurb: "Play, pause, skip",
                  category: .apps, symbol: "music.note",
                  params: [BlockParam(key: "action", label: "Do",
                                      kind: .pick(["playpause", "play", "pause", "next", "previous"]),
                                      fallback: "playpause")]),
        BlockSpec(type: "app.safari", title: "Safari Tab",
                  blurb: "Front tab's title & URL",
                  category: .apps, symbol: "safari.fill"),
        BlockSpec(type: "app.finder", title: "Finder Selection",
                  blurb: "Selected files, as paths",
                  category: .apps, symbol: "rectangle.and.hand.point.up.left.fill"),

        // Text
        BlockSpec(type: "text.template", title: "Compose",
                  blurb: "Write around the input",
                  category: .text, symbol: "square.and.pencil",
                  params: [BlockParam(key: "template", label: "Template", kind: .multiline,
                                      fallback: "{{input}}", placeholder: templateHint)]),
        BlockSpec(type: "text.replace", title: "Find & Replace",
                  blurb: "Swap every occurrence",
                  category: .text, symbol: "arrow.2.squarepath",
                  params: [BlockParam(key: "find", label: "Find", kind: .text),
                           BlockParam(key: "replace", label: "Replace with", kind: .text)]),
        BlockSpec(type: "text.regex", title: "Extract (Regex)",
                  blurb: "Keep what the pattern matches",
                  category: .text, symbol: "asterisk",
                  params: [BlockParam(key: "pattern", label: "Pattern", kind: .text,
                                      placeholder: #"e.g. \d+ or "([^"]+)""#)]),
        BlockSpec(type: "text.case", title: "Change Case",
                  blurb: "UPPER, lower or Title",
                  category: .text, symbol: "textformat.size",
                  params: [BlockParam(key: "mode", label: "Case",
                                      kind: .pick(["upper", "lower", "title"]), fallback: "upper")]),
        BlockSpec(type: "text.join", title: "Join Lines",
                  blurb: "Lines → one line",
                  category: .text, symbol: "arrow.right.to.line",
                  params: [BlockParam(key: "separator", label: "Separator", kind: .text,
                                      fallback: ", ")]),
        BlockSpec(type: "text.trim", title: "Trim",
                  blurb: "Strip surrounding whitespace",
                  category: .text, symbol: "scissors"),
        BlockSpec(type: "text.sort", title: "Sort Lines",
                  blurb: "Alphabetical, either way",
                  category: .text, symbol: "arrow.up.arrow.down",
                  params: [BlockParam(key: "order", label: "Order",
                                      kind: .pick(["az", "za"]), fallback: "az")]),
        BlockSpec(type: "text.unique", title: "Unique Lines",
                  blurb: "Drop the duplicates",
                  category: .text, symbol: "rectangle.compress.vertical"),
        BlockSpec(type: "text.first", title: "First Lines",
                  blurb: "Keep the top N",
                  category: .text, symbol: "list.number",
                  params: [BlockParam(key: "count", label: "How many", kind: .number,
                                      fallback: "5")]),
        BlockSpec(type: "text.base64", title: "Base64",
                  blurb: "Encode or decode",
                  category: .text, symbol: "lock.rectangle",
                  params: [BlockParam(key: "mode", label: "Direction",
                                      kind: .pick(["encode", "decode"]), fallback: "encode")]),
        BlockSpec(type: "text.date", title: "Date & Time",
                  blurb: "Now, formatted",
                  category: .text, symbol: "calendar",
                  params: [BlockParam(key: "format", label: "Format",
                                      kind: .pick(["datetime", "date", "time", "iso", "unix"]),
                                      fallback: "datetime")]),
        BlockSpec(type: "text.stats", title: "Word Count",
                  blurb: "Characters, words, lines",
                  category: .text, symbol: "number"),

        // Files
        BlockSpec(type: "file.read", title: "Read File",
                  blurb: "Text or PDF from the Mac",
                  category: .files, symbol: "doc.text.fill",
                  params: [BlockParam(key: "path", label: "Path (or use input)", kind: .text,
                                      placeholder: "~/Documents/notes.txt")]),
        BlockSpec(type: "file.write", title: "Write File",
                  blurb: "Save the input to disk",
                  category: .files, symbol: "square.and.arrow.down.fill",
                  params: [BlockParam(key: "path", label: "Path", kind: .text,
                                      placeholder: "~/Desktop/output.txt")]),
        BlockSpec(type: "file.append", title: "Append to File",
                  blurb: "Add the input to the end",
                  category: .files, symbol: "text.append",
                  params: [BlockParam(key: "path", label: "Path", kind: .text,
                                      placeholder: "~/Desktop/log.txt")]),
        BlockSpec(type: "file.list", title: "List Folder",
                  blurb: "File names, one per line",
                  category: .files, symbol: "folder.fill",
                  params: [BlockParam(key: "path", label: "Folder", kind: .text, fallback: "~")]),
        BlockSpec(type: "file.move", title: "Move File",
                  blurb: "Relocate or rename",
                  category: .files, symbol: "arrowshape.turn.up.right.fill",
                  params: [BlockParam(key: "from", label: "From (or use input)", kind: .text),
                           BlockParam(key: "to", label: "To", kind: .text,
                                      placeholder: "~/Documents/sorted/")]),
        BlockSpec(type: "file.copy", title: "Copy File",
                  blurb: "Duplicate somewhere",
                  category: .files, symbol: "doc.on.doc.fill",
                  params: [BlockParam(key: "from", label: "From (or use input)", kind: .text),
                           BlockParam(key: "to", label: "To", kind: .text)]),
        BlockSpec(type: "file.trash", title: "Move to Trash",
                  blurb: "Recoverable delete",
                  category: .files, symbol: "trash.fill",
                  params: [BlockParam(key: "path", label: "Path (or use input)", kind: .text)]),

        // System
        BlockSpec(type: "sys.shell", title: "Shell Command",
                  blurb: "zsh on the Mac",
                  category: .system, symbol: "terminal.fill",
                  params: [BlockParam(key: "command", label: "Command", kind: .multiline,
                                      placeholder: "e.g. git -C ~/Project status\n" + templateHint),
                           BlockParam(key: "timeout", label: "Timeout (seconds)", kind: .number,
                                      fallback: "120")]),
        BlockSpec(type: "sys.applescript", title: "AppleScript",
                  blurb: "Drive Mac apps",
                  category: .system, symbol: "applescript.fill",
                  params: [BlockParam(key: "script", label: "Script", kind: .multiline,
                                      placeholder: "tell application \"Music\" to play")]),
        BlockSpec(type: "sys.clipboard.get", title: "Read Clipboard",
                  blurb: "The Mac's copied text",
                  category: .system, symbol: "doc.on.clipboard"),
        BlockSpec(type: "sys.clipboard.set", title: "Set Clipboard",
                  blurb: "Copy the input on the Mac",
                  category: .system, symbol: "doc.on.doc.fill"),
        BlockSpec(type: "sys.notify", title: "Notification",
                  blurb: "Banner on the Mac",
                  category: .system, symbol: "bell.badge.fill",
                  params: [BlockParam(key: "title", label: "Title", kind: .text,
                                      fallback: "MacON Flow")]),
        BlockSpec(type: "sys.speak", title: "Speak",
                  blurb: "The Mac reads it aloud",
                  category: .system, symbol: "speaker.wave.2.fill",
                  params: [BlockParam(key: "voice", label: "Voice (optional)", kind: .text,
                                      placeholder: "Samantha")]),
        BlockSpec(type: "sys.open", title: "Open",
                  blurb: "A URL, file or app",
                  category: .system, symbol: "arrow.up.forward.app.fill",
                  params: [BlockParam(key: "target", label: "URL / path / app name", kind: .text,
                                      placeholder: "Leave empty to open the input")]),
        BlockSpec(type: "sys.screenshot", title: "Screenshot",
                  blurb: "Capture the Mac's screen",
                  category: .system, symbol: "camera.viewfinder",
                  params: [BlockParam(key: "path", label: "Save to", kind: .text,
                                      placeholder: "~/Desktop/shot.png")]),
        BlockSpec(type: "sys.volume", title: "Set Volume",
                  blurb: "The Mac's output level",
                  category: .system, symbol: "speaker.wave.3.fill",
                  params: [BlockParam(key: "level", label: "Level (0–100)", kind: .number,
                                      fallback: "50")]),
        BlockSpec(type: "sys.sleepdisplay", title: "Sleep Display",
                  blurb: "Screen off, Mac stays up",
                  category: .system, symbol: "moon.fill"),
        BlockSpec(type: "sys.info", title: "System Info",
                  blurb: "Host, uptime, battery, disk",
                  category: .system, symbol: "info.circle.fill"),

        // Web
        BlockSpec(type: "web.get", title: "HTTP GET",
                  blurb: "Fetch a URL from the Mac",
                  category: .web, symbol: "arrow.down.circle.fill",
                  params: [BlockParam(key: "url", label: "URL (or use input)", kind: .text,
                                      placeholder: "https://…")]),
        BlockSpec(type: "web.post", title: "HTTP POST",
                  blurb: "Send the input somewhere",
                  category: .web, symbol: "arrow.up.circle.fill",
                  params: [BlockParam(key: "url", label: "URL", kind: .text,
                                      placeholder: "https://…"),
                           BlockParam(key: "body", label: "Body", kind: .multiline,
                                      fallback: "{{input}}", placeholder: templateHint),
                           BlockParam(key: "format", label: "Content type",
                                      kind: .pick(["json", "text"]), fallback: "json")]),
        BlockSpec(type: "web.download", title: "Download",
                  blurb: "URL → file on the Mac",
                  category: .web, symbol: "square.and.arrow.down.on.square.fill",
                  params: [BlockParam(key: "url", label: "URL (or use input)", kind: .text),
                           BlockParam(key: "path", label: "Save to", kind: .text,
                                      placeholder: "~/Downloads/…")]),
        BlockSpec(type: "web.rss", title: "RSS Headlines",
                  blurb: "Latest titles from a feed",
                  category: .web, symbol: "dot.radiowaves.up.forward",
                  params: [BlockParam(key: "url", label: "Feed URL", kind: .text,
                                      placeholder: "https://hnrss.org/frontpage"),
                           BlockParam(key: "count", label: "How many", kind: .number,
                                      fallback: "10")]),
        BlockSpec(type: "web.json", title: "Pick from JSON",
                  blurb: "Dig a field out of the input",
                  category: .web, symbol: "curlybraces.square",
                  params: [BlockParam(key: "path", label: "Path", kind: .text,
                                      placeholder: "items.0.title")]),

        // Logic
        BlockSpec(type: "logic.if", title: "If",
                  blurb: "Branch on a condition",
                  category: .logic, symbol: "arrow.triangle.branch",
                  ports: ["true", "false"],
                  params: [BlockParam(key: "mode", label: "Condition",
                                      kind: .pick(["contains", "equals", "matches", "nonempty"]),
                                      fallback: "contains"),
                           BlockParam(key: "value", label: "Value / pattern", kind: .text)]),
        BlockSpec(type: "logic.filter", title: "Filter Lines",
                  blurb: "Keep only matching lines",
                  category: .logic, symbol: "line.3.horizontal.decrease",
                  params: [BlockParam(key: "mode", label: "Keep lines that",
                                      kind: .pick(["contains", "matches"]), fallback: "contains"),
                           BlockParam(key: "value", label: "Value / pattern", kind: .text)]),
        BlockSpec(type: "logic.loop", title: "For Each Line",
                  blurb: "Run the \"each\" branch per line",
                  category: .logic, symbol: "repeat",
                  ports: ["each", "done"]),
        BlockSpec(type: "logic.repeat", title: "Repeat",
                  blurb: "Run the \"each\" branch N times",
                  category: .logic, symbol: "arrow.clockwise",
                  ports: ["each", "done"],
                  params: [BlockParam(key: "times", label: "Times", kind: .number,
                                      fallback: "3")]),
        BlockSpec(type: "logic.delay", title: "Wait",
                  blurb: "Pause, then pass along",
                  category: .logic, symbol: "hourglass",
                  params: [BlockParam(key: "seconds", label: "Seconds", kind: .number,
                                      fallback: "2")]),
        BlockSpec(type: "logic.merge", title: "Merge",
                  blurb: "Wait for several branches",
                  category: .logic, symbol: "arrow.triangle.merge"),
    ]

    private static let byType = Dictionary(uniqueKeysWithValues: all.map { ($0.type, $0) })

    /// Lookup that always answers — unknown types render as a generic block
    /// instead of crashing the canvas.
    static func spec(_ type: String) -> BlockSpec {
        byType[type] ?? BlockSpec(type: type, title: type, blurb: "Unknown block",
                                  category: .logic, symbol: "questionmark.square.dashed")
    }

    static var grouped: [(category: BlockCategory, blocks: [BlockSpec])] {
        BlockCategory.allCases.map { cat in (cat, all.filter { $0.category == cat }) }
    }

    /// The one-line card subtitle: the param that best identifies the node.
    func summary(_ node: FlowNode) -> String {
        let p = node.params
        func v(_ key: String) -> String? { (p[key]?.isEmpty == false) ? p[key] : nil }
        switch type {
        case "trigger.schedule":  return "every \(v("interval") ?? "60") min"
        case "trigger.daily":     return "at \(v("time") ?? "09:00")"
        case "trigger.watch", "file.read", "file.write", "file.append",
             "file.list", "file.trash", "sys.screenshot":
            return v("path") ?? blurb
        case "file.move", "file.copy":
            return v("to") ?? blurb
        case "ai.ollama", "ai.summarize", "ai.translate", "ai.classify",
             "ai.extract", "ai.vision":
            return v("model") ?? "pick a model"
        case "ai.claude":         return v("model") ?? "claude-sonnet-5"
        case "ai.openai":         return v("model") ?? "gpt-5.1"
        case "ai.gemini":         return v("model") ?? "gemini-2.5-flash"
        case "ai.rewrite":        return v("style") ?? blurb
        case "sys.shell":         return v("command")?.components(separatedBy: .newlines).first ?? blurb
        case "sys.volume":        return "\(v("level") ?? "50")%"
        case "web.get", "web.post", "web.download", "web.rss":
            return v("url") ?? blurb
        case "web.json":          return v("path") ?? blurb
        case "logic.if", "logic.filter":
            return "\(v("mode") ?? "contains") \"\(v("value") ?? "")\""
        case "logic.delay":       return "\(v("seconds") ?? "2")s"
        case "logic.repeat":      return "×\(v("times") ?? "3")"
        case "text.replace":      return "\"\(v("find") ?? "")\" → \"\(v("replace") ?? "")\""
        case "text.first":        return "first \(v("count") ?? "5")"
        case "sys.open":          return v("target") ?? blurb
        case "app.launch", "app.quit":
            return v("app") ?? blurb
        case "app.shortcut":      return v("name") ?? blurb
        case "app.music":         return v("action") ?? blurb
        default:                  return blurb
        }
    }
}
