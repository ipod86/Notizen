#!/bin/bash

# Installationsverzeichnis (passe dies an, falls deine 2. Instanz z.B. /opt/notiz-tool-2 heißt)
INSTALL_DIR="/opt/notiz-tool"
JSON_FILE="$INSTALL_DIR/data.json"
DB_FILE="$INSTALL_DIR/data.db"
TEMP_SCRIPT="$INSTALL_DIR/run_import.py"

echo "--- JSON zu SQLite Import-Tool ---"

# 1. Root-Rechte prüfen
if [ "$EUID" -ne 0 ]; then
    echo "FEHLER: Bitte führe dieses Skript als Root (z.B. sudo) aus!"
    exit 1
fi

# 2. Prüfen, ob die JSON-Datei existiert
if [ ! -f "$JSON_FILE" ]; then
    echo "FEHLER: Die Datei $JSON_FILE wurde nicht gefunden."
    echo "Bitte lade deine alte data.json zuerst in den Ordner $INSTALL_DIR hoch."
    exit 1
fi

# 3. Existierende Datenbank radikal löschen
echo "Lösche existierende Datenbank..."
rm -f "$DB_FILE"
rm -f "$DB_FILE-wal"
rm -f "$DB_FILE-shm"

echo "Erstelle temporäres Python-Import-Skript..."

# 4. Python-Skript generieren
cat << 'EOF' > $TEMP_SCRIPT
import json
import sqlite3
import sys
import os

json_file = sys.argv[1]
db_file = sys.argv[2]

try:
    with open(json_file, 'r', encoding='utf-8') as f:
        data = json.load(f)
except Exception as e:
    print(f"Fehler beim Lesen der JSON-Datei: {e}")
    sys.exit(1)

conn = sqlite3.connect(db_file)
# Aktiviere Write-Ahead-Logging wie im Hauptprogramm
conn.execute('PRAGMA journal_mode=WAL')
cursor = conn.cursor()

# Tabellenstruktur neu anlegen, da die DB frisch ist
cursor.execute('''
    CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY, 
        value TEXT
    )
''')
cursor.execute('''
    CREATE TABLE IF NOT EXISTS notes (
        id TEXT PRIMARY KEY,
        parent_id TEXT,
        sort_order INTEGER,
        title TEXT,
        text TEXT,
        reminder TEXT,
        locked_by TEXT,
        locked_at REAL
    )
''')
cursor.execute('''
    CREATE TABLE IF NOT EXISTS note_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        note_id TEXT,
        title TEXT,
        text TEXT,
        saved_at REAL
    )
''')

# Standard-Einstellungen schreiben
cursor.execute("INSERT INTO settings (key, value) VALUES ('theme', 'dark')")
cursor.execute("INSERT INTO settings (key, value) VALUES ('accent', '#27ae60')")
cursor.execute("INSERT INTO settings (key, value) VALUES ('password_enabled', 'false')")
cursor.execute("INSERT INTO settings (key, value) VALUES ('history_enabled', 'true')")
cursor.execute("INSERT INTO settings (key, value) VALUES ('history_days', '30')")
cursor.execute("INSERT INTO settings (key, value) VALUES ('tree_last_modified', '0')")

# Rekursive Funktion für den sauberen Baum-Aufbau
def insert_node(node, parent_id=None, sort_order=0):
    cursor.execute('''
        INSERT INTO notes (id, parent_id, sort_order, title, text, reminder)
        VALUES (?, ?, ?, ?, ?, ?)
    ''', (
        node.get('id'),
        parent_id,
        sort_order,
        node.get('title', 'Neu'),
        node.get('text', ''),
        node.get('reminder', None)
    ))
    
    # Kinder-Elemente (Unterordner/Notizen) verarbeiten
    children = node.get('children', [])
    for index, child in enumerate(children):
        insert_node(child, node.get('id'), index)

try:
    if isinstance(data, dict) and 'content' in data:
        nodes = data['content']
    elif isinstance(data, list):
        nodes = data
    else:
        print("Fehler: Unbekanntes JSON-Format. Weder Liste noch 'content'-Objekt gefunden.")
        sys.exit(1)
        
    print(f"Gefundene Hauptknoten: {len(nodes)}. Starte Import...")
    
    for index, node in enumerate(nodes):
        insert_node(node, None, index)
        
    conn.commit()
    print("Erfolg! Alle Notizen wurden sauber in die neue SQLite-Datenbank übertragen.")
    
except Exception as e:
    print(f"Datenbank-Fehler während des Imports: {e}")
finally:
    conn.close()
EOF

# 5. Import ausführen
echo "Starte Datenmigration..."
python3 $TEMP_SCRIPT "$JSON_FILE" "$DB_FILE"

# 6. Rechte für den Systemdienst korrigieren
echo "Korrigiere Dateirechte..."
chown notizen:notizen "$DB_FILE"
if [ -f "$DB_FILE-wal" ]; then chown notizen:notizen "$DB_FILE-wal"; fi
if [ -f "$DB_FILE-shm" ]; then chown notizen:notizen "$DB_FILE-shm"; fi

# 7. Aufräumen
echo "Räume auf..."
rm -f $TEMP_SCRIPT

# Service neustarten
systemctl restart notizen.service

echo "--- Import komplett abgeschlossen! ---"
