# 📝 Self-Hosted Notiz-Tool

Ein schlankes, schnelles und vollständig selbstgehostetes Web-Notizbuch. Es kombiniert die Leichtigkeit von Markdown mit mächtigen Features wie einem integrierten Skizzenblock, Push-Erinnerungen, Live-Synchronisation und automatischen Backups – angetrieben von einer robusten SQLite-Datenbank und verpackt in einem einzigen, einfach zu installierenden Bash-Skript.

## ✨ Features

Das Notiz-Tool bietet eine Vielzahl an Funktionen, die es zu einer vollwertigen, selbstgehosteten Notiz- und Wissensdatenbank machen:

### 🛡️ Sicherheit & Multi-Device
* **Multi-Instanz fähig:** Komfortables Setup-Skript zum Anlegen, Updaten und Löschen beliebig vieler unabhängiger Instanzen auf einem Server.
* **Passwortschutz:** Optionaler Zugriffsschutz für die gesamte Instanz.
* **Brute-Force-Schutz:** Intelligente IP-Sperre bei zu vielen fehlerhaften Login-Versuchen.
* **Kollisions-Schutz (Locking):** Sperrt Notizen für andere Geräte/Tabs, während sie von jemandem bearbeitet werden, um unbeabsichtigtes Überschreiben zu verhindern.

### 🔔 Benachrichtigungen & Aufgaben
* **Push-Benachrichtigungen (Webhooks):** Sende zeitgesteuerte Erinnerungen an dein Smartphone (z.B. via ntfy.sh) oder als formatierte Nachricht an Discord (unterstützt GET und POST mit JSON-Payload).
* **To-Do Dashboard:** Eine zentrale Übersicht aller offenen und erledigten Checkboxen aus allen Notizen.

### 📝 Editor & Inhalte
* **Markdown-Support:** Umfangreiche Formatierungen (Fett, Kursiv, Tabellen, Zitate, Code-Blöcke).
* **Drag & Drop Uploads:** Bilder und Dateien einfach in den Textbereich ziehen.
* **Skizzen-Block:** Integriertes Zeichen-Tool mit Stift, Textmarker und Radiergummi für handschriftliche Notizen.
* **Verlinkungen (Mentions):** Tippe `@`, um blitzschnell andere Notizen im Text zu verlinken.
* **Sprachnotiz:** Sprachaufnahmen direkt in der App aufnhemen und abspielen..

### 🌍 Freigaben & Verwaltung
* **Öffentliche Freigabe-Links:** Generiere Lese-Links für einzelne Notizen, um sie mit Leuten ohne Account zu teilen.
* **Versionsverlauf (Historie):** Jeder Speichervorgang wird gesichert. Kehre jederzeit zu einer alten Version einer Notiz zurück.
* **Papierkorb:** Gelöschte Notizen landen im Papierkorb und können samt Unterstruktur wiederhergestellt werden.
* **Automatisches Sortieren:** Notizen lassen sich auf Knopfdruck alphabetisch ordnen (Ordner stehen immer oben).
* **Backup & Restore:** Vollautomatische nächtliche Backups, die direkt über die Web-Oberfläche heruntergeladen oder wiederhergestellt werden können.

## 🚀 Installation

Das Tool wird über ein interaktives Setup-Skript installiert. Es richtet die Python-Umgebung (Flask), alle Verzeichnisse, die SQLite-Datenbank sowie die systemd-Services und Cronjobs automatisch ein.

**Voraussetzungen:** Ein Linux-Server (z. B. Ubuntu/Debian) und Root-Rechte.

### Step-by-Step

**1. Skript herunterladen:**
Lade das Installationsskript direkt von GitHub herunter:

```bash
wget -O setup_notes_sql_lite.sh [https://raw.githubusercontent.com/ipod86/Notizen/main/setup_notes_sql_lite.sh](https://raw.githubusercontent.com/ipod86/Notizen/main/setup_notes_sql_lite.sh) && chmod +x setup_notes_sql_lite.sh && sudo ./setup_notes_sql_lite.sh
```

## Verwendete Open-Source-Bibliotheken & Ressourcen

Dieses Projekt nutzt folgende Open-Source-Bibliotheken und freie Ressourcen:

* **[Flask](https://flask.palletsprojects.com/) & [SQLite](https://www.sqlite.org/):** Web-Framework für das Python-Backend und lokale relationale Datenbank.
* **[SortableJS](https://sortablejs.github.io/Sortable/):** Drag-and-Drop-Funktionalität für die Strukturierung des Notizbaums.
* **[Highlight.js](https://highlightjs.org/):** Syntax-Highlighting für Code-Blöcke innerhalb der Notizen.
* **[Material Design Icons](https://pictogrammers.com/library/mdi/):** Die in der Benutzeroberfläche verwendeten SVG-Icons entstammen der Pictogrammers-Bibliothek.
