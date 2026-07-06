//
//  PipelineDetailView.swift
//  MacON
//

import SwiftUI

struct PipelineDetailView: View {
    @ObservedObject var pipeline: PipelineRunner
    @EnvironmentObject private var pool: PipelinePool
    @State private var showEdit = false
    @State private var confirmDelete = false

    // nil = the live/current log; otherwise a past run.
    @State private var selectedRun: RunSummary?
    @State private var historyLines: [LogLine] = []
    @State private var stepsView = true    // Steps (structured) vs Raw

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                runsList
                Divider()
                consolePane
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 400)
        .sheet(isPresented: $showEdit) {
            PipelineEditView(pipeline: pipeline).environmentObject(pool)
        }
        .confirmationDialog("Delete “\(pipeline.config.name)”?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { pool.remove(pipeline) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Dot(color: pipeline.buildState.color, glow: pipeline.isWatching)
            VStack(alignment: .leading, spacing: 2) {
                Text(pipeline.config.name).font(.headline)
                Text(pipeline.buildState.label)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(pipeline.config.workspace)/\(pipeline.config.repoSlug) @ \(pipeline.config.branch)")
                    .font(.caption).foregroundStyle(.secondary)
                if pipeline.isWatching, let p = pipeline.lastPoll {
                    Text("watching · last poll \(p.formatted(date: .omitted, time: .standard))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 6)
            Spacer()
            Button { showEdit = true } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
        }
        .padding()
    }

    // MARK: Runs history list

    private var runsList: some View {
        List {
            Section("History") {
                // Live entry
                Button {
                    selectedRun = nil
                } label: {
                    HStack(spacing: 8) {
                        Dot(color: pipeline.isBuilding ? .yellow : pipeline.buildState.color,
                            glow: pipeline.isBuilding)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Live").font(.callout).bold()
                            Text(pipeline.isBuilding ? "building…" : "current log")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(selectedRun == nil ? Color.accentColor.opacity(0.15) : Color.clear)

                ForEach(pipeline.history) { run in
                    Button { selectedRun = run } label: { runRow(run) }
                        .buttonStyle(.plain)
                        .listRowBackground(selectedRun == run ? Color.accentColor.opacity(0.15) : Color.clear)
                }

                if pipeline.history.isEmpty {
                    Text("No past runs yet.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 210)
        .task(id: selectedRun) { await loadSelected() }
    }

    private func runRow(_ run: RunSummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: run.result.icon).foregroundStyle(run.result.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.shaShort).font(.system(.callout, design: .monospaced))
                Text("\(run.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(run.durationText)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Console

    private var displayedLines: [LogLine] {
        selectedRun == nil ? pipeline.log : historyLines
    }

    private var consolePane: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $stepsView) {
                    Text("Steps").tag(true)
                    Text("Raw").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .labelsHidden()

                Spacer()
                if !displayedLines.isEmpty {
                    Label(formatDuration(totalDuration(displayedLines)), systemImage: "clock")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(selectedRun == nil ? "Live" : "Run \(selectedRun!.shaShort)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
            Divider()

            if displayedLines.isEmpty {
                ContentUnavailableView("No output yet", systemImage: "terminal",
                                       description: Text("Run the pipeline to see logs."))
            } else if stepsView {
                StructuredLog(lines: displayedLines)
            } else {
                RawStringLog(lines: displayedLines, autoscroll: selectedRun == nil)
            }
        }
    }

    private func loadSelected() async {
        guard let run = selectedRun else { historyLines = []; return }
        historyLines = await pipeline.lines(for: run.id)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if pipeline.isWatching {
                Button(role: .destructive) { pipeline.stopWatching() } label: {
                    Label("Stop Watching", systemImage: "eye.slash")
                }
            } else {
                Button { pipeline.startWatching() } label: {
                    Label("Start Watching", systemImage: "eye")
                }
            }
            if pipeline.isBuilding {
                Button(role: .destructive) { pipeline.cancelBuild() } label: {
                    Label("Stop Build", systemImage: "stop.fill")
                }
            } else {
                Button { selectedRun = nil; pipeline.runNow() } label: {
                    Label("Run Now", systemImage: "play.fill")
                }
                .help("Build the current head commit immediately")
            }
            Spacer()
            Button { pipeline.clearLog() } label: { Label("Clear", systemImage: "text.badge.xmark") }
                .disabled(pipeline.log.isEmpty || selectedRun != nil)
            Button { copyLog() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .disabled(displayedLines.isEmpty)
        }
        .padding()
    }

    private func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            displayedLines.map { $0.text.strippingANSI() }.joined(separator: "\n"),
            forType: .string)
    }
}
