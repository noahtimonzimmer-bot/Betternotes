# GoodNotes-Dateiformat (`.goodnotes`, schema 26)

Reverse-engineered aus eigenen Exporten zur Interoperabilität. Referenz-Implementierung:
`tools/goodnotes.py` (rendert jede Seite als PNG), Swift-Port: `Betternotes/Import/GoodNotesFormat.swift`.
Verifiziert durch Vergleich der gerenderten Seiten mit `thumbnail.jpg` und Screenshots aus GoodNotes.

## Container
ZIP-Archiv:

| Pfad | Inhalt |
|---|---|
| `schema.pb` | `{1: 26}` Schema-Version |
| `index.events.pb` | Ereignis-Log: Dokument, Seiten, Ebenen, Anhänge |
| `index.notes.pb` | `{1: notes-id, 2: "notes/<id>"}` je Ebene |
| `index.attachments.pb` | `{1: attachment-id, 2: "attachments/<file>"}` |
| `notes/<id>` | Objekte (Striche, Formen, Text, Bilder) einer Ebene |
| `attachments/<file>` | Original-PDFs / Bilder, unverändert |
| `search/<id>` | Handschrift-/Text-Suchindex (nicht nötig zum Anzeigen) |
| `thumbnail.jpg` | Vorschau der ersten Seite |

Alle `.pb`-Dateien und `notes/*` sind **Folgen längenpräfixierter Protobuf-Nachrichten**
(varint Länge, dann Nachricht).

## index.events.pb
Jede Nachricht: `{1: objekt-id, <typ>: {...}}`. Relevante Typen:

| Typ | Bedeutung | Felder |
|---|---|---|
| 30 | Dokument | `2.1` Titel |
| 6 | Anhang | `1` id, `2` Datei, `6` Dokument |
| 2 | Seite | `2` Seiten-id, `4` Anhang-id (PDF), `5` PDF-Seite (1-basiert), `8` Größe `{1: f32 w, 2: f32 h}` |
| 64 | Whiteboard | `2` Ebenen-id, `3.1` Name |
| 54 | Ebene | `2` Ebenen-id, `3.1` Seiten-id, `4.1` Sortierschlüssel (fractional index) |
| 62 | Gliederung/Lesezeichen | `5` Titel, `3.1` Position |
| 104/105 | Such-/Indexstatus | – |

Seitenkoordinaten: PDF-Punkte × ~1,8335 (A4 = 1091,6 × 1543,7).
Whiteboards haben keine Größe; ihre Koordinaten liegen um (250000, 250000).

**Ebene → Datei:** `notes/<Ebenen-UUID + 1>` (UUID als 128-Bit-Zahl plus eins).

## notes/<id>
Paare aus Kopf und Körper.

Kopf: `1` Objekt-id, `2` `{1: Revision, 2: Hash}`, `3` = 1 → **gelöscht** (Tombstone), `9` Sequenz.

Körper (genau ein Feld):

| Feld | Objekt |
|---|---|
| 7 | Strich (Stift, Textmarker) |
| 1 | Bild: `2` Rahmen `{1:{x,y},2:{w,h}}`, `3` Zuschnitt, `4` Anhang-id |
| 21 | Textfeld: `20.1` Position, `32.1.2` Text (bv4-komprimiertes Protobuf), `32.5.1.30` Schrift, `.40` Größe |
| 22 | Form: `21` Punkte, `32.1` Linienbreite, `32.3.1` Farbe |
| 9 | Fläche (z. B. Lasso-Füllung), `7` Farbe |

### Strich (Körper-Feld 7)
| Feld | Inhalt |
|---|---|
| 1 | id |
| 2 | Pfad, **bv4-komprimiert** (s. u.) |
| 4 | Farbe `{1:r, 2:g, 3:b, 4:a}` f32 0…1 (a < 1 → Textmarker) |
| 6 | Verschiebung `{1: dx, 2: dy}` (Lasso-Bewegung), auf alle Punkte addieren |
| 9 | Begradigte Linie: zwei Endpunkte, `15` Breite |
| 14 | 1 bei gelöschten Strichen |

### bv4-Kompression (Apple LZ4-Framing)
`"bv41" u32 raw u32 comp <LZ4-Block>` … `"bv4-" u32 n <roh>` … `"bv4$"`.
Entspricht `COMPRESSION_LZ4` des Apple-Compression-Frameworks.

### tpl-Container (dekomprimierter Pfad)
`"tpl\0" u32 Gesamtlänge <Typsignatur>\0 <Daten>`, little endian.
Typen: `v` u16, `u`/`f` 32 Bit (als f32), `A(x)` u32 Anzahl + Elemente, `S(...)` Struktur.

Bekannte Pfad-Signaturen:
1. `vuA(v)A(S(uu))A(S(uuuu))vA(f)` – Version, Breite, Ops (0 = Start, 1 = Segment),
   Startpunkte (x,y), quadratische Bézier-Segmente (cx,cy,x,y), Flags, Extras.
2. `vuA(v)A(S(uuuuu))A(S(uuuuuuuuuuu))A(S(uu))A(v)A(S(uu))A(S(uuuu))A(u)` – druckabhängig:
   Start (x,y,w,…), Segment (?,cx,cy,cw,…,x,y,w,…).
3. `[vu]A(v)A(u)A(u)A(v)A(v)A(u)A(u)A(u)A(u)A(v)` – v2 flach: Ops, Startpunkte und Segmente als flache Float-Listen.

## Offen
- Textfeld-Inhalt (attributierter Text) vollständig auswerten
- Formen (Feld 22) und Bilder (Feld 1) rendern
- Schreiben (Export zurück nach `.goodnotes`): eigene Objekte als Typ-7-Striche mit Signatur 1,
  neue UUIDs, Revision 1 – Round-Trip mit GoodNotes testen
