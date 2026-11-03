import PencilKit
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

// MARK: - Add page

/// Panel under the "+ page" button: where to insert, which paper, or what to bring in.
struct AddPagePanel: View {
    @EnvironmentObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    let doc: NoteDocument
    let current: Int
    /// Called with the new page's index so the editor can scroll there.
    let didInsert: (Int) -> Void
    let pickPhoto: () -> Void
    var pasteClipboard: () -> Void = {}
    @State private var position = Position.after
    @State private var scanning = false
    @State private var camera = false
    @State private var importing = false

    enum Position: String, CaseIterable, Identifiable {
        case before = "Vor dieser", after = "Nach dieser", end = "Ans Ende"
        var id: String { rawValue }
    }

    private var index: Int {
        switch position {
        case .before: return current
        case .after: return current + 1
        case .end: return doc.pages.count
        }
    }

    private var currentPage: NotePage? { doc.pages.indices.contains(current) ? doc.pages[current] : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Seite hinzufügen").font(.headline).frame(maxWidth: .infinity)
                Picker("Position", selection: $position) {
                    ForEach(Position.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                Text("Papier").font(.title3.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        if let cur = currentPage {
                            card("Wie aktuelle Seite") {
                                PageThumbnail(doc: doc, page: cur, version: 0)
                            } action: {
                                var p = NotePage(width: cur.isBoard ? 1091.64 : cur.width,
                                                 height: cur.isBoard ? 1543.74 : cur.height, template: cur.template)
                                p.template = cur.template
                                insert(p)
                            }
                        }
                        ForEach(PageTemplate.allCases) { t in
                            card(t.label) { TemplatePreview(template: t) } action: {
                                insert(NotePage(width: currentPage?.width ?? 1091.64, height: currentPage?.height ?? 1543.74, template: t))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                VStack(spacing: 0) {
                    row("Bild aus Fotos", "photo") { dismiss(); pickPhoto() }
                    Divider().padding(.leading, 52)
                    row("Dokument scannen", "doc.viewfinder") { scanning = true }
                        .disabled(!VNDocumentCameraViewController.isSupported)
                    Divider().padding(.leading, 52)
                    row("Foto aufnehmen", "camera") { camera = true }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    Divider().padding(.leading, 52)
                    row("PDF-Seiten importieren", "square.and.arrow.down") { importing = true }
                    Divider().padding(.leading, 52)
                    row("Aus Zwischenablage einfügen", "doc.on.clipboard") { dismiss(); pasteClipboard() }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .frame(width: 440, height: 560)
        .fullScreenCover(isPresented: $scanning) {
            DocumentScanner { images in
                scanning = false
                if !images.isEmpty { store.insertImagePages(images, at: index, in: doc.id); finish(index) }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $camera) {
            CameraPicker { image in
                camera = false
                if let image { store.insertImagePages([image], at: index, in: doc.id); finish(index) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if (try? store.insertPDFPages(url, at: index, in: doc.id)) != nil { finish(index) }
        }
    }

    private func insert(_ page: NotePage) {
        let i = index
        store.insertPage(page, at: i, in: doc.id)
        finish(i)
    }

    private func finish(_ i: Int) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { didInsert(i) }
    }

    private func card<V: View>(_ title: String, @ViewBuilder preview: () -> V, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview()
                    .frame(width: 96, height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                Text(title).font(.caption).foregroundStyle(.primary).lineLimit(2).frame(width: 100)
            }
        }
        .buttonStyle(.plain)
    }

    private func row(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.title3).frame(width: 28)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct TemplatePreview: View {
    let template: PageTemplate
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let line = Color(red: 0.62, green: 0.72, blue: 0.86)
            switch template {
            case .blank: break
            case .lined:
                var y: CGFloat = 18
                while y < size.height - 4 {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) }, with: .color(line), lineWidth: 0.6)
                    y += 7
                }
            case .grid:
                var x: CGFloat = 6
                while x < size.width { ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(line), lineWidth: 0.4); x += 6 }
                var y: CGFloat = 6
                while y < size.height { ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) }, with: .color(line), lineWidth: 0.4); y += 6 }
            case .dotted:
                var y: CGFloat = 4.5
                while y < size.height {
                    var x: CGFloat = 4.5
                    while x < size.width { ctx.fill(Path(ellipseIn: CGRect(x: x - 0.45, y: y - 0.45, width: 0.9, height: 0.9)), with: .color(Color(white: 0.62, opacity: 0.9))); x += 4.5 }
                    y += 4.5
                }
            }
        }
    }
}

