import SwiftUI

struct ContextHeader: View {
    let context: AccountContext

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(.teal)
                Text(context.account)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 8)
                Text("\(context.pendingCount) pending")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 18) {
                metric("Per payment", "\(context.policy.perTxMaxNear) NEAR")
                metric("Daily left", "\(context.budget.remainingTodayNear) NEAR")
            }
        }
        .padding(.vertical, 4)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold))
        }
    }
}

struct ReasonBadge: View {
    let reason: String
    var text: String?

    var body: some View {
        Text(text ?? reason)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        reason == "NotAllowlisted" ? .red : .orange
    }
}

struct PendingRow: View {
    let spend: PendingSpend

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(spend.amountNear) NEAR")
                    .font(.title3.weight(.bold))
                Spacer()
                ReasonBadge(reason: spend.reason, text: spend.reasonLabel)
            }
            Text(spend.receiverId)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !spend.memo.isEmpty {
                Text(spend.memo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }
}
