//
//  Components.swift
//  MacON
//
//  Reusable SwiftUI pieces. Log-processing logic lives in MaconKit.
//

import SwiftUI
import MaconKit

// MARK: - UI colour mappings for core enums

extension RunnerState {
    var uiColor: Color {
        switch self {
        case .running:  return Brand.emerald
        case .starting: return Brand.amber
        case .stopped:  return .gray
        case .crashed:  return Brand.rose
        }
    }
    var symbol: String {
        switch self {
        case .stopped:  return "pause.fill"
        case .starting: return "hourglass"
        case .running:  return "bolt.fill"
        case .crashed:  return "exclamationmark.triangle.fill"
        }
    }
}

extension BuildState {
    var uiColor: Color {
        switch self {
        case .idle:      return .gray
        case .running:   return Brand.amber
        case .succeeded: return Brand.emerald
        case .failed:    return Brand.rose
        }
    }
    var symbol: String {
        switch self {
        case .idle:      return "bolt.horizontal.fill"
        case .running:   return "hammer.fill"
        case .succeeded: return "checkmark"
        case .failed:    return "xmark"
        }
    }
}

extension RunResult {
    var uiColor: Color {
        switch self {
        case .succeeded: return Brand.emerald
        case .failed:    return Brand.rose
        case .cancelled: return Brand.amber
        }
    }
}

// MARK: - Status badge

/// Rounded tile with the status color + symbol; pulses while active.
struct StatusBadge: View {
    var color: Color
    var symbol: String
    var active: Bool = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            if active {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(color.opacity(0.5), lineWidth: 2)
                    .scaleEffect(pulse ? 1.35 : 1)
                    .opacity(pulse ? 0 : 0.7)
            }
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(color.gradient)
                .overlay(Image(systemName: symbol).font(.title3.weight(.bold)).foregroundStyle(.white))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white.opacity(0.25)))
                .shadow(color: color.opacity(active ? 0.6 : 0.3), radius: active ? 8 : 3, y: 2)
        }
        .frame(width: 46, height: 46)
        .onAppear { if active { run() } }
        .onChange(of: active) { _, a in a ? run() : (pulse = false) }
    }
    private func run() {
        pulse = false
        withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
    }
}

// MARK: - Status dot

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
    var body: some View { Dot(color: state.uiColor, glow: state.isActive) }
}

// MARK: - Live log console

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

// MARK: - Structured "Steps" view (CI-style step list)

struct StructuredLog: View {
    let lines: [LogLine]
    @State private var expanded: Set<Int> = []

    private var sections: [LogSection] { parseLogSections(lines) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(sections) { section in
                    StepRow(section: section, isOpen: expanded.contains(section.id)) {
                        withAnimation(.spring(duration: 0.28)) {
                            if expanded.contains(section.id) { expanded.remove(section.id) }
                            else { expanded.insert(section.id) }
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
        .onAppear { autoExpandFailures() }
    }

    private func autoExpandFailures() {
        for s in sections where s.failed { expanded.insert(s.id) }
        if expanded.isEmpty, let last = sections.last { expanded.insert(last.id) }
    }
}

/// One collapsible CI step: status node, accent stripe, duration pill, and a
/// terminal-style body when expanded.
private struct StepRow: View {
    let section: LogSection
    let isOpen: Bool
    let toggle: () -> Void
    @State private var hover = false
    @State private var copied = false

    private var tint: Color {
        if section.failed { return Brand.rose }
        if section.succeeded { return Brand.emerald }
        return .secondary
    }
    private var kindIcon: String {
        switch section.kind {
        case .command: return "terminal"
        case .step:    return "arrow.right"
        case .phase:   return "hammer.fill"
        case .output:  return "text.alignleft"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                node
                Text(section.title)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                copyButton
                Text(formatDuration(section.duration))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Text("\(section.lines.count)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    .frame(minWidth: 24, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)

            if isOpen {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(section.lines) { l in
                        Text(l.text.strippingANSI())
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(lineColor(l.text))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.22))
            }
        }
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(hover ? tint.opacity(0.1) : Color.primary.opacity(0.04)))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.06)))
        .onHover { hover = $0 }
    }

    private var copyButton: some View {
        Button {
            copyStep()
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(copied ? Brand.emerald : .secondary)
                .frame(width: 22, height: 22)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(hover || copied ? 1 : 0)
        .help("Copy this step")
    }

    private func copyStep() {
        let body = section.lines.map { $0.text.strippingANSI() }.joined(separator: "\n")
        let text = body.isEmpty ? section.title : "\(section.title)\n\(body)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
    }

    private var node: some View {
        Group {
            if section.failed {
                badge(Brand.rose, "xmark")
            } else if section.succeeded {
                badge(Brand.emerald, "checkmark")
            } else {
                ZStack {
                    Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1.5)
                    Image(systemName: kindIcon)
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 24, height: 24)
    }

    private func badge(_ c: Color, _ symbol: String) -> some View {
        Circle().fill(c.gradient)
            .overlay(Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
            .shadow(color: c.opacity(0.5), radius: 3, y: 1)
    }

    private func lineColor(_ text: String) -> Color {
        if text.contains("❌") || text.contains("error") || text.contains("failed") { return Brand.rose }
        if text.hasPrefix("⚠︎") || text.contains("warning") { return Brand.amber }
        if text.contains("✅") || text.hasPrefix("✓") { return Brand.emerald }
        if text.hasPrefix("$") || text.hasPrefix("▸") { return .secondary }
        return .primary
    }
}
