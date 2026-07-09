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

// MARK: - Structured "Steps" view (Bitrise-style collapsible sections)

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
