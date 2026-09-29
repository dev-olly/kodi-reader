import AppKit
import SwiftUI

struct AICreditPacksSheet: View {
    let credits: AICreditsController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let added = credits.addedCredits {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
                Text("Credits added").font(.title2.bold())
                Text("Your payment is confirmed. \(added) credits have been added to your account.")
                if let balance = credits.balance { Text("\(balance) credits available").font(.headline) }
                Button("Continue with Ask AI") { credits.dismissPurchaseSuccess(); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
            Text("Ask AI credits").font(.title2)
            Text("One credit buys one answer, including a follow-up. Purchased credits never expire.")
                .foregroundStyle(.secondary)
            if let balance = credits.balance { Text("\(balance) credits available").font(.headline) }
            if credits.sandbox { Text("Test checkout — no real payment").foregroundStyle(.orange) }
            ForEach(credits.packs) { pack in
                HStack {
                    VStack(alignment: .leading) {
                        Text(pack.name).font(.headline)
                        Text("\(pack.credits) answers").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let price = pack.formattedPrice, pack.available {
                        Button(price) {
                            Task { if let url = await credits.checkout(pack: pack) { NSWorkspace.shared.open(url) } }
                        }.disabled(credits.busy || credits.confirmingPurchase)
                    } else { Text("Coming soon").foregroundStyle(.secondary) }
                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            if credits.packs.isEmpty { Text("Credit packs are not available yet.") }
            if credits.confirmingPurchase {
                HStack { ProgressView().controlSize(.small); Text("Waiting for payment confirmation…").font(.callout) }
                Text("Your credits will appear automatically. You can return to your book while we check.").font(.caption).foregroundStyle(.secondary)
            }
            Text("One-time purchases. No subscription or automatic top-ups. Prices include tax. Payment opens in your browser; credits appear after payment is confirmed.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = credits.error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Refresh balance") { Task { await credits.refresh() } }.disabled(credits.busy)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            }
        }.padding(24).frame(width: 420)
        .task { await credits.refresh() }
        .onChange(of: phase) { _, value in if value == .active { Task { await credits.refresh() } } }
    }
}
