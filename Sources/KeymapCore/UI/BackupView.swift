import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ViaKit

/// Save the keyboard's setup to a file, or restore one (with a preview of what will change).
struct BackupView: View {
    let model: AppModel

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "v3-keymap-backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.exportBackup(to: url) } catch { model.report(error) }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { model.restorePreview = AppModel.RestorePreview(url: url, changes: try model.previewRestore(from: url)) } catch { model.report(error) }
    }

    var body: some View {
        Form {
            Section {
                Text("A backup is saved automatically before the first change of each session. You can also save or restore one yourself.").foregroundStyle(.secondary)
                if let last = model.lastBackupURL {
                    LabeledContent("This session's backup") { Text(last.lastPathComponent).textSelection(.enabled) }
                }
            }
            Section("Save") {
                Button("Save a backup of the keyboard…", action: save)
            }
            Section("Restore") {
                Button("Choose a backup file…", action: choose)
                if let preview = model.restorePreview {
                    LabeledContent("File") { Text(preview.url.lastPathComponent) }
                    if preview.changes.isEmpty {
                        Text("This backup matches the keyboard. Nothing to restore.").foregroundStyle(.secondary)
                    } else {
                        Text("Restoring will change \(plural(preview.changes.count, "setting")):")
                        ForEach(Array(preview.changes.enumerated()), id: \.offset) { _, c in Text(model.describe(c)).font(.callout) }
                        Button("Restore now") { Task { do { try await model.restore(from: preview.url) } catch { model.report(error) } } }
                            .disabled(model.state != .connected || model.isApplying)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
