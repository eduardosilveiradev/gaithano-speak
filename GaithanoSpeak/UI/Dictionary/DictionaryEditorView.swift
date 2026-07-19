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
                ForEach(environment.dictionaryEntries) { entry in
                    HStack {
                        Text(entry.phrase).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(entry.replacement).frame(maxWidth: .infinity, alignment: .leading)
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
        .onAppear { environment.refreshDictionary() }
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
