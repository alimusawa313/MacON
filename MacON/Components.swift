//
//  Components.swift
//  MacON
//
//  Reusable UI pieces.
//

import SwiftUI

extension String {
    /// Remove ANSI colour escape codes (fastlane/xcpretty emit lots of these).
    func strippingANSI() -> String {
        guard let re = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*m") else { return self }
        let range = NSRange(startIndex..., in: self)
        return re.stringByReplacingMatches(in: self, range: range, withTemplate: "")
    }
}

/// Generic coloured status indicator.
struct Dot: View {
    let color: Color
    var glow: Bool = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(.black.opacity(0.1)))
            .shadow(color: color.opacity(0.6), radius: glow ? 4 : 0)
    }
}

struct StatusDot: View {
    let state: RunnerState
    var body: some View { Dot(color: color, glow: state.isActive) }
    private var color: Color {
        switch state {
        case .running:  return .green
        case .starting: return .yellow
        case .stopped:  return .gray
        case .crashed:  return .red
        }
    }
}

struct LogConsole: View {
    let lines: [LogLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(color(for: line.text))
                            .id(line.id)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: lines.count) {
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .overlay {
                if lines.isEmpty {
                    ContentUnavailableView(
                        "No output yet",
                        systemImage: "terminal",
                        description: Text("Start this runner to see live logs."))
                }
            }
        }
    }

    private func color(for text: String) -> Color {
        if text.hasPrefix("✗") || text.contains("error") || text.contains("failed") { return .red }
        if text.hasPrefix("⚠︎") { return .orange }
        if text.hasPrefix("✓") || text.hasPrefix("🧹") { return .green }
        if text.hasPrefix("$") || text.hasPrefix("↻") || text.hasPrefix("⏹") { return .secondary }
        return .primary
    }
}

/// Human-friendly duration.
func formatDuration(_ t: TimeInterval) -> String {
    let t = max(0, t)
    if t < 1 { return String(format: "%.0fms", t * 1000) }
    if t < 60 { return String(format: "%.1fs", t) }
    let s = Int(t.rounded())
    return "\(s / 60)m \(s % 60)s"
}

/// Total wall time spanned by a set of log lines.
func totalDuration(_ lines: [LogLine]) -> TimeInterval {
    guard let first = lines.first?.date, let last = lines.last?.date else { return 0 }
    return last.timeIntervalSince(first)
}

// MARK: - Raw log (for history + pipelines)

struct RawStringLog: View {
    let lines: [LogLine]
    var autoscroll = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { line in
                        Text(line.text.strippingANSI())
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: lines.count) {
                if autoscroll, let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

// MARK: - Structured "Steps" view (Bitrise-style collapsible sections)

struct LogSection: Identifiable {
    enum Kind { case command, step, phase, output }
    let id: Int
    var title: String
    var lines: [LogLine]
    var kind: Kind
    var startDate: Date
    var endDate: Date

    var duration: TimeInterval { max(0, endDate.timeIntervalSince(startDate)) }

    // Precise failure detection — avoids false positives like the fastlane
    // setting line "slack_only_on_failure | false".
    var failed: Bool {
        lines.contains { l0 in
            let l = l0.text
            if l.contains("❌") { return true }
            if l.contains("** BUILD FAILED") || l.contains("** TEST FAILED")
                || l.contains("TEST EXECUTE FAILED") || l.contains("fatal error:") { return true }
            return l.range(of: #"with [1-9][0-9]* failure"#, options: .regularExpression) != nil
        }
    }
    var succeeded: Bool {
        lines.contains {
            let l = $0.text
            return l.contains("✅") || l.contains("** BUILD SUCCEEDED")
                || l.contains("Build Succeeded") || l.contains("with 0 failures")
                || l.contains("Tests Passed")
        }
    }
}

/// Parse a flat log into collapsible sections keyed off command / fastlane-step markers.
func parseLogSections(_ lines: [LogLine]) -> [LogSection] {
    var sections: [LogSection] = []
    var current: LogSection?

    func flush() { if let c = current { sections.append(c) }; current = nil }
    func start(_ title: String, _ kind: LogSection.Kind, _ date: Date) {
        flush()
        current = LogSection(id: sections.count, title: title, lines: [],
                             kind: kind, startDate: date, endDate: date)
    }

    for line in lines {
        let t = line.text.strippingANSI()
        if t.hasPrefix("──────") {
            let name = t.replacingOccurrences(of: "─", with: "").trimmingCharacters(in: .whitespaces)
            start(name.isEmpty ? "Build" : name.capitalized, .phase, line.date)
        } else if t.hasPrefix("$ ") {
            start(String(t.dropFirst(2)), .command, line.date)
        } else if let r = t.range(of: "--- Step: ") {
            let name = t[r.upperBound...].replacingOccurrences(of: "---", with: "")
                .trimmingCharacters(in: .whitespaces)
            start(name, .step, line.date)
        } else {
            if current == nil { start("Output", .output, line.date) }
            current?.lines.append(line)
        }
    }
    flush()

    // A step's duration runs until the next step starts (last step → final line).
    let lastDate = lines.last?.date
    for i in sections.indices {
        sections[i].endDate = (i + 1 < sections.count) ? sections[i + 1].startDate
                                                        : (lastDate ?? sections[i].startDate)
    }
    return sections
}

struct StructuredLog: View {
    let lines: [LogLine]
    @State private var expanded: Set<Int> = []

    private var sections: [LogSection] { parseLogSections(lines) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(sections) { section in
                    sectionView(section)
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { autoExpandFailures() }
    }

    @ViewBuilder
    private func sectionView(_ section: LogSection) -> some View {
        let isOpen = expanded.contains(section.id)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if isOpen { expanded.remove(section.id) } else { expanded.insert(section.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                    Image(systemName: icon(section)).foregroundStyle(color(section))
                    Text(section.title)
                        .font(.system(.callout, design: .monospaced)).bold()
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(formatDuration(section.duration))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Text("· \(section.lines.count) lines")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 5).padding(.horizontal, 8)
                .background(color(section).opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(section.lines) { l in
                        Text(l.text.strippingANSI())
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.leading, 26).padding(.vertical, 4)
            }
        }
    }

    private func icon(_ s: LogSection) -> String {
        if s.failed { return "xmark.circle.fill" }
        if s.succeeded { return "checkmark.circle.fill" }
        switch s.kind {
        case .command: return "terminal"
        case .step:    return "arrow.right.circle"
        case .phase:   return "hammer"
        case .output:  return "text.alignleft"
        }
    }
    private func color(_ s: LogSection) -> Color {
        if s.failed { return .red }
        if s.succeeded { return .green }
        return .secondary
    }
    private func autoExpandFailures() {
        for s in sections where s.failed { expanded.insert(s.id) }
        if expanded.isEmpty, let last = sections.last { expanded.insert(last.id) }
    }
}
