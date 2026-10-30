# Betternotes

Native iPad-Notizapp (SwiftUI + PencilKit). Handschrift auf PDFs, die Striche bleiben getrennt von der PDF und damit dauerhaft bearbeitbar. Öffnet bestehende GoodNotes-Dateien.

## Funktionen
- **GoodNotes-Import (`.goodnotes`)**: Seiten, PDF-Hintergründe, Striche (alle 3 bekannten Strich-Formate), Textmarker, Lasso-Verschiebungen, Whiteboards. Striche werden zu bearbeitbaren PencilKit-Strichen. Format: `docs/GOODNOTES_FORMAT.md`
- **PDF-Import**, Notizbücher, Bibliothek
- **Schreibrand** links/rechts neben jeder Seite (wie OneNote), Breite einstellbar
- **Apple Pencil**: Doppeltippen und Drücken (Pencil Pro) frei belegbar – Werkzeugauswahl an der Stiftspitze, Radierer für einen Zug (danach zurück zum Stift), Radierer ein/aus, vorheriges Werkzeug, Lasso
- **Gerade Linien** werden automatisch begradigt (abschaltbar)
- **Foto-Werkzeug**: Bereich aufziehen → Bild in der Zwischenablage
- Stift, Bleistift, Textmarker, Radierer (ganze Striche oder pixelweise), Lasso, Farben, Strichstärke
- OneDrive: Anmeldung, Upload, Download (Abgleich folgt)

## Noch offen
- GoodNotes: Textfelder, Formen, Bilder anzeigen; Export zurück nach `.goodnotes`
- OneDrive-Abgleich in beide Richtungen
- Zoom, Seiten hinzufügen/verschieben, Suche, Ebenen

## Werkzeuge zur Analyse
```bash
python3 tools/goodnotes.py datei.goodnotes ausgabe/
```
rendert jede Seite als PNG (PDF + Handschrift), braucht Pillow und `pdftoppm`.

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
