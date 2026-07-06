//
//  PipelineModels.swift
//  MacON
//
//  Value types for local CI pipelines (poll Bitbucket → build → report status).
//

import Foundation
import SwiftUI

enum WatchMode: String, Codable, CaseIterable {
    case branch, pullRequests
    var label: String { self == .branch ? "Branch" : "Pull Requests" }
}

/// A local CI pipeline: watch a branch (or open PRs) of a repo, build here.
struct PipelineConfig: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = "New Pipeline"
    var workspace = ""        // e.g. "academytools"
    var repoSlug = ""         // e.g. "planpal-ios-learner-2"
    var branch = "main"
    /// Watch a single branch, or all open pull requests.
    var watchMode: WatchMode = .branch
    /// In PR mode, only build PRs targeting this branch (blank = all open PRs).
    var prTargetBranch = ""
    /// Pipeline definition file to look for in the repo root. If found, its steps
    /// run instead of `buildCommand`.
    var pipelineFile = "macon.yml"
    /// Which workflow to run from the pipeline file. Blank = auto (match branch /
    /// PR target against the file's `triggers`).
    var workflow = ""
    /// Fallback when no pipeline file is present: the whole pipeline as one shell command.
    var buildCommand = "bundle install && bundle exec fastlane test device:\"iPhone 17 Pro\""
    /// Where the repo is cloned/checked out for this pipeline.
    var workingDirectory = ""
    var pollSeconds = 30
    /// Post build status back to the commit on Bitbucket.
    var postStatus = true
    /// Names of secret env vars (e.g. ASC_KEY_ID). Values live in the Keychain,
    /// never here. Injected into every step's environment.
    var secretKeys: [String] = []

    init() {}

    // Tolerant decoding: any missing key falls back to its default, so adding
    // new fields never invalidates previously-saved pipelines.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "New Pipeline"
        workspace = (try? c.decode(String.self, forKey: .workspace)) ?? ""
        repoSlug = (try? c.decode(String.self, forKey: .repoSlug)) ?? ""
        branch = (try? c.decode(String.self, forKey: .branch)) ?? "main"
        watchMode = (try? c.decode(WatchMode.self, forKey: .watchMode)) ?? .branch
        prTargetBranch = (try? c.decode(String.self, forKey: .prTargetBranch)) ?? ""
        pipelineFile = (try? c.decode(String.self, forKey: .pipelineFile)) ?? "macon.yml"
        workflow = (try? c.decode(String.self, forKey: .workflow)) ?? ""
        buildCommand = (try? c.decode(String.self, forKey: .buildCommand))
            ?? "bundle install && bundle exec fastlane test device:\"iPhone 17 Pro\""
        workingDirectory = (try? c.decode(String.self, forKey: .workingDirectory)) ?? ""
        pollSeconds = (try? c.decode(Int.self, forKey: .pollSeconds)) ?? 30
        postStatus = (try? c.decode(Bool.self, forKey: .postStatus)) ?? true
        secretKeys = (try? c.decode([String].self, forKey: .secretKeys)) ?? []
    }
}

/// Outcome of the most recent build.
enum BuildState: Equatable {
    case idle
    case running(sha: String)
    case succeeded(sha: String)
    case failed(sha: String)

    var shortSHA: String? {
        switch self {
        case .idle: return nil
        case .running(let s), .succeeded(let s), .failed(let s): return String(s.prefix(8))
        }
    }
    var color: Color {
        switch self {
        case .idle:      return .gray
        case .running:   return .yellow
        case .succeeded: return .green
        case .failed:    return .red
        }
    }
    var label: String {
        switch self {
        case .idle:            return "No builds yet"
        case .running(let s):  return "Building \(s.prefix(8))…"
        case .succeeded(let s):return "Passed \(s.prefix(8))"
        case .failed(let s):   return "Failed \(s.prefix(8))"
        }
    }
}

/// A repo-defined pipeline (macon.yml). Parsed from YAML→JSON at build time.
/// Supports Bitrise-style workflows, before/after composition, triggers, env,
/// and conditional / always-run steps.
struct MaconPipeline: Codable {
    var name: String?
    var env: [String: String]?
    /// Simple single-workflow form: top-level steps (used when `workflows` is absent).
    var steps: [MaconStep]?
    /// Named, composable workflows.
    var workflows: [String: MaconWorkflow]?
    /// Branch/tag → workflow routing (like Bitrise trigger_map).
    var triggers: [MaconTrigger]?

    var hasContent: Bool {
        !(steps?.isEmpty ?? true) || !(workflows?.isEmpty ?? true)
    }
}

struct MaconWorkflow: Codable {
    var before_run: [String]?
    var after_run: [String]?
    var env: [String: String]?
    var steps: [MaconStep]?
}

struct MaconStep: Codable {
    var name: String
    var script: String
    /// Shell condition; the step runs only if this exits 0. Env vars are available.
    var run_if: String?
    /// Run even if an earlier step already failed (like Bitrise is_always_run).
    var always_run: Bool?
}

struct MaconTrigger: Codable {
    var branch: String?
    var tag: String?
    var pull_request: String?
    var workflow: String
}

/// Final result of a saved run.
enum RunResult: String, Codable {
    case succeeded, failed, cancelled
    var icon: String {
        switch self {
        case .succeeded: return "checkmark.circle.fill"
        case .failed:    return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .succeeded: return .green
        case .failed:    return .red
        case .cancelled: return .orange
        }
    }
    var label: String {
        switch self {
        case .succeeded: return "Passed"
        case .failed:    return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Lightweight metadata for a past run (kept in the on-disk index).
struct RunSummary: Identifiable, Codable, Equatable {
    var id: UUID
    var shaFull: String
    var startedAt: Date
    var finishedAt: Date
    var result: RunResult

    var shaShort: String { String(shaFull.prefix(8)) }
    var duration: TimeInterval { max(0, finishedAt.timeIntervalSince(startedAt)) }
    var durationText: String {
        let s = Int(duration)
        return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
    }
}

/// A full saved run (metadata + its log), persisted to disk.
struct PipelineRun: Codable {
    var summary: RunSummary
    var lines: [LogLine]
}

/// Bitbucket account used to poll, clone, and post status. Shared by all pipelines.
struct BitbucketCredentials: Equatable {
    var email: String = ""
    var apiToken: String = ""
    var isComplete: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty &&
        !apiToken.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
