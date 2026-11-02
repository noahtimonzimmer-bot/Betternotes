import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: DocumentStore
    @EnvironmentObject var onedrive: OneDriveSync
    @State private var error: String?

    var body: some View {
        Form {
            Section("Apple Pencil") {
                Picker("Doppeltippen", selection: $settings.doubleTap) {
                    ForEach(PencilAction.allCases) { Text($0.label).tag($0) }
                }
                Picker("Drücken (Pencil Pro)", selection: $settings.squeeze) {
                    ForEach(PencilAction.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Nur mit Pencil zeichnen (Finger scrollt)", isOn: $settings.onlyPencilDraws)
            }
            Section("Schreiben") {
                Toggle("Gerade Linien automatisch begradigen", isOn: $settings.straightenLines)
                Toggle("Radierer löscht ganze Striche", isOn: $settings.eraserWholeStroke)
            }
            Section {
                Picker("Schreibrand neben PDF", selection: $settings.marginRatio) {
                    Text("Schmal").tag(0.15)
                    Text("Mittel").tag(0.25)
                    Text("Breit").tag(0.4)
                }
            } footer: {
                Text("Wie in OneNote: Platz links und rechts der Seite für eigene Notizen.")
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
