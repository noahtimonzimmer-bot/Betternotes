import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: DocumentStore
    @EnvironmentObject var onedrive: OneDriveSync
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.doubleTap) {
                    ForEach(PencilAction.allCases) { Text($0.label).tag($0) }
                } label: { Label("Doppeltippen", systemImage: "hand.tap") }
                Picker(selection: $settings.squeeze) {
                    ForEach(PencilAction.allCases) { Text($0.label).tag($0) }
                } label: { Label("Drücken (Pencil Pro)", systemImage: "hand.pinch") }
                Toggle(isOn: $settings.onlyPencilDraws) {
                    Label("Nur mit Pencil zeichnen", systemImage: "pencil.tip")
                }
            } header: {
                Text("Apple Pencil")
            } footer: {
                Text("Mit „Nur mit Pencil zeichnen“ scrollt und zoomt der Finger, lange drücken mit dem Finger fügt ein.")
            }
            Section("Schreiben") {
                Toggle(isOn: $settings.holdToShape) {
                    Label("Formen: zeichnen und kurz halten", systemImage: "square.on.circle")
                }
                Toggle(isOn: $settings.smoothInk) {
                    Label("Handschrift leicht glätten", systemImage: "scribble.variable")
                }
                Toggle(isOn: $settings.straightenLines) {
                    Label("Gerade Linien begradigen", systemImage: "line.diagonal")
                }
                Toggle(isOn: $settings.eraserWholeStroke) {
                    Label("Radierer löscht ganze Striche", systemImage: "eraser")
                }
            }
            Section {
                Toggle(isOn: $settings.exportMarginNotes) {
                    Label("Randnotizen im PDF-Export", systemImage: "arrow.left.and.right.square")
                }
                Picker(selection: $settings.marginRatio) {
                    Text("Schmal").tag(0.15)
                    Text("Mittel").tag(0.25)
                    Text("Breit").tag(0.4)
                } label: { Label("Seitenbreite auf dem Bildschirm", systemImage: "rectangle.portrait") }
            } footer: {
                Text("Neben jeder Seite ist unbegrenzt Platz. „Seitenbreite“ legt fest, wie groß das Papier beim Öffnen erscheint. Ohne „Randnotizen im PDF-Export“ bleiben Randnotizen nur in Betternotes.")
            }
            Section {
                if OneDriveSync.clientID.hasPrefix("REPLACE") {
                    Text("Noch keine Azure-Client-ID eingetragen (siehe README).").foregroundStyle(.secondary)
                } else if onedrive.isSignedIn {
                    Button {
                        Task { await onedrive.sync(root: store.root); store.reload() }
                    } label: {
                        HStack {
                            Label("Jetzt synchronisieren", systemImage: "arrow.triangle.2.circlepath")
                            if onedrive.isSyncing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(onedrive.isSyncing)
                    Button("Abmelden", role: .destructive) { onedrive.signOut() }
                } else {
                    Button {
                        Task {
                            do { try await onedrive.signIn() } catch { self.error = error.localizedDescription }
                        }
                    } label: { Label("Bei OneDrive anmelden", systemImage: "icloud") }
                }
                if let s = onedrive.status { Text(s).font(.caption).foregroundStyle(.secondary) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("OneDrive")
            } footer: {
                Text("Spiegelt alle Notizbücher in den OneDrive-Ordner „Apps/Betternotes“ – in beide Richtungen. Geändert auf beiden Seiten: die neuere Version gewinnt.")
            }
        }
        .navigationTitle("Einstellungen")
    }
}
