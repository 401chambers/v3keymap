import AppKit
import Observation
import PDFKit
import SwiftUI

/// The three reference documents shown from the Help menu.
@MainActor
@Observable
public final class HelpLibrary {
    public static let shared = HelpLibrary()

    public enum Doc: String, CaseIterable, Identifiable, Sendable {
        case quickStart = "quick-start-guide"
        case userManual = "user-manual"
        case disassembly = "disassembly-guide"
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .quickStart: return "Quick Start Guide"
            case .userManual: return "User Manual"
            case .disassembly: return "Disassembly"
            }
        }
        var subtitle: String {
            switch self {
            case .quickStart: return "Layers, backlight keys, Siri, factory reset"
            case .userManual: return "What's in the box, setup, keys, reset and flashing"
            case .disassembly: return "Step by step, with photos"
            }
        }
        var icon: String {
            switch self {
            case .quickStart: return "bolt.badge.clock"
            case .userManual: return "book.closed"
            case .disassembly: return "wrench.and.screwdriver"
            }
        }
    }

    public var selected: Doc = .quickStart

    /// The PDF inside the app bundle (`Help` folder), or next to where the app was started from during development.
    func url(for doc: Doc) -> URL? {
        if let bundled = Bundle.main.url(forResource: doc.rawValue, withExtension: "pdf", subdirectory: "Help") { return bundled }
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Help/\(doc.rawValue).pdf")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }
}

/// Help window: the documents on the left, the selected one on the right.
public struct HelpView: View {
    let library: HelpLibrary
    public init(library: HelpLibrary) { self.library = library }

    public var body: some View {
        NavigationSplitView {
            List(selection: Binding<HelpLibrary.Doc?>(get: { library.selected }, set: { if let d = $0 { library.selected = d } })) {
                ForEach(HelpLibrary.Doc.allCases) { doc in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.title)
                            Text(doc.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: doc.icon) }
                    .padding(.vertical, 3)
                    .tag(doc)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            if let url = library.url(for: library.selected) {
                PDFContent(url: url).id(url)
                    .navigationTitle(library.selected.title)
            } else {
                ContentUnavailableView("Document Not Found", systemImage: "doc.questionmark",
                                       description: Text("This copy of the app was built without the Help folder, so \(library.selected.title) isn't included."))
                    .navigationTitle(library.selected.title)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
    }
}

private struct PDFContent: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(url: url)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {}
}
