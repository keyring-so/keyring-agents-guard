import SwiftUI

struct PendingListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack(path: $model.path) {
            List {
                if let context = model.context {
                    Section {
                        ContextHeader(context: context)
                    }
                }

                Section("Pending approvals") {
                    if model.pending.isEmpty {
                        Text("No pending approvals. The agent is inside its policy.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.pending) { spend in
                            NavigationLink(value: spend) {
                                PendingRow(spend: spend)
                            }
                        }
                    }
                }

                if let error = model.error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .refreshable { await model.refresh() }
            .navigationTitle("Keyring Agent")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .navigationDestination(for: PendingSpend.self) { spend in
                ApprovalView(spend: spend)
            }
            .overlay(alignment: .bottom) {
                if let status = model.status {
                    Text(status)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding()
                }
            }
        }
    }
}
