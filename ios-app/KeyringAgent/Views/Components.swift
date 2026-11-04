import SwiftUI

// MARK: - Design tokens

enum Palette {
    static let accent = Color(red: 0.06, green: 0.46, blue: 0.43)
    static let warning = Color(red: 0.85, green: 0.47, blue: 0.02)
    static let danger = Color(red: 0.80, green: 0.18, blue: 0.18)
    static let surface = Color(.secondarySystemGroupedBackground)
    static let canvas = Color(.systemGroupedBackground)
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Palette.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(.white)
            .background(tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Palette.danger

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(tint)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

// MARK: - Containers

struct SurfaceCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Budget

struct BudgetCard: View {
    let context: AccountContext

    private var daily: Double { Double(context.policy.dailyMaxNear) ?? 0 }
    private var left: Double { Double(context.budget.remainingTodayNear) ?? 0 }
    private var fractionUsed: Double {
        guard daily > 0 else { return 0 }
        return min(max((daily - left) / daily, 0), 1)
    }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Agent budget today")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(context.budget.remainingTodayNear)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                    Text("NEAR left")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: fractionUsed)
                    .tint(Palette.accent)

                HStack {
                    Label("Up to \(context.policy.perTxMaxNear) NEAR each", systemImage: "gauge.with.dots.needle.33percent")
                    Spacer()
                    Text("of \(context.policy.dailyMaxNear) NEAR a day")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Requests

struct RequestCard: View {
    let spend: PendingSpend

    var body: some View {
        SurfaceCard {
            HStack(spacing: 14) {
                Image(systemName: "arrow.up.forward")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(tone, in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(spend.amountNear) NEAR")
                        .font(.title3.weight(.bold))
                    Text(spend.receiverId)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(reasonShort(spend.reason))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tone)
                }

                Spacer(minLength: 0)
                Text(relativeTime(nanos: spend.requestedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var tone: Color { spend.isHighRisk ? Palette.danger : Palette.warning }
}

struct EmptyInbox: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(Palette.accent)
            Text("All clear")
                .font(.title3.weight(.semibold))
            Text("The agent is within its limits. Nothing needs your card.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Details

struct ReasonBanner: View {
    let icon: String
    let text: String
    let tone: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(tone)
            Text(text)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(tone.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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

// MARK: - Plain language

func reasonShort(_ reason: String) -> String {
    switch reason {
    case "OverTxLimit": return "Above your per-payment limit"
    case "OverDailyLimit": return "Over today's budget"
    case "NotAllowlisted": return "Receiver not on your list"
    default: return "Needs your approval"
    }
}

func reasonSentence(_ reason: String, perTxMaxNear: String?) -> String {
    switch reason {
    case "OverTxLimit":
        let limit = perTxMaxNear.map { "\($0) NEAR" } ?? "the limit"
        return "Bigger than the \(limit) the agent may pay alone. The contract held it for you."
    case "OverDailyLimit":
        return "This would go past today's agent budget. The contract held it for you."
    case "NotAllowlisted":
        return "This receiver isn't on the agent's allowed list. The contract held it for you."
    default:
        return "The contract held this payment for your approval."
    }
}

func relativeTime(nanos: UInt64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(nanos) / 1_000_000_000)
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}
