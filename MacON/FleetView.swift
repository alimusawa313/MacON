//
//  FleetView.swift
//  MacON
//
//  A teaser for the upcoming multi-Mac Fleet: pair more than one Mac and
//  MacOn links them into a cluster — not just for CI, but for any heavy work:
//  distributed AI training, or a personal supercomputer chained from Macs.
//  Styled in the same clay world as the welcome pane. No functionality yet.
//

import SwiftUI

struct FleetView: View {
    let world: WorldStyle

    var body: some View {
        ZStack {
            WorldBackdrop(world: world)
            VStack(spacing: 16) {
                FleetStage(dark: world.dark, theme: world.theme)
                    .aspectRatio(0.62, contentMode: .fit)
                    .frame(maxHeight: 420)

                Pill(text: "Coming soon", systemImage: "sparkles", tint: world.primary)

                Text("Many Macs, one machine")
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .foregroundStyle(world.ink)

                Text("Pair more than one Mac and MacOn links them into a fleet — one cluster you can point at anything heavy. Fan CI and builds across every idle machine, distribute an AI training run, or chain them into a personal supercomputer. Releases still pin to your always-on Mac.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(world.ink.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)

                VStack(spacing: 0) {
                    featureRow("rectangle.3.group.fill", "Every paired Mac in one cluster")
                    divider
                    featureRow("arrow.triangle.branch", "Fan CI & builds across idle Macs")
                    divider
                    featureRow("cpu.fill", "Pool them for AI training & heavy compute")
                }
                .frame(maxWidth: 460)
                .background(world.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(world.line))
            }
            .padding(28)
        }
    }

    private var divider: some View {
        Rectangle().fill(world.line).frame(height: 1).padding(.leading, 52)
    }

    private func featureRow(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(world.primary)
                .frame(width: 24)
            Text(text)
                .font(.system(.callout, design: .rounded).weight(.medium))
                .foregroundStyle(world.ink.opacity(0.85))
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}
