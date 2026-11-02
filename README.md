# Betternotes

Native iPad-Notizapp (SwiftUI + PencilKit). Handschrift auf PDFs, die Striche bleiben getrennt von der PDF und damit dauerhaft bearbeitbar. Öffnet bestehende GoodNotes-Dateien.

## Funktionen
- **Bibliothek wie OneNote**: links Ordner (verschachtelt) und Notizbücher, per Kontextmenü oder Drag & Drop verschieben, umbenennen, löschen; Suche nach Titeln
- **GoodNotes-Import (`.goodnotes`)**: Seiten, PDF-Hintergründe, Striche (alle 3 bekannten Formate), Textmarker, Lasso-Verschiebungen, Whiteboards, Bilder, Textfelder → bearbeitbare PencilKit-Striche bzw. Objekte. Format: `docs/GOODNOTES_FORMAT.md`
- **PDF-Import**, neue Notizbücher mit Vorlage (leer, liniert, kariert, gepunktet)
- **Editor**: Zoom (zwei Finger), flüssig auch bei 100+ Seiten, Seitenübersicht links, Seite hinzufügen/duplizieren/löschen/verschieben, Vorlage pro Seite, „Gehe zu Seite“, Rückgängig/Wiederholen
- **Endloser Schreibrand**: links und rechts jeder Seite Platz zum Schreiben; schreibst du nahe am Rand, wächst er automatisch weiter (Seite scrollt dann seitlich). Einstellbar, ob Randnotizen im PDF-Export erscheinen oder nur in der App bleiben
- **Werkzeuge**: Füller, Bleistift, Textmarker, Radierer (ganze Striche oder pixelweise), Formen (Linie, Rechteck, Ellipse), Lasso, **Kamera-Lasso** (Bereich umkreisen → Bild direkt in der Zwischenablage), Text & Objekte (Textfelder, Bilder verschieben/skalieren)
- **Apple Pencil**: Doppeltippen und Drücken (Pencil Pro) frei belegbar – Werkzeugauswahl an der Stiftspitze, Radierer für einen Zug, Radierer ein/aus, vorheriges Werkzeug, Lasso, Kamera-Lasso
- **Formerkennung wie GoodNotes**: zeichnen und kurz halten → die Form rastet sofort ein (Vibration), weiter ziehen ohne abzuheben skaliert/dreht sie → Rechteck (exakte rechte Winkel, auch gedreht), Kreis, Ellipse, Dreieck, Vieleck, Linie oder rechter Winkel; mit jedem Stift
- **Gerade Linien** werden automatisch begradigt (abschaltbar)
- **Bilder** aus Fotos oder Zwischenablage einfügen
- **Suche** im PDF-Text, in Textfeldern und in der **Handschrift** (Texterkennung Deutsch/Englisch, wird pro Seite zwischengespeichert)
- **Tabs**: mehrere Notizbücher gleichzeitig offen
- **Audioaufnahmen** pro Notizbuch (Aufnehmen, Liste, Abspielen, Löschen)
- **PDF-Export** mit Handschrift (inkl. Rand, wenn dort geschrieben wurde) über das Teilen-Menü
- **OneDrive-Synchronisation** in beide Richtungen

## Noch offen
- GoodNotes: Formen übernehmen (in den Beispieldateien alle gelöscht, daher ungetestet); Export zurück nach `.goodnotes`
- Ebenen, Bild zuschneiden, Laserpointer, Stift-Favoriten

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
