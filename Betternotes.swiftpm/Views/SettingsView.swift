import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

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
                    Text("Mittel").tag(0.35)
                    Text("Breit").tag(0.6)
                }
            } footer: {
                Text("Wie in OneNote: Platz links und rechts der Seite für eigene Notizen.")
            }
        }
        .navigationTitle("Einstellungen")
    }
}
