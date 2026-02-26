# 📝 Self-Hosted Notiz-Tool

> **Hinweis:** Der Code für dieses Projekt sowie diese Dokumentation wurden vollständig und iterativ mithilfe von Künstlicher Intelligenz (Gemini) generiert und nach meinen spezifischen Anforderungen im praktischen Einsatz optimiert.

Ein schlankes, schnelles und vollständig selbstgehostetes Web-Notizbuch. Es kombiniert die Leichtigkeit von Markdown mit mächtigen Features wie einem integrierten Skizzenblock, Live-Synchronisation und automatischen Backups – alles verpackt in einem einzigen, einfach zu installierenden Bash-Skript.

## ✨ Features

* **Einfacher Editor:** Markdown-Unterstützung (Fett, Kursiv, Listen, Code-Blöcke, Zitate, Spoiler).
* **Live-Sync:** Automatische Aktualisierung im Hintergrund (alle 30 Sekunden), ideal für die parallele Nutzung auf Smartphone und PC. Konflikterkennung verhindert versehentliches Überschreiben.
* **Dateien & Bilder:** Drag & Drop Upload für Bilder und beliebige Dateien (bis zu 20 MB).
* **Skizzenblock:** Integriertes Zeichen-Tool für schnelle handschriftliche Notizen oder Skizzen (funktioniert auch per Touch am Handy).
* **Organisation:** Unendlich verschachtelbare Ordnerstruktur, Drag & Drop Sortierung und @-Erwähnungen (Verlinkungen) zwischen Notizen.
* **Sicherheit & Wartung:** Optionaler Passwortschutz, tägliches automatisches Voll-Backup (tar.gz) und nächtliche Bereinigung von ungenutzten (gelöschten) Uploads.
* **Anpassbar:** Dark- und Light-Mode sowie frei wählbare Akzentfarben.

## 🚀 Installation

Das Tool wird über ein interaktives Setup-Skript installiert. Es richtet die Python-Umgebung (Flask), alle Verzeichnisse und auf Wunsch auch die systemd-Services und Cronjobs automatisch ein.

**Voraussetzungen:** Ein Linux-Server (z.B. Ubuntu/Debian) und Root-Rechte.

### Step-by-Step

**1. Skript herunterladen:**
Lade das Installationsskript direkt von GitHub herunter. 
*(Ersetze `DEIN_NAME` und `DEIN_REPO` mit deinen echten GitHub-Daten)*

```bash
wget [https://raw.githubusercontent.com/DEIN_NAME/DEIN_REPO/main/install.sh](https://raw.githubusercontent.com/DEIN_NAME/DEIN_REPO/main/install.sh)
