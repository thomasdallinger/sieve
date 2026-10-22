import SieveCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    let model: LocalModel
    let indexes: () -> IndexManager
    let rebuild: () -> Void

    @State private var status: LocalModel.Status = .unknown
    @State private var entries = 0
    @State private var building = false
    @State private var excludedText = ""
    @State private var modelText = ""

    var body: some View {
        Form {
            Section("Browsing") {
                Toggle("Show hidden files", isOn: $prefs.filter.showHidden)
                Toggle("Folders on top", isOn: $prefs.sort.foldersFirst)
                Picker("Default view", selection: $prefs.viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("File extensions are always shown. Sieve has no option to hide them.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Search index") {
                LabeledContent("Indexed") {
                    Text(building ? "Building… \(entries.formatted()) items" : "\(entries.formatted()) items, updated live")
                        .monospacedDigit()
                }
                LabeledContent("Indexed folders") {
                    Text(indexes().main.roots.map(Format.displayPath).joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Skip the contents of folders named")
                    TextEditor(text: $excludedText)
                        .font(.system(size: 11, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(height: 76)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                    Text("Comma-separated. The folders themselves are still found, only what is inside them is skipped. ~/Library is always skipped; searching inside it works on demand.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Apply and Rebuild Index") {
                        prefs.excludedNames = excludedText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        rebuild()
                        refresh()
                    }
                }
            }

            Section("Related results (local AI)") {
                Toggle("Suggest related names with a local model", isOn: $prefs.aiEnabled)
                Text("After the exact matches appear, a small model running on this Mac through Ollama suggests synonyms, translations and abbreviations, which are searched the same literal way. Nothing leaves your computer.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    TextField("Model", text: $modelText)
                        .onSubmit(applyModel)
                    Button("Use", action: applyModel).disabled(modelText == prefs.modelName)
                }
                LabeledContent("Status") { statusView }
            }
        }
        .formStyle(.grouped)
        .tint(Theme.swiftAccent)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            excludedText = prefs.excludedNames.joined(separator: ", ")
            modelText = prefs.modelName
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: IndexManager.didChange)) { _ in refresh() }
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .unknown: ProgressView().controlSize(.small)
        case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .serverNotRunning:
            HStack {
                Text("Ollama isn’t running").foregroundStyle(.secondary)
                Button(LocalModel.ollamaBinary == nil && !FileManager.default.fileExists(atPath: "/Applications/Ollama.app") ? "Get Ollama" : "Start") {
                    if !LocalModel.startServer() { NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { refresh() }
                }
            }
        case .modelMissing:
            HStack {
                Text("Not downloaded").foregroundStyle(.secondary)
                Button("Download") { pull() }
            }
        case .downloading(let p): ProgressView(value: p).frame(width: 160)
        case .failed(let message): Text(message).foregroundStyle(.red).lineLimit(2)
        }
    }

    private func applyModel() {
        let name = modelText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        prefs.modelName = name
        model.model = name
        refresh()
    }

    private func pull() {
        status = .downloading(0)
        Task {
            do {
                try await model.pull { p in DispatchQueue.main.async { status = .downloading(p) } }
            } catch {
                await MainActor.run { status = .failed(error.localizedDescription) }
                return
            }
            refresh()
        }
    }

    private func refresh() {
        entries = indexes().main.count
        building = indexes().main.isBuilding
        Task {
            let s = await model.status()
            await MainActor.run { if case .downloading = status { return }; status = s }
        }
    }
}
