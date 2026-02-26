# 📝 Self-Hosted Notiz-Tool

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
Lade das Installationsskript direkt von GitHub herunter:

```bash
wget -O setup.sh https://raw.githubusercontent.com/ipod86/Notizen/main/setup.sh
```

**2. Skript ausführbar machen:**
```bash
chmod +x setup.sh
```

**3. Installation starten:**
Führe das Skript als Root aus. Es wird dich durch die grundlegenden Einstellungen (Port, Autostart, Cronjobs) führen.
```bash
sudo ./setup.sh
```

**4. Fertig!**
Sobald die Installation abgeschlossen ist, erreichst du dein Notiz-Tool im Browser unter:
`http://<deine-server-ip>:8080` (bzw. dem Port, den du im Setup gewählt hast).

## 🛠️ Updates

Um das Tool zu aktualisieren, lade einfach die neueste Version des `setup.sh` Skripts herunter und führe es erneut aus. Es überschreibt die App-Dateien, lässt deine bestehenden Notizen (`data.json`) und Uploads aber völlig unangetastet.

## 🌐 Hinweis zu externen Bibliotheken (CDNs)

Das Tool lädt standardmäßig einige wenige externe Bibliotheken (z. B. SortableJS für Drag & Drop, Highlight.js für Code-Highlighting) über schnelle Content Delivery Networks (CDNs). 

Wenn du das Tool **komplett offline** (ohne jeglichen externen Internetverkehr) betreiben möchtest, kannst du die entsprechenden `.js` und `.css` Dateien manuell herunterladen, im Ordner `/opt/notiz-tool/static/` ablegen und die Pfade in der Datei `/opt/notiz-tool/templates/index.html` anpassen.

**Wichtig bei Updates:** Wenn du später ein Update über das `setup.sh` Skript durchführst, wird die `index.html` wieder mit den Standard-CDN-Links überschrieben. Du musst deine lokalen Pfade in der HTML-Datei nach einem Update also manuell wieder nachtragen.
> **Hinweis:** Dieses Projekt sowie die zugehörige Dokumentation wurden unter Zuhilfenahme von Künstlicher Intelligenz (Gemini) iterativ entwickelt und für den praktischen Einsatz optimiert.
