import SwiftUI
import SpeakCore

struct HistoryView: View {
    @Bindable var environment: AppEnvironment

    var body: some View {
        VStack(spacing: 0) {
            statsHeader
            Divider()
            if environment.history.isEmpty {
                ContentUnavailableView("No dictations yet",
                                       systemImage: "text.bubble",
                                       description: Text("Hold your dictation key and speak to get started."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(environment.history) { record in
                        DictationRow(record: record) {
                            if let id = record.id { environment.deleteDictation(id: id) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 560, height: 520)
        .onAppear { environment.refreshHistory() }
    }

    private var statsHeader: some View {
        HStack(spacing: 24) {
            stat("\(environment.stats.totalDictations)", "dictations")
            stat("\(environment.stats.totalWords)", "words")
            stat(String(format: "%.0f", environment.stats.averageWPM), "avg wpm")
            Spacer()
        }
        .padding()
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .semibold, design: .monospaced))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct DictationRow: View {
    let record: DictationRecord
    var onDelete: () -> Void
    @State private var showingRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(record.wordCount) words")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(showingRaw ? record.rawText : record.formattedText)
                .font(.system(.body, design: .default))
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Button(showingRaw ? "Show formatted" : "Show raw") { showingRaw.toggle() }
                Button("Copy") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(showingRaw ? record.rawText : record.formattedText, forType: .string)
                }
                Button("Delete", role: .destructive, action: onDelete)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}
