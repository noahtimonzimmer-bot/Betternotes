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

## Auf das iPad bringen (nur iPad, kein Mac nötig)
1. **Swift Playgrounds** aus dem App Store laden (kostenlos, von Apple).
2. In Safari das Repo auf GitHub öffnen › *Code* › *Download ZIP*.
3. In der Dateien-App die ZIP antippen (entpackt sich) und den Ordner `Betternotes.swiftpm` öffnen – er startet in Swift Playgrounds.
4. Oben auf ▶︎ tippen. Die App läuft dann auf dem iPad; Notizen bleiben gespeichert.

Optional: Mit einem Apple-Developer-Account (99 $/Jahr) lässt sich die App aus Swift Playgrounds per *App Store Connect* nach TestFlight hochladen und wie eine normale App mit eigenem Symbol installieren.

Auf einem Mac geht `Betternotes.swiftpm` auch direkt in Xcode.

## OneDrive
In Safari auf portal.azure.com › *App registrations* › *New*: Kontotyp „Persönliche Microsoft-Konten“, Plattform „Mobile und Desktop“, Redirect `betternotes://auth`. Die Client-ID in `Betternotes.swiftpm/Sync/OneDriveSync.swift` eintragen.
