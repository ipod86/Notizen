# 📝 Self-Hosted Notiz-Tool

Ein schlankes, schnelles und vollständig selbstgehostetes Web-Notizbuch. Es kombiniert die Leichtigkeit von Markdown mit mächtigen Features wie einem integrierten Skizzenblock, Push-Erinnerungen, Live-Synchronisation und automatischen Backups – angetrieben von einer robusten SQLite-Datenbank und verpackt in einem einzigen, einfach zu installierenden Bash-Skript.

## ✨ Features

* **Einfacher Editor:** Markdown-Unterstützung (Fett, Kursiv, Listen, Code-Blöcke mit Highlighting, Zitate, Spoiler).
* **Live-Sync & Sperrsystem (Locking):** Automatische Aktualisierung im Hintergrund. Ein intelligentes Sperrsystem blockiert die Notiz für andere Geräte, sobald jemand tippt oder in der Historie wühlt – so werden Überschreibungen zu 100 % verhindert.
* **Versionsverlauf (Historie):** Mache Fehler rückgängig! Einstellbare Lebensdauer für alte Versionen (z. B. 30 Tage) inklusive nahtloser Wiederherstellung auf Knopfdruck.
* **Dateien & Bilder:** Drag & Drop Upload für Bilder und beliebige Dateien (bis zu 50 MB) mit nativem Fortschrittsbalken.
* **Skizzenblock:** Integriertes Zeichen-Tool für schnelle handschriftliche Notizen oder Skizzen (funktioniert per Touch am Handy, inkl. Dark-/Light-Backgrounds).
* **Erinnerungen & Webhooks:** Setze fällige Termine (Datum oder exakte Uhrzeit) und lass dich über anpassbare HTTP-Webhooks (GET/POST) via Push-Nachricht (z. B. ntfy.sh oder Discord) benachrichtigen.
* **Smarte Suche:** Durchsucht Titel und Texte rasend schnell (findet auch Wort-Teile) und klappt den Notiz-Baum automatisch genau dort auf, wo sich der Treffer befindet.
* **Organisation:** Unendlich verschachtelbare Ordnerstruktur, Drag & Drop Sortierung, @-Erwähnungen (Verlinkungen) und automatische Backlink-Anzeige (wer verlinkt auf diese Notiz?).
* **Sicherheit & Wartung:** Optionaler Passwortschutz, intelligenter nächtlicher Cronjob (löscht verwaiste Uploads erst, wenn sie auch aus der Historie abgelaufen sind).
* **Backup & Restore:** Tägliche automatische Voll-Backups (`.tar.gz`). Wiederherstellung alter Server-Backups oder das Hochladen eigener Archive funktioniert **direkt über die Benutzeroberfläche** (kein Konsolenzugriff nötig).
* **Anpassbar:** Dark- und Light-Mode sowie frei wählbare Akzentfarben direkt im Menü.

## 🚀 Installation

Das Tool wird über ein interaktives Setup-Skript installiert. Es richtet die Python-Umgebung (Flask), alle Verzeichnisse, die SQLite-Datenbank sowie die systemd-Services und Cronjobs automatisch ein.

**Voraussetzungen:** Ein Linux-Server (z. B. Ubuntu/Debian) und Root-Rechte.

### Step-by-Step

**1. Skript herunterladen:**
Lade das Installationsskript direkt von GitHub herunter:

```bash
wget -O setup.sh [https://raw.githubusercontent.com/ipod86/Notizen/main/setup.sh](https://raw.githubusercontent.com/ipod86/Notizen/main/setup.sh)
