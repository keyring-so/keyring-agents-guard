import SwiftUI

struct PendingListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack(path: $model.path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let context = model.context {
                        BudgetCard(context: context)
                    }

                    if let error = model.error {
                        ReasonBanner(icon: "exclamationmark.triangle.fill", text: error, tone: Palette.danger)
                    }

                    SectionTitle(text: model.pending.isEmpty ? "Waiting for you" : "Waiting for you · \(model.pending.count)")

                    if model.pending.isEmpty {
                        SurfaceCard { EmptyInbox() }
                    } else {
                        VStack(spacing: 12) {
                            ForEach(model.pending) { spend in
                                NavigationLink(value: spend) {
                                    RequestCard(spend: spend)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Palette.canvas)
            .refreshable { await model.refresh() }
            .navigationTitle("Keyring")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        WalletView()
                    } label: {
                        Image(systemName: "wallet.pass")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
            .navigationDestination(for: PendingSpend.self) { spend in
                ApprovalView(spend: spend)
            }
        }
    }
}
