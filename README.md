# Betternotes

Native iPad-Notizapp (SwiftUI + PencilKit): Handschrift auf PDFs, die Striche bleiben getrennt von der PDF und damit dauerhaft bearbeitbar.

## Stand
- Bibliothek, Notizbuch-Editor mit Apple Pencil, PDF-Import
- `.goodnotes`-Import: Container und PDFs (Striche folgen, sobald Beispieldateien vorliegen, siehe `docs/GOODNOTES_FORMAT.md`)
- OneDrive: Anmeldung, Upload, Download (Abgleich folgt)

## Auf das iPad bringen (Mac mit Xcode nötig)
```bash
brew install xcodegen
```
```bash
xcodegen generate
```
```bash
open Betternotes.xcodeproj
```
In Xcode: Team unter *Signing & Capabilities* wählen, iPad anschließen, Run.

## OneDrive
In Azure unter *App registrations* eine App anlegen (Redirect `msauth.com.betternotes.app://auth`), die Client-ID in `Betternotes/Sync/OneDriveSync.swift` eintragen.
