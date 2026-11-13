import SwiftUI

/// Ordering also prevents delayed loading callbacks from replacing a later UI stage.
enum PromptActivity: Int {
    case retrieving
    case verifyingModel
    case loadingModel
    case preparingModel
    case processingPrompt
    case generating
    case maintaining

    var title: String {
        switch self {
        case .retrieving: return "Finding relevant journal entries"
        case .verifyingModel, .loadingModel, .preparingModel: return "Getting ready to answer"
        case .processingPrompt: return "Reading your entries"
        case .generating: return "Writing your reflection"
        case .maintaining: return "Refreshing your journal"
        }
    }
}

struct PromptProgressView: View {
    let activity: PromptActivity
    let startedAt: Date

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(activity.title).font(.callout.weight(.medium))
            Spacer()
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text("\(max(0, Int(context.date.timeIntervalSince(startedAt))))s elapsed")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