// MARK: - More

/// Panel under the "…" button: actions for the current page, the notebook and settings.
struct MorePanel: View {
    @EnvironmentObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    let doc: NoteDocument
    let current: Int
    let goTo: () -> Void
    let outline: () -> Void
    let layers: () -> Void
    let recordings: () -> Void
    let export: () -> Void
    let settings: () -> Void
    @State private var confirmDelete = false
    @State private var confirmClear = false

    private var page: NotePage? { doc.pages.indices.contains(current) ? doc.pages[current] : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let page {
                    group {
                        HStack {
                            Text("Seite \(current + 1)").font(.title3.bold())
                            Spacer()
                            PageThumbnail(doc: doc, page: page, version: 0)
                                .frame(width: 44, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                        }
                        .padding(14)
                        Divider()
                        row(page.isFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen",
                            page.isFavorite ? "star.fill" : "star") {
                            var p = page
                            p.isFavorite.toggle()
                            store.updatePage(p, in: doc.id)
                        }
                        Divider().padding(.leading, 52)
                        row("Seite kopieren", "plus.square.on.square") { store.duplicatePage(at: current, in: doc.id); dismiss() }
                        Divider().padding(.leading, 52)
                        row("Zur Gliederung hinzufügen", "list.bullet.indent") { dismiss(); outline() }
                        Divider().padding(.leading, 52)
                        HStack(spacing: 16) {
                            Image(systemName: "paintpalette").font(.title3).frame(width: 28)
                            Text("Vorlage")
                            Spacer()
                            Picker("", selection: Binding(get: { page.template }, set: { t in
                                var p = page
                                p.template = t
                                store.updatePage(p, in: doc.id)
                            })) {
                                ForEach(PageTemplate.allCases) { Text($0.label).tag($0) }
                            }
                            .disabled(page.pdfAttachment != nil)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        Divider().padding(.leading, 52)
                        row("Gehe zu Seite", "arrow.right.square", detail: "1 – \(doc.pages.count)") { dismiss(); goTo() }
                    }

                    header("Seite leeren oder löschen")
                    group {
                        row("Seite leeren", "xmark.square", role: .destructive) { confirmClear = true }
                        Divider().padding(.leading, 52)
                        row("Seite löschen", "trash", role: .destructive) { confirmDelete = true }
                    }
                }

                header("Notizbuch")
                group {
                    row("Ebenen dieser Seite", "square.3.layers.3d") { dismiss(); layers() }
                    Divider().padding(.leading, 52)
                    row("Audioaufnahmen (\(doc.recordings.count))", "waveform") { dismiss(); recordings() }
                    Divider().padding(.leading, 52)
                    row("Als PDF teilen", "square.and.arrow.up") { dismiss(); export() }
                }

                header("Einstellungen")
                group {
                    row("Stift, Pencil, Rand und Formen", "gearshape") { dismiss(); settings() }
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .frame(width: 400, height: 640)
        .confirmationDialog("Alles auf dieser Seite löschen? Das Papier bleibt.", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Seite leeren", role: .destructive) { store.clearPage(at: current, in: doc.id); dismiss() }
        }
        .confirmationDialog("Seite \(current + 1) löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { store.deletePage(at: current, in: doc.id); dismiss() }
        }
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.headline).foregroundStyle(.secondary).padding(.leading, 6)
    }

    private func group<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        VStack(spacing: 0, content: content)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func row(_ title: String, _ icon: String, detail: String? = nil, role: ButtonRole? = nil,
                     action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.title3).frame(width: 28)
                Text(title)
                Spacer()
                if let detail { Text(detail).foregroundStyle(.secondary) }
            }
            .foregroundStyle(role == .destructive ? Color.red : Color.primary)
            .padding(.horizontal, 14).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Camera / scanner

struct DocumentScanner: UIViewControllerRepresentable {
    let done: ([UIImage]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let done: ([UIImage]) -> Void
        init(done: @escaping ([UIImage]) -> Void) { self.done = done }
        func documentCameraViewController(_ c: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            done((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }
        func documentCameraViewControllerDidCancel(_ c: VNDocumentCameraViewController) { done([]) }
        func documentCameraViewController(_ c: VNDocumentCameraViewController, didFailWithError error: Error) { done([]) }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let vc = UIImagePickerController()
        vc.sourceType = .camera
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }
        func imagePickerController(_ p: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ p: UIImagePickerController) { done(nil) }
    }
}
