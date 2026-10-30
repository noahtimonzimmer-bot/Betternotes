# GoodNotes-Dateiformat (Analyse)

Ziel: eigene `.goodnotes`-Exporte lesen und schreiben (Interoperabilität mit den eigenen Notizen).

## Bekannt / Annahmen (noch zu verifizieren)
- `.goodnotes` ist ein ZIP-Archiv.
- Importierte PDFs liegen als normale PDF-Dateien im Archiv (Seitenhintergrund, unverändert).
- Striche, Texte, Bilder liegen getrennt davon in Binärdateien (vermutlich Protobuf).

## Analyse-Ablauf, sobald Beispieldateien da sind (`samples/`)
1. `unzip -l datei.goodnotes` – Dateistruktur erfassen.
2. Leeres Notizbuch vs. Notizbuch mit genau einem Strich vergleichen (Binär-Diff), dann Stiftart, Farbe, Dicke einzeln ändern.
3. `protoc --decode_raw < datei` auf die Binärdateien, Felder den Eigenschaften zuordnen.
4. Schema in diesem Dokument festhalten, dann Parser in `GoodNotesImporter.swift`, Mapping auf `PKStroke`.
5. Writer: Round-Trip-Test – importieren, exportieren, in GoodNotes wieder öffnen.

Hinweis: nur eigene Dateien analysieren; keine Dekompilierung der App.
