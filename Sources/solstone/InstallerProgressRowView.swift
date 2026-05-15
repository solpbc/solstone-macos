import SwiftUI

struct InstallerProgressRowView: View {
    let label: String
    let status: RowStatus
    let progress: SubprocessProgress?
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                statusIcon
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.headline)

                    if case .running = status, let currentStep = progress?.currentStep {
                        Text(currentStep)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if case .failed(let message) = status {
                        Text("couldn't finish — " + message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Spacer()

                if let progress, !progress.renderedLog.isEmpty {
                    Button(isExpanded ? "hide details" : "show details") {
                        isExpanded.toggle()
                    }
                    .font(.caption)
                }
            }

            if isExpanded, let renderedLog = progress?.renderedLog, !renderedLog.isEmpty {
                ScrollView {
                    Text(renderedLog)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 96, maxHeight: 180)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("waiting")
        case .running:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("running")
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("done")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}
