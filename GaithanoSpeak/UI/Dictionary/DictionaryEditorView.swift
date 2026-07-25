import SwiftUI
import SpeakCore

struct DictionaryEditorView: View {
    @Bindable var environment: AppEnvironment
    @State private var newPhrase = ""
    @State private var newReplacement = ""
    @State private var matchCase = false

    var body: some View {
        VStack(spacing: 0) {
            Text("Replace what’s heard on the left with the text on the right. Also used as spelling hints for the formatter.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()

            List {
                if !environment.learnedSuggestions.isEmpty {
                    Section("Suggested") {
                        ForEach(environment.learnedSuggestions) { term in
                            suggestionRow(term)
                        }
                    }
                }

                Section {
                    ForEach(environment.dictionaryEntries) { entry in
                        HStack {
                            Text(entry.phrase).frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Text(entry.replacement).frame(maxWidth: .infinity, alignment: .leading)
                            if entry.source == .learned {
                                // The user didn't write this one. They should be able
                                // to see that at a glance and delete it like any other.
                                Image(systemName: "sparkles").foregroundStyle(.secondary)
                                    .help("Learned from the formatter’s corrections")
                            }
                            if entry.matchCase {
                                Image(systemName: "textformat").foregroundStyle(.secondary)
                                    .help("Case-sensitive")
                            }
                            Button(role: .destructive) {
                                if let id = entry.id { environment.deleteDictionaryEntry(id: id) }
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                        .font(.system(.body, design: .monospaced))
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                TextField("Heard", text: $newPhrase)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("Replacement", text: $newReplacement)
                Toggle("Aa", isOn: $matchCase).help("Case-sensitive").toggleStyle(.button)
                Button("Add") { add() }
                    .disabled(newPhrase.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 460, height: 440)
        .onAppear {
            environment.refreshDictionary()
            environment.refreshLearnedTerms()
        }
    }

    /// A term the learner saw more than once and wants a decision on. Deliberately
    /// shows the count: "heard twice" is the entire argument for the suggestion, and
    /// hiding it would make this look like the app guessing.
    @ViewBuilder
    private func suggestionRow(_ term: LearnedTerm) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(term.phrase)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(term.replacement)
                }
                .font(.system(.body, design: .monospaced))
                Text("Corrected \(term.occurrences) times while formatting")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add") {
                if let id = term.id { environment.acceptLearnedTerm(id: id) }
            }
            Button("No") {
                if let id = term.id { environment.dismissLearnedTerm(id: id) }
            }
            .help("Never suggest this again")
        }
    }

    private func add() {
        let entry = DictionaryEntry(
            phrase: newPhrase.trimmingCharacters(in: .whitespaces),
            replacement: newReplacement.trimmingCharacters(in: .whitespaces),
            matchCase: matchCase,
            sortOrder: environment.dictionaryEntries.count
        )
        environment.saveDictionaryEntry(entry)
        newPhrase = ""; newReplacement = ""; matchCase = false
    }
}
