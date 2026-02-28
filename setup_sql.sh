#!/bin/bash

# Root-Rechte prüfen
if [ "$EUID" -ne 0 ]; then
    echo "FEHLER: Bitte führe dieses Skript als Root (z.B. sudo) aus!"
    exit 1
fi

# 1. Port & Einstellungen
echo "Welcher Port soll für das Notiz-Tool genutzt werden? (Standard: 8080)"
read -p "Port: " USER_PORT
if [ -z "$USER_PORT" ]; then 
    USER_PORT=8080
fi

echo "Soll das Tool als Systemdienst eingerichtet und beim Systemstart automatisch geladen werden? (Y/n)"
read -p "Autostart: " AUTOSTART_CONFIRM
if [ -z "$AUTOSTART_CONFIRM" ]; then 
    AUTOSTART_CONFIRM="y"
fi

echo "Soll ein nächtlicher Cleanup-Cronjob (03:00 Uhr) angelegt werden? (Y/n)"
read -p "Cleanup-Cronjob: " CRON_CONFIRM
if [ -z "$CRON_CONFIRM" ]; then 
    CRON_CONFIRM="y"
fi

echo "Soll ein tägliches SQLite-Voll-Backup (04:00 Uhr) eingerichtet werden? (Y/n)"
read -p "Backup-Cronjob: " BACKUP_CONFIRM
if [ -z "$BACKUP_CONFIRM" ]; then 
    BACKUP_CONFIRM="y"
fi

INSTALL_DIR="/opt/notiz-tool"
SERVICE_NAME="notizen.service"

echo "--- Stoppe alten Service (falls aktiv) ---"
systemctl stop $SERVICE_NAME 2>/dev/null

echo "--- Starte V2 SQLite Setup in $INSTALL_DIR auf Port $USER_PORT ---"

# 2. Abhängigkeiten installieren
apt update && apt install -y python3 python3-pip python3-venv cron sqlite3 wget

# 3. Verzeichnisstruktur erstellen
mkdir -p $INSTALL_DIR/static 
mkdir -p $INSTALL_DIR/templates 
mkdir -p $INSTALL_DIR/uploads 
mkdir -p $INSTALL_DIR/backups

# 4. Python Umgebung einrichten
python3 -m venv $INSTALL_DIR/venv
$INSTALL_DIR/venv/bin/python3 -m pip install flask werkzeug requests

# 5. Originale CSS von GitHub laden (damit dein altes Design bleibt!)
echo "Lade originale style.css von GitHub..."
wget -qO $INSTALL_DIR/static/style.css https://raw.githubusercontent.com/ipod86/Notizen/main/static/style.css

# 6. Dateien schreiben

# app.py (SQLite Backend)
cat << 'EOF' > $INSTALL_DIR/app.py
from flask import Flask, render_template, request, jsonify, send_from_directory, session, redirect, url_for, send_file
from werkzeug.security import generate_password_hash, check_password_hash
import json
import os
import uuid
import tarfile
import io
import time
import base64
import requests
import urllib.parse
import threading
import sqlite3
import tempfile
import shutil
from datetime import datetime

app = Flask(__name__)

SECRET_FILE = 'secret.key'
if not os.path.exists(SECRET_FILE):
    with open(SECRET_FILE, 'wb') as f:
        f.write(os.urandom(24))
        
with open(SECRET_FILE, 'rb') as f:
    app.secret_key = f.read()

app.config['MAX_CONTENT_LENGTH'] = 50 * 1024 * 1024

DB_FILE = 'data.db'
OLD_JSON = 'data.json'
UPLOAD_FOLDER = 'uploads'
BACKUP_FOLDER = 'backups'

def get_db():
    conn = sqlite3.connect(DB_FILE, timeout=15.0)
    conn.row_factory = sqlite3.Row
    conn.execute('PRAGMA journal_mode=WAL')
    conn.execute('PRAGMA synchronous=NORMAL')
    conn.execute('PRAGMA foreign_keys=ON')
    return conn

def init_db():
    with get_db() as conn:
        conn.execute('''
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY, 
                value TEXT
            )
        ''')
        
        conn.execute('''
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
        
        if not conn.execute("SELECT key FROM settings WHERE key='theme'").fetchone():
            conn.execute("INSERT INTO settings (key, value) VALUES ('theme', 'dark')")
            conn.execute("INSERT INTO settings (key, value) VALUES ('accent', '#27ae60')")
            conn.execute("INSERT INTO settings (key, value) VALUES ('password_enabled', 'false')")
            conn.execute("INSERT INTO settings (key, value) VALUES ('tree_last_modified', '0')")
            
        conn.execute('''
            CREATE TRIGGER IF NOT EXISTS update_tree_mod 
            AFTER UPDATE OF parent_id, sort_order, title, reminder ON notes 
            BEGIN 
                UPDATE settings SET value = strftime('%s', 'now') WHERE key = 'tree_last_modified'; 
            END;
        ''')
        
        conn.execute('''
            CREATE TRIGGER IF NOT EXISTS insert_tree_mod 
            AFTER INSERT ON notes 
            BEGIN 
                UPDATE settings SET value = strftime('%s', 'now') WHERE key = 'tree_last_modified'; 
            END;
        ''')
        
        conn.execute('''
            CREATE TRIGGER IF NOT EXISTS delete_tree_mod 
            AFTER DELETE ON notes 
            BEGIN 
                UPDATE settings SET value = strftime('%s', 'now') WHERE key = 'tree_last_modified'; 
            END;
        ''')

    if os.path.exists(OLD_JSON):
        print("[MIGRATION] Konvertiere data.json zu SQLite...", flush=True)
        try:
            with open(OLD_JSON, 'r') as f: 
                data = json.load(f)
                
            with get_db() as conn:
                for k, v in data.get('settings', {}).items():
                    val_str = str(v).lower() if isinstance(v, bool) else str(v)
                    conn.execute("REPLACE INTO settings (key, value) VALUES (?, ?)", (k, val_str))
                
                def import_nodes(nodes, parent_id=None):
                    for idx, n in enumerate(nodes):
                        conn.execute('''
                            INSERT OR IGNORE INTO notes (id, parent_id, sort_order, title, text, reminder) 
                            VALUES (?, ?, ?, ?, ?, ?)
                        ''', (n['id'], parent_id, idx, n.get('title', 'Neu'), n.get('text', ''), n.get('reminder')))
                        if 'children' in n: 
                            import_nodes(n['children'], n['id'])
                
                import_nodes(data.get('content', []))
                conn.execute("UPDATE settings SET value = strftime('%s', 'now') WHERE key = 'tree_last_modified'")
            
            os.rename(OLD_JSON, OLD_JSON + '.bak')
            print("[MIGRATION] Erfolgreich!", flush=True)
        except Exception as e: 
            print(f"[MIGRATION] Fehler: {e}", flush=True)

def webhook_worker():
    sent_reminders = set()
    while True:
        try:
            with get_db() as conn:
                en = conn.execute("SELECT value FROM settings WHERE key='webhook_enabled'").fetchone()
                
                if en and en['value'] == 'true':
                    url_r = conn.execute("SELECT value FROM settings WHERE key='webhook_url'").fetchone()
                    method_r = conn.execute("SELECT value FROM settings WHERE key='webhook_method'").fetchone()
                    payload_r = conn.execute("SELECT value FROM settings WHERE key='webhook_payload'").fetchone()
                    
                    url = url_r['value'] if url_r else ''
                    method = method_r['value'] if method_r else 'GET'
                    payload = payload_r['value'] if payload_r else ''
                    now = datetime.now()
                    
                    reminders = conn.execute("SELECT id, title, reminder FROM notes WHERE reminder IS NOT NULL AND reminder != ''").fetchall()
                    
                    for r in reminders:
                        try:
                            r_str = r['reminder'].replace('Z', '')
                            if len(r_str) == 10:
                                r_dt = datetime.strptime(r_str, '%Y-%m-%d')
                            else:
                                r_dt = datetime.fromisoformat(r_str)
                                
                            key = f"{r['id']}_{r_str}"
                            
                            if r_dt <= now and key not in sent_reminders:
                                if url:
                                    su = urllib.parse.quote(r['title'])
                                    st = urllib.parse.quote(r_str)
                                    final_url = url.replace('{{TITLE}}', su).replace('{{TIME}}', st)
                                    
                                    if method == 'GET': 
                                        requests.get(final_url, timeout=10)
                                    else:
                                        sj = r['title'].replace('"', '\\"').replace('\n', ' ')
                                        pd = payload.replace('{{TITLE}}', sj).replace('{{TIME}}', r_str)
                                        requests.post(final_url, data=pd.encode('utf-8'), headers={'Content-Type': 'application/json'}, timeout=10)
                                        
                                sent_reminders.add(key)
                        except Exception as inner_e: 
                            pass
        except Exception as outer_e: 
            pass
        
        time.sleep(30)

init_db()
threading.Thread(target=webhook_worker, daemon=True).start()

@app.after_request
def add_header(response):
    if request.path.startswith('/uploads/'):
        response.headers['Cache-Control'] = 'public, max-age=31536000'
        return response
    response.headers['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
    return response

def get_settings():
    with get_db() as conn:
        rows = conn.execute("SELECT key, value FROM settings").fetchall()
        sets = {}
        for r in rows:
            v = r['value']
            if v == 'true': 
                v = True
            elif v == 'false': 
                v = False
            sets[r['key']] = v
        return sets

@app.before_request
def require_login():
    if request.endpoint in ['login', 'static']: 
        return
        
    sets = get_settings()
    if sets.get('password_enabled') and not session.get('logged_in'):
        if request.path.startswith('/api/'): 
            return jsonify({"error": "Unauthorized"}), 401
        return redirect(url_for('login'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    sets = get_settings()
    if not sets.get('password_enabled'): 
        return redirect(url_for('index'))
        
    if request.method == 'POST':
        if check_password_hash(sets.get('password_hash', ''), request.form.get('password')):
            session['logged_in'] = True
            return redirect(url_for('index'))
        return render_template('login.html', theme=sets.get('theme', 'dark'), accent=sets.get('accent', '#27ae60'), error="Falsches Passwort", v=str(time.time()))
        
    return render_template('login.html', theme=sets.get('theme', 'dark'), accent=sets.get('accent', '#27ae60'), v=str(time.time()))

@app.route('/logout')
def logout():
    session.pop('logged_in', None)
    return redirect(url_for('login'))

@app.route('/')
def index():
    return render_template('index.html', v=str(time.time()))

@app.route('/api/tree', methods=['GET'])
def get_tree():
    with get_db() as conn:
        rows = conn.execute("SELECT id, parent_id, sort_order, title, reminder FROM notes ORDER BY sort_order").fetchall()
        sets = get_settings()
        
        nodes_by_parent = {}
        for r in rows:
            pid = r['parent_id']
            if pid not in nodes_by_parent: 
                nodes_by_parent[pid] = []
            nodes_by_parent[pid].append(dict(r))
            
        def build_tree(pid=None):
            children = nodes_by_parent.get(pid, [])
            for c in children: 
                c['children'] = build_tree(c['id'])
            return children
            
        return jsonify({
            "content": build_tree(None), 
            "settings": sets, 
            "last_modified": sets.get('tree_last_modified', 0)
        })

@app.route('/api/tree', methods=['POST'])
def update_tree():
    items = request.json
    with get_db() as conn:
        update_data = [(item.get('parent_id'), item.get('sort_order'), item['id']) for item in items]
        conn.executemany("UPDATE notes SET parent_id=?, sort_order=? WHERE id=?", update_data)
    return jsonify({"status": "success"})

@app.route('/api/notes/<note_id>', methods=['GET'])
def get_note(note_id):
    with get_db() as conn:
        row = conn.execute("SELECT id, title, text, reminder FROM notes WHERE id=?", (note_id,)).fetchone()
        if row: 
            return jsonify(dict(row))
        return jsonify({"error": "Not found"}), 404

@app.route('/api/notes', methods=['POST'])
def create_note():
    data = request.json
    with get_db() as conn:
        conn.execute('''
            INSERT INTO notes (id, parent_id, sort_order, title, text) 
            VALUES (?, ?, ?, ?, ?)
        ''', (data['id'], data.get('parent_id'), data.get('sort_order', 999), data.get('title', 'Neu'), data.get('text', '')))
    return jsonify({"status": "success", "id": data['id']})

@app.route('/api/notes/<note_id>', methods=['PUT'])
def update_note(note_id):
    data = request.json
    with get_db() as conn:
        conn.execute('''
            UPDATE notes SET title=?, text=?, reminder=? WHERE id=?
        ''', (data.get('title'), data.get('text'), data.get('reminder'), note_id))
    return jsonify({"status": "success"})

@app.route('/api/notes/<note_id>', methods=['DELETE'])
def delete_note(note_id):
    with get_db() as conn:
        def delete_recursive(nid):
            children = conn.execute("SELECT id FROM notes WHERE parent_id=?", (nid,)).fetchall()
            for c in children: 
                delete_recursive(c['id'])
            conn.execute("DELETE FROM notes WHERE id=?", (nid,))
            
        delete_recursive(note_id)
    return jsonify({"status": "success"})

@app.route('/api/settings', methods=['POST'])
def update_settings():
    data = request.json
    with get_db() as conn:
        for k, v in data.items():
            if k == 'password':
                conn.execute("REPLACE INTO settings (key, value) VALUES ('password_hash', ?)", (generate_password_hash(v),))
                continue
            
            val_str = str(v).lower() if isinstance(v, bool) else str(v)
            conn.execute("REPLACE INTO settings (key, value) VALUES (?, ?)", (k, val_str))
    return jsonify({"status": "success"})

@app.route('/api/lock/<note_id>', methods=['POST'])
def handle_lock(note_id):
    req = request.json
    cid = req.get('client_id')
    action = req.get('action')
    now = time.time()
    
    with get_db() as conn:
        row = conn.execute("SELECT locked_by, locked_at FROM notes WHERE id=?", (note_id,)).fetchone()
        if not row: 
            return jsonify({"error": "Note not found"}), 404
            
        c_owner = row['locked_by']
        lock_time = row['locked_at'] or 0
        is_locked = c_owner and (now - lock_time) < 30
        
        if action == 'release':
            if c_owner == cid or not is_locked: 
                conn.execute("UPDATE notes SET locked_by=NULL, locked_at=NULL WHERE id=?", (note_id,))
            return jsonify({"status": "released"})
            
        elif action in ['acquire', 'override', 'heartbeat']:
            if action == 'override' or not is_locked or c_owner == cid:
                conn.execute("UPDATE notes SET locked_by=?, locked_at=? WHERE id=?", (cid, now, note_id))
                return jsonify({"status": "acquired"})
            else: 
                return jsonify({"status": "locked"})
                
    return jsonify({"error": "invalid action"}), 400

@app.route('/uploads/<filename>')
def uploaded_file(filename): 
    return send_from_directory(UPLOAD_FOLDER, filename)

@app.route('/api/upload', methods=['POST'])
def upload_file():
    file = request.files.get('file') or request.files.get('image')
    if file:
        ext = file.filename.rsplit('.', 1)[1].lower()
        filename = f"{uuid.uuid4().hex}.{ext}"
        file.save(os.path.join(UPLOAD_FOLDER, filename))
        return jsonify({"filename": filename, "original": file.filename})
    return jsonify({"error": "error"}), 400

@app.route('/api/sketch', methods=['POST'])
def save_sketch():
    data = request.json
    sid = data.get('id') or uuid.uuid4().hex
    
    with open(os.path.join(UPLOAD_FOLDER, f"sketch_{sid}.png"), "wb") as f:
        f.write(base64.b64decode(data['image'].split(',')[1]))
        
    with open(os.path.join(UPLOAD_FOLDER, f"sketch_{sid}.json"), "w") as f:
        json.dump({"bg": data['bg'], "strokes": data['strokes']}, f)
        
    return jsonify({"id": sid})

@app.route('/api/sketch/<sid>', methods=['GET'])
def load_sketch(sid):
    p = os.path.join(UPLOAD_FOLDER, f"sketch_{sid}.json")
    if os.path.exists(p):
        with open(p, 'r') as f: 
            return jsonify(json.load(f))
    return jsonify({"error": "404"}), 404

@app.route('/api/export', methods=['GET'])
def export_backup():
    mem = io.BytesIO()
    b_path = DB_FILE + '.backup'
    
    try:
        with sqlite3.connect(DB_FILE) as src, sqlite3.connect(b_path) as dst: 
            src.backup(dst)
            
        with tarfile.open(fileobj=mem, mode='w:gz') as tar:
            tar.add(b_path, arcname='data.db')
            if os.path.exists(UPLOAD_FOLDER): 
                tar.add(UPLOAD_FOLDER, arcname='uploads')
    finally:
        if os.path.exists(b_path): 
            os.remove(b_path)
            
    mem.seek(0)
    filename = f'notes_backup_{datetime.now().strftime("%Y%m%d_%H%M")}.tar.gz'
    return send_file(mem, download_name=filename, as_attachment=True)

@app.route('/api/backups', methods=['GET'])
def list_backups():
    backups = []
    if os.path.exists(BACKUP_FOLDER):
        for f in os.listdir(BACKUP_FOLDER):
            if f.endswith('.tar.gz'):
                p = os.path.join(BACKUP_FOLDER, f)
                st = os.stat(p)
                dt = datetime.fromtimestamp(st.st_mtime).strftime('%d.%m.%Y %H:%M:%S')
                backups.append({
                    "filename": f, 
                    "date": dt, 
                    "ts": st.st_mtime, 
                    "size": round(st.st_size / 1024 / 1024, 2)
                })
    
    backups.sort(key=lambda x: x['ts'], reverse=True)
    return jsonify(backups)

@app.route('/api/restore', methods=['POST'])
def restore_backup():
    file = request.files.get('file')
    server_file = request.form.get('server_file')
    
    tar_path = None
    if file:
        fd, tar_path = tempfile.mkstemp(suffix='.tar.gz')
        os.close(fd)
        file.save(tar_path)
    elif server_file:
        tar_path = os.path.join(BACKUP_FOLDER, server_file)
        if not os.path.exists(tar_path):
            return jsonify({"error": "Serverseitiges Backup nicht gefunden"}), 404
    else:
        return jsonify({"error": "Keine Backup-Datei angegeben"}), 400

    try:
        with tempfile.TemporaryDirectory() as tmpdir:
            try:
                with tarfile.open(tar_path, 'r:gz') as tar:
                    tar.extractall(path=tmpdir)
            except Exception as e:
                return jsonify({"error": "Datei ist kein gültiges tar.gz Archiv"}), 400
            
            db_path = os.path.join(tmpdir, 'data.db')
            if not os.path.exists(db_path):
                return jsonify({"error": "Das Archiv enthält keine data.db"}), 400
            
            try:
                conn = sqlite3.connect(db_path)
                cursor = conn.cursor()
                cursor.execute("PRAGMA integrity_check;")
                res = cursor.fetchone()
                conn.close()
                
                if res[0] != "ok":
                    return jsonify({"error": "Die Datenbank im Backup ist korrupt (Integrity Check fehlgeschlagen)"}), 400
            except Exception as e:
                return jsonify({"error": f"Datenbank-Prüfung fehlgeschlagen: {str(e)}"}), 400
            
            if os.path.exists(DB_FILE):
                shutil.copy2(DB_FILE, DB_FILE + '.pre-restore')
            
            # WICHTIGER FIX: WAL und SHM löschen, sonst zerschießt SQLite das Backup beim Lesen!
            for ext in ['-wal', '-shm']:
                if os.path.exists(DB_FILE + ext):
                    try:
                        os.remove(DB_FILE + ext)
                    except Exception:
                        pass
            
            shutil.copy2(db_path, DB_FILE)
            
            uploads_ext = os.path.join(tmpdir, 'uploads')
            if os.path.exists(uploads_ext):
                if os.path.exists(UPLOAD_FOLDER):
                    shutil.rmtree(UPLOAD_FOLDER)
                shutil.copytree(uploads_ext, UPLOAD_FOLDER)
            elif not os.path.exists(UPLOAD_FOLDER):
                os.makedirs(UPLOAD_FOLDER)

        return jsonify({"status": "success"})
        
    except Exception as e:
        return jsonify({"error": str(e)}), 500
        
    finally:
        if file and tar_path and os.path.exists(tar_path):
            os.remove(tar_path)

if __name__ == '__main__':
    pass
EOF

echo "app.run(host='0.0.0.0', port=$USER_PORT, debug=False)" >> $INSTALL_DIR/app.py

# cleanup.py 
cat << 'EOF' > $INSTALL_DIR/cleanup.py
import sqlite3
import os

DB = '/opt/notiz-tool/data.db'
UPL = '/opt/notiz-tool/uploads'

if not os.path.exists(DB) or not os.path.exists(UPL): 
    exit()

used_files = set()
conn = sqlite3.connect(DB)
rows = conn.execute("SELECT text FROM notes WHERE text IS NOT NULL").fetchall()

for r in rows:
    text = r[0]
    for f in os.listdir(UPL):
        if f in text: 
            used_files.add(f)
            
        if f.startswith('sketch_') and f.endswith('.png'):
            sid = f.replace('sketch_', '').replace('.png', '')
            if f"[sketch:{sid}]" in text:
                used_files.add(f)
                used_files.add(f"sketch_{sid}.json")
                
for f in os.listdir(UPL):
    if f not in used_files:
        try: 
            os.remove(os.path.join(UPL, f))
        except: 
            pass
EOF

# backup.sh 
cat << 'EOF' > $INSTALL_DIR/backup.sh
#!/bin/bash
cd /opt/notiz-tool
if [ -f data.db ]; then
    sqlite3 data.db ".backup 'data.db.backup'"
    tar -czf backups/backup_$(date +%u).tar.gz data.db.backup uploads/
    rm data.db.backup
fi
EOF

# templates/index.html 
cat << 'EOF' > $INSTALL_DIR/templates/index.html
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width,initial-scale=1.0">
    <title>Notes V2</title>
    <link rel="stylesheet" href="/static/style.css?v={{ v }}">
    <script src="https://cdn.jsdelivr.net/npm/sortablejs@1.15.0/Sortable.min.js"></script>
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/tomorrow-night-blue.min.css">
    <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
</head>
<body data-theme="dark">
    <div class="header-actions">
        <div class="dropdown">
            <button onclick="toggleSettings(event)" style="font-size:1.4em">⚙️</button>
            <div class="dropdown-content" id="dropdown-menu">
                <div class="menu-row" onclick="toggleTheme()"><span>🌓 Theme wechseln</span></div>
                <div class="menu-row">
                    <span>🎨 Akzentfarbe</span>
                    <input type="color" id="accent-color-picker" onchange="updateGlobalAccent(this.value)" onclick="event.stopPropagation()">
                </div>
                <div class="menu-row" onclick="exportData()"><span>📥 DB-Backup herunterladen</span></div>
                <div class="menu-row" onclick="openRestoreModal()"><span>🔄 Backup Wiederherstellen</span></div>
                <div class="menu-row" onclick="togglePassword()"><span id="pwd-toggle-text">🔒 Passwortschutz an</span></div>
                <div class="menu-row" onclick="toggleWebhookModal()"><span id="webhook-toggle-text">🔔 Webhook (Push)</span></div>
                <div class="menu-row" id="logout-btn" style="display:none; color:#e74c3c;" onclick="window.location.href='/logout'"><span>🚪 Abmelden</span></div>
            </div>
        </div>
    </div>
    
    <button id="mobile-toggle-btn" onclick="toggleSidebar()"><span>◀</span></button>
    
    <div id="sidebar">
        <div class="sidebar-header">
            <h3 style="margin:0">Notizen</h3>
            <div style="display:flex; gap:8px;">
                <button id="toggle-all-btn" onclick="toggleAllFolders()" title="Alle auf/zu">↔️</button>
                <button id="sort-btn" onclick="confirmAutoSort()" title="Automatisch sortieren">⇅</button>
                <button onclick="toggleEditMode()" title="Struktur Bearbeiten">✏️</button>
            </div>
        </div>
        <div style="padding:15px; flex-shrink: 0;">
            <div class="search-wrapper">
                <input type="text" id="search-input" placeholder="Suchen..." oninput="filterTree()">
                <span id="clear-search" onclick="clearSearch()">✕</span>
            </div>
            <button onclick="addItem(null)" style="width:100%;background:var(--accent) !important;color:white;padding:8px;border-radius:4px;font-weight:bold;">+ Hauptkategorie</button>
        </div>
        <div id="tree"></div>
    </div>
    
    <div id="editor">
        <div id="no-selection" style="margin-top:50px;text-align:center;opacity:0.5">Wähle eine Notiz aus.</div>
        <div id="edit-area" style="display:none">
            <div id="breadcrumb" style="font-size:0.8em;color:var(--accent);margin-bottom:15px;overflow-wrap:anywhere;word-break:break-word;"></div>
            
            <div id="view-mode">
                <div style="display:flex; align-items:center; gap:12px; margin-bottom:20px; flex-wrap:wrap;">
                    <h1 id="view-title" style="margin:0; overflow-wrap:anywhere; word-break:break-word; max-width:100%;"></h1>
                    <span id="view-reminder-badge" style="display:none; color:#e74c3c; font-size:1.2em; animation: pulse 2s infinite;" title="Erinnerung aktiv!">⏰</span>
                    <button id="view-reminder-ack" onclick="clearReminder()" style="display:none; background:#e74c3c !important; color:white; padding:4px 8px; border-radius:4px; font-size:0.8em; font-weight:bold;">Bestätigen</button>
                    <button onclick="enableEdit()" style="font-size:1.2em; margin-left:auto;">✏️</button>
                </div>
                <div id="display-area"></div>
            </div>
            
            <div id="edit-mode" style="display:none">
                <div id="mention-dropdown"></div>

                <div class="toolbar">
                    <button class="tool-btn" onclick="saveChanges();" style="background:var(--accent) !important; color:white;"><i>💾</i><span>OK</span></button>
                    <button class="tool-btn" onclick="cancelEdit()" style="color:#e74c3c;"><i>❌</i><span>Abbruch</span></button>
                    <button class="tool-btn" onclick="wrapSelection('**','**', 'Fett')"><i><b>B</b></i><span>Fett</span></button>
                    <button class="tool-btn" onclick="wrapSelection('_','_', 'Kursiv')"><i style="font-style:italic; font-family:serif;">I</i><span>Kursiv</span></button>
                    <button class="tool-btn" onclick="wrapSelection('~~','~~', 'Text')"><i style="text-decoration:line-through;">S</i><span>Streich</span></button>
                    <button class="tool-btn" onclick="wrapSelection('### ','', 'Überschrift')"><i style="font-weight:bold;">H</i><span>Titel</span></button>
                    <button class="tool-btn" onclick="handleListAction('- ', 'Punkt')"><i style="font-weight:bold;">•—</i><span>Liste</span></button>
                    <button class="tool-btn" onclick="handleListAction('- [ ] ', 'Aufgabe')"><i>☑</i><span>To-Do</span></button>
                    <button class="tool-btn" onclick="wrapSelection('> ','', 'Zitat')"><i style="font-family:serif;">"</i><span>Zitat</span></button>
                    <button class="tool-btn" onclick="wrapSelection('[s=Spoiler-Titel]\n','\n[/s]', 'Text hier...')"><i>👁️‍🗨️</i><span>Spoiler</span></button>
                    <button class="tool-btn" onclick="wrapSelection('\n---\n','', '')"><i>—</i><span>Linie</span></button>
                    <button class="tool-btn" onclick="insertCodeTag()"><i>💻</i><span>Code</span></button>
                    <button class="tool-btn" onclick="uploadImage()"><i>🖼️</i><span>Bild</span></button>
                    <button class="tool-btn" onclick="uploadGenericFile()"><i>📎</i><span>Datei</span></button>
                    <button class="tool-btn" onclick="openSketch()"><i>🖌️</i><span>Skizze</span></button>
                    <button class="tool-btn" onclick="triggerMentionButton()"><i>@</i><span>Verweis</span></button>
                    <button class="tool-btn" onclick="wrapSelection('[','](https://)', 'Link-Text')"><i>🔗</i><span>Web-Link</span></button>
                    <div class="tool-btn color-tool">
                        <div class="color-row">
                            <span onclick="applyColor()">🎨</span>
                            <input type="color" id="text-color-input" value="#27ae60">
                        </div>
                        <span>Farbe</span>
                    </div>
                </div>

                <div style="display:flex; gap:10px; margin-bottom:10px; align-items:stretch;">
                    <input type="text" id="node-title" placeholder="Titel" style="margin-bottom:0; flex-grow:1;">
                    <button class="tool-btn" onclick="openReminderModal()" style="margin:0; min-height:100%; flex-direction:row; gap:5px; padding:0 10px; width:auto;">
                        <i>⏰</i><span id="edit-reminder-text">Erinnerung</span>
                    </button>
                    <button class="tool-btn" id="edit-reminder-clear" onclick="clearReminder()" style="display:none; margin:0; min-height:100%; flex-direction:row; gap:5px; padding:0 10px; width:auto; color:#e74c3c; border-color:#e74c3c;">
                        <i>✖</i><span>Löschen</span>
                    </button>
                </div>

                <textarea id="node-text" placeholder="Text oder Bild hier ablegen..." style="height:60vh"></textarea>
            </div>
            
            <button onclick="addItem(activeId)" style="margin-top:20px;border:1px solid var(--accent) !important;color:var(--accent);padding:5px 10px;border-radius:4px;">+ Unter-Ebene</button>
        </div>
    </div>
    
    <div id="restore-modal" class="modal-overlay">
        <div class="modal" style="width: 500px; max-width: 95vw;">
            <h3 style="margin-top:0">Backup Wiederherstellen</h3>
            <div style="text-align: left; margin-bottom: 15px;">
                <p style="font-size: 0.9em; color: #ccc;">Wähle ein automatisches Server-Backup:</p>
                <select id="server-backups" style="width: 100%; padding: 10px; margin-bottom: 15px; background: rgba(255,255,255,0.05); color: inherit; border: 1px solid var(--border-color); border-radius: 4px;">
                    <option value="">-- Lade Backups... --</option>
                </select>
                
                <p style="font-size: 0.9em; color: #ccc;">Oder lade eine Backup-Datei (.tar.gz) hoch:</p>
                <input type="file" id="restore-file-upload" accept=".tar.gz,.gz" style="width: 100%; padding: 10px; background: rgba(255,255,255,0.05); border: 1px dashed var(--accent); border-radius: 4px; box-sizing: border-box;">
            </div>
            
            <div id="restore-status" style="font-size: 0.9em; margin-bottom: 15px; display: none; padding: 10px; border-radius: 4px; background: rgba(0,0,0,0.2);"></div>
            
            <div class="modal-btns">
                <button class="btn-cancel" onclick="document.getElementById('restore-modal').style.display='none'">Abbruch</button>
                <button class="btn-save" id="btn-do-restore" onclick="executeRestore()">Verifizieren & Wiederherstellen</button>
            </div>
        </div>
    </div>

    <div id="sketch-modal" class="modal-overlay">
        <div class="modal" style="width: 1000px; max-width: 95vw;">
            <h3 style="margin-top:0">Skizzenblock</h3>
            <div id="sketch-toolbar">
                <div class="sketch-tool">
                    <span>Hintergrund:</span>
                    <select id="sketch-bg-select" onchange="setSketchBg(this.value)" style="padding:5px; border-radius:4px;">
                        <option value="white">Weiß</option>
                        <option value="black">Schwarz</option>
                    </select>
                </div>
                <div class="sketch-tool">
                    <span>Farbe:</span>
                    <input type="color" onchange="sketchColor=this.value" value="#000000">
                </div>
                <div class="sketch-tool">
                    <span>Dicke:</span>
                    <input type="range" min="1" max="50" value="8" onchange="sketchWidth=this.value" style="width: 80px;">
                </div>
                <button id="btn-pen" class="sketch-btn active" onclick="setSketchMode('pen')">✏️ Stift</button>
                <button id="btn-highlighter" class="sketch-btn" onclick="setSketchMode('highlighter')">🖍️ Marker</button>
                <button id="btn-eraser" class="sketch-btn" onclick="setSketchMode('eraser')">🧽 Radierer</button>
                <button class="sketch-btn" onclick="undoSketch()" style="color:#f39c12;">↩️ Zurück</button>
                <button class="sketch-btn" onclick="sketchStrokes=[]; redrawSketch();" style="color:#e74c3c;">🗑️ Leeren</button>
                <div style="flex-grow:1; text-align:right;">
                    <button class="btn-cancel" onclick="closeSketch()">Abbruch</button>
                    <button class="btn-save" onclick="saveSketch()">Speichern</button>
                </div>
            </div>
            <div id="canvas-wrapper">
                <canvas id="sketch-canvas"></canvas>
            </div>
        </div>
    </div>

    <div id="reminder-modal" class="modal-overlay">
        <div class="modal">
            <h3 style="margin-top:0">Erinnerung setzen</h3>
            <div style="margin-bottom:15px; text-align:left;">
                <label style="display:block; margin-bottom:10px; cursor:pointer;">
                    <input type="checkbox" id="reminder-has-time" onchange="toggleReminderInput()"> Mit fester Uhrzeit
                </label>
                <input type="date" id="reminder-date" style="display:block; width:100%;">
                <input type="datetime-local" id="reminder-datetime" style="display:none; width:100%;">
            </div>
            <div class="modal-btns">
                <button class="btn-cancel" onclick="document.getElementById('reminder-modal').style.display='none'">Abbruch</button>
                <button class="btn-save" onclick="saveReminder()">Speichern</button>
            </div>
        </div>
    </div>

    <div id="webhook-modal" class="modal-overlay">
        <div class="modal" style="max-width: 500px;">
            <h3 style="margin-top:0">Webhook Push-Benachrichtigungen</h3>
            <div style="text-align:left; margin-bottom: 15px;">
                <label style="display:block; margin-bottom:10px; cursor:pointer;">
                    <input type="checkbox" id="webhook-enabled"> Webhooks aktivieren
                </label>
                <label style="display:block; margin-bottom:5px; font-size:0.9em;">HTTP Methode:</label>
                <select id="webhook-method" onchange="toggleWebhookPayload()" style="width:100%; padding:10px; margin-bottom:10px; background:rgba(255,255,255,0.05); color:inherit; border:1px solid var(--border-color); border-radius:4px;">
                    <option value="GET">GET (z.B. ntfy.sh)</option>
                    <option value="POST">POST (z.B. Discord)</option>
                </select>
                <label style="display:block; margin-bottom:5px; font-size:0.9em;">Ziel-URL:</label>
                <input type="text" id="webhook-url" placeholder="https://..." style="margin-bottom:10px;">
                <div id="webhook-payload-container" style="display:none;">
                    <label style="display:block; margin-bottom:5px; font-size:0.9em;">JSON Payload:</label>
                    <textarea id="webhook-payload" rows="4" placeholder='{"text": "Erinnerung: {{TITLE}} ist fällig!"}' style="font-family:monospace; font-size:0.9em;"></textarea>
                </div>
            </div>
            <div class="modal-btns">
                <button class="btn-cancel" onclick="document.getElementById('webhook-modal').style.display='none'">Abbruch</button>
                <button class="btn-save" onclick="saveWebhook()">Speichern</button>
            </div>
        </div>
    </div>

    <div id="custom-modal" class="modal-overlay">
        <div class="modal">
            <h3 id="modal-title"></h3>
            <p id="modal-text" style="white-space: pre-wrap;"></p>
            <input type="password" id="modal-input" style="display:none; margin-top: 15px; width: 100%; box-sizing: border-box;" placeholder="Passwort...">
            <div class="modal-btns" id="modal-btns-container"></div>
        </div>
    </div>
    
    <div id="lightbox" onclick="closeLightbox()">
        <img id="lightbox-img" src="">
    </div>
    
    <script src="/static/script.js?v={{ v }}"></script>
</body>
</html>
EOF

# static/script.js (UNMINIFIED UND KOMPLETT EXPANDIERT)
cat << 'EOF' > $INSTALL_DIR/static/script.js
var fullTree = {
    content: [], 
    settings: {}
};
var activeId = null;
var activeNoteData = null; 
var collapsedIds = new Set();
var sortables = [];
var currentTreeLastMod = 0;

let myClientId = sessionStorage.getItem('clientId');
if (!myClientId) {
    myClientId = 'client_' + Math.random().toString(36).substring(2, 10);
    sessionStorage.setItem('clientId', myClientId);
}

let lockInterval = null;
let currentLockedNote = null;

async function acquireLock(noteId, override = false) {
    try {
        const res = await fetch(`/api/lock/${noteId}`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                client_id: myClientId, 
                action: override ? 'override' : 'acquire'
            })
        });
        
        const data = await res.json();
        
        if (data.status === 'acquired') {
            currentLockedNote = noteId;
            startHeartbeat(noteId);
            return true;
        }
    } catch(e) { 
        console.error(e); 
    }
    
    return false;
}

async function releaseLock() {
    if (!currentLockedNote) {
        return;
    }
    
    let nidToRelease = currentLockedNote;
    currentLockedNote = null; 
    
    if (lockInterval) { 
        clearInterval(lockInterval); 
        lockInterval = null; 
    }
    
    try {
        await fetch(`/api/lock/${nidToRelease}`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                client_id: myClientId, 
                action: 'release'
            })
        });
    } catch(e) {
        console.error(e);
    }
}

function startHeartbeat(noteId) {
    if (lockInterval) {
        clearInterval(lockInterval);
    }
    
    lockInterval = setInterval(async () => {
        try {
            const res = await fetch(`/api/lock/${noteId}`, {
                method: 'POST', 
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({
                    client_id: myClientId, 
                    action: 'heartbeat'
                })
            });
            
            const data = await res.json();
            
            if (data.status === 'lost') {
                if (lockInterval) {
                    clearInterval(lockInterval);
                }
                
                lockInterval = null;
                currentLockedNote = null;
                
                showModal("Sperre verloren!", "Ein anderes Gerät hat die Bearbeitung erzwungen.", [
                    {
                        label: "Verstanden", 
                        class: "btn-cancel", 
                        action: () => { 
                            disableEdit(); 
                            if(document.getElementById('sketch-modal').style.display === 'flex') {
                                closeSketch();
                            }
                        }
                    }
                ]);
            }
        } catch(e) { 
            console.error(e); 
        }
    }, 5000); 
}

window.addEventListener('beforeunload', () => {
    if (currentLockedNote) {
        const blob = new Blob([JSON.stringify({
            client_id: myClientId, 
            action: 'release'
        })], {
            type: 'application/json'
        });
        navigator.sendBeacon(`/api/lock/${currentLockedNote}`, blob);
    }
});

async function checkAndReloadData() {
    try {
        const res = await fetch('/api/tree?_t=' + Date.now());
        
        if (!res.ok) {
            return;
        }
        
        const data = await res.json();
        
        if (data.last_modified && data.last_modified > currentTreeLastMod) {
            currentTreeLastMod = data.last_modified;
            fullTree.content = cleanDataArray(data.content || []);
            fullTree.settings = data.settings || {};
            
            document.body.setAttribute('data-theme', fullTree.settings.theme || 'dark'); 
            applyAccentColor(fullTree.settings.accent || '#27ae60');
            updateMenuUI();
            
            if (!document.body.classList.contains('edit-mode-active')) {
                renderTree();
            }
        }
    } catch (e) { 
        console.error("Sync error:", e); 
    }
}

async function fetchNoteData(id) {
    try {
        const res = await fetch(`/api/notes/${id}?_t=` + Date.now());
        
        if(res.ok) {
            return await res.json();
        }
    } catch(e) { 
        console.error("Fehler beim Laden der Notiz:", e); 
    }
    
    return null;
}

function cleanDataArray(arr) {
    if (!arr) {
        return [];
    }
    
    return arr.map(item => {
        return {
            ...item, 
            children: cleanDataArray(item.children)
        };
    });
}

async function loadData() { 
    const sState = localStorage.getItem('sidebarState') || 'closed'; 
    
    if (sState === 'closed') {
        document.body.classList.add('sidebar-hidden'); 
    }
    
    const savedCollapsed = localStorage.getItem('collapsedNodes');
    
    if (savedCollapsed) {
        collapsedIds = new Set(JSON.parse(savedCollapsed));
    }
    
    await checkAndReloadData();
    
    if (!savedCollapsed && fullTree.content.length > 0) {
        initAllCollapsed(fullTree.content);
    }
    
    renderTree(); 
    
    const lastId = localStorage.getItem('lastActiveId'); 
    
    if (lastId && findNode(fullTree.content, lastId)) {
        selectNode(lastId); 
    }
}

function initAllCollapsed(items) { 
    items.forEach(item => { 
        if (item.children && item.children.length > 0) { 
            collapsedIds.add(item.id); 
            initAllCollapsed(item.children); 
        } 
    }); 
    
    saveCollapsedToLocal(); 
}

function saveCollapsedToLocal() { 
    localStorage.setItem('collapsedNodes', JSON.stringify(Array.from(collapsedIds))); 
}

async function enableEdit() { 
    if (!activeId) {
        return;
    }
    
    activeNoteData = await fetchNoteData(activeId);
    
    if (!activeNoteData) { 
        alert("Notiz nicht gefunden!"); 
        return; 
    }
    
    const locked = await acquireLock(activeId);
    
    if (!locked) {
        showModal("System gesperrt", "Diese Notiz wird gerade auf einem anderen Gerät bearbeitet.\n\nSperre erzwingen?", [
            { 
                label: "Ja, erzwingen", 
                class: "btn-discard", 
                action: async () => { 
                    await acquireLock(activeId, true); 
                    showEditArea(); 
                }
            },
            { 
                label: "Abbrechen", 
                class: "btn-cancel", 
                action: () => {} 
            }
        ]);
        return;
    }
    
    showEditArea();
}

function showEditArea() {
    document.getElementById('node-title').value = activeNoteData.title || '';
    document.getElementById('node-text').value = activeNoteData.text || '';
    
    const editRemBtnText = document.getElementById('edit-reminder-text');
    const editRemClearBtn = document.getElementById('edit-reminder-clear');
    
    if (activeNoteData.reminder) { 
        editRemBtnText.innerText = activeNoteData.reminder.replace('T', ' '); 
        editRemClearBtn.style.display = 'flex'; 
    } else { 
        editRemBtnText.innerText = 'Erinnerung'; 
        editRemClearBtn.style.display = 'none'; 
    }
    
    document.getElementById('view-mode').style.display = 'none'; 
    document.getElementById('edit-mode').style.display = 'block'; 
}

async function saveChanges() { 
    if (!activeId || !activeNoteData) {
        return;
    }
    
    activeNoteData.title = document.getElementById('node-title').value; 
    activeNoteData.text = document.getElementById('node-text').value; 
    
    await fetch(`/api/notes/${activeId}`, { 
        method: 'PUT', 
        headers: {
            'Content-Type': 'application/json'
        }, 
        body: JSON.stringify(activeNoteData) 
    });
    
    await releaseLock();
    await checkAndReloadData(); 
    
    renderDisplayArea();
}

function cancelEdit() { 
    releaseLock(); 
    renderDisplayArea(); 
}

function renderDisplayArea() {
    if (!activeNoteData) {
        return;
    }
    
    document.getElementById('view-title').innerText = activeNoteData.title; 
    document.getElementById('display-area').innerHTML = renderMarkdown(activeNoteData.text); 
    
    if(window.hljs) {
        hljs.highlightAll(); 
    }
    
    const viewBadge = document.getElementById('view-reminder-badge');
    const viewAck = document.getElementById('view-reminder-ack');
    
    if (isReminderActive(activeNoteData)) { 
        viewBadge.style.display = 'inline-block'; 
        viewAck.style.display = 'inline-block'; 
    } else { 
        viewBadge.style.display = 'none'; 
        viewAck.style.display = 'none'; 
    }
    
    document.getElementById('view-mode').style.display = 'block'; 
    document.getElementById('edit-mode').style.display = 'none'; 
}

async function selectNode(id) { 
    if (document.getElementById('edit-mode').style.display === 'block') {
        if (activeNoteData && (document.getElementById('node-title').value !== activeNoteData.title || document.getElementById('node-text').value !== activeNoteData.text)) { 
            showModal("Ungespeichert", "Speichern?", [ 
                { 
                    label: "Ja", 
                    class: "btn-save", 
                    action: async () => { 
                        await saveChanges(); 
                        doSelectNode(id); 
                    } 
                }, 
                { 
                    label: "Nein", 
                    class: "btn-discard", 
                    action: () => { 
                        cancelEdit(); 
                        doSelectNode(id); 
                    } 
                }, 
                { 
                    label: "Abbruch", 
                    class: "btn-cancel", 
                    action: () => {} 
                } 
            ]); 
            return; 
        } 
    }
    
    doSelectNode(id);
}

async function doSelectNode(id) {
    activeId = id; 
    localStorage.setItem('lastActiveId', id); 
    
    activeNoteData = await fetchNoteData(id);
    
    if (!activeNoteData) {
        return;
    }
    
    document.getElementById('no-selection').style.display = 'none'; 
    document.getElementById('edit-area').style.display = 'block'; 
    
    const pathData = getPath(fullTree.content, id) || []; 
    const breadcrumbEl = document.getElementById('breadcrumb'); 
    
    breadcrumbEl.innerHTML = '';
    
    pathData.forEach((p, idx) => { 
        const span = document.createElement('span'); 
        span.innerText = p.title; 
        span.style.cursor = 'pointer'; 
        
        span.onclick = () => {
            selectNode(p.id);
        }; 
        
        span.onmouseover = () => {
            span.style.textDecoration = 'underline';
        }; 
        
        span.onmouseout = () => {
            span.style.textDecoration = 'none';
        }; 
        
        breadcrumbEl.appendChild(span); 
        
        if(idx < pathData.length - 1) {
            breadcrumbEl.appendChild(document.createTextNode(' / ')); 
        }
    });
    
    renderDisplayArea();
    
    document.querySelectorAll('.tree-item').forEach(el => {
        el.classList.remove('active');
    }); 
    
    const activeEl = document.querySelector(`.tree-item-container[data-id="${id}"] > .tree-item`); 
    
    if(activeEl) {
        activeEl.classList.add('active'); 
    }
}

function toggleEditMode() { 
    if (!document.body.classList.contains('edit-mode-active')) { 
        document.body.classList.add('edit-mode-active'); 
        renderTree(); 
    } else { 
        document.body.classList.remove('edit-mode-active'); 
        
        sortables.forEach(s => {
            s.destroy();
        }); 
        
        sortables = []; 
        renderTree(); 
    }
}

async function rebuildDataFromDOM() { 
    if (!document.body.classList.contains('edit-mode-active')) {
        return;
    }
    
    let flatUpdates = [];
    
    function parse(container, parentId) { 
        Array.from(container.querySelectorAll(':scope > .tree-item-container')).forEach((div, index) => { 
            const id = div.getAttribute('data-id'); 
            
            flatUpdates.push({ 
                id: id, 
                parent_id: parentId, 
                sort_order: index 
            });
            
            const sub = div.querySelector(':scope > .tree-group'); 
            
            if(sub) {
                parse(sub, id);
            }
        }); 
    } 
    
    const rg = document.querySelector('#tree > .tree-group'); 
    
    if(rg) { 
        parse(rg, null); 
        
        await fetch('/api/tree', { 
            method: 'POST', 
            headers: {
                'Content-Type': 'application/json'
            }, 
            body: JSON.stringify(flatUpdates) 
        }); 
        
        await checkAndReloadData(); 
    } 
}

window.toggleTask = async function(targetIdx, currentlyChecked) {
    if (!await acquireLock(activeId)) { 
        showModal("Gesperrt", "Checkbox kann nicht geändert werden (Notiz wird bearbeitet).", [
            { 
                label: "OK", 
                class: "btn-cancel", 
                action: () => {} 
            }
        ]); 
        renderDisplayArea(); 
        return; 
    }
    
    activeNoteData = await fetchNoteData(activeId);
    
    if(!activeNoteData) { 
        releaseLock(); 
        return; 
    }
    
    let tIndex = 0; 
    let lines = activeNoteData.text.split('\n');
    
    for (let i = 0; i < lines.length; i++) {
        let t = lines[i].trim();
        
        if (t.startsWith('- [ ] ') || t.startsWith('- [x] ') || t.startsWith('- [X] ')) {
            if (tIndex === targetIdx) { 
                if (currentlyChecked) {
                    lines[i] = lines[i].replace(/- \[[xX]\] /, '- [ ] ');
                } else {
                    lines[i] = lines[i].replace(/- \[ \] /, '- [x] ');
                }
                break; 
            } 
            
            tIndex++;
        }
    }
    
    activeNoteData.text = lines.join('\n'); 
    
    await fetch(`/api/notes/${activeId}`, { 
        method: 'PUT', 
        headers: {
            'Content-Type': 'application/json'
        }, 
        body: JSON.stringify(activeNoteData) 
    });
    
    await releaseLock(); 
    renderDisplayArea();
};

async function openSketch(id = null) {
    const isEdit = document.getElementById('edit-mode').style.display === 'block';
    
    if (!isEdit && !await acquireLock(activeId)) { 
        showModal("Gesperrt", "Skizze kann nicht geöffnet werden.", [
            { 
                label: "OK", 
                class: "btn-cancel", 
                action: () => {} 
            }
        ]); 
        return; 
    }

    document.getElementById('sketch-modal').style.display = 'flex';
    
    if(!sketchCanvas) {
        initSketcher();
    }
    
    activeSketchId = id; 
    sketchStrokes = [];
    
    if (id) { 
        try { 
            const res = await fetch(`/api/sketch/${id}`); 
            
            if(res.ok) { 
                const data = await res.json(); 
                sketchBg = data.bg || 'white'; 
                document.getElementById('sketch-bg-select').value = sketchBg; 
                sketchStrokes = data.strokes || []; 
            } 
        } catch(e) {
            console.error(e);
        } 
    } else { 
        sketchBg = document.getElementById('sketch-bg-select').value; 
    }
    
    setSketchMode('pen'); 
    redrawSketch();
}

function closeSketch() { 
    document.getElementById('sketch-modal').style.display = 'none'; 
    
    if (document.getElementById('edit-mode').style.display !== 'block') {
        releaseLock();
    }
}

async function saveSketch() {
    const payload = { 
        id: activeSketchId, 
        bg: sketchBg, 
        strokes: sketchStrokes, 
        image: sketchCanvas.toDataURL("image/png") 
    };
    
    const res = await fetch('/api/sketch', { 
        method: 'POST', 
        headers: {
            'Content-Type': 'application/json'
        }, 
        body: JSON.stringify(payload) 
    }); 
    
    const data = await res.json();
    
    if (!activeSketchId && data.id) {
        wrapSelection(`[sketch:${data.id}]`, '', '');
    }
    
    document.getElementById('sketch-modal').style.display = 'none';
    
    const ta = document.getElementById('node-text'); 
    
    if (ta) {
        ta.value = ta.value.replace(`[sketch:${data.id}]`, `[sketch:${data.id}] `).trim();
    }
    
    document.querySelectorAll('.sketch-img').forEach(img => { 
        if (img.src.includes(data.id)) {
            img.src = `/uploads/sketch_${data.id}.png?v=` + Date.now();
        }
    });

    if (document.getElementById('edit-mode').style.display !== 'block') {
        releaseLock();
    }
}

async function addItem(parentId) { 
    const newId = Date.now().toString() + Math.random().toString(36).substring(2, 6); 
    
    const payload = { 
        id: newId, 
        parent_id: parentId, 
        title: 'Neu', 
        text: '' 
    };
    
    await fetch('/api/notes', { 
        method: 'POST', 
        headers: {
            'Content-Type': 'application/json'
        }, 
        body: JSON.stringify(payload) 
    });
    
    if (parentId) { 
        collapsedIds.delete(parentId); 
        saveCollapsedToLocal(); 
    }
    
    await checkAndReloadData(); 
    selectNode(newId); 
    enableEdit(); 
}

function deleteItem(id) { 
    showModal("Löschen", "Sicher?", [ 
        { 
            label: "Löschen", 
            class: "btn-discard", 
            action: async () => { 
                await fetch(`/api/notes/${id}`, { 
                    method: 'DELETE' 
                }); 
                
                if (activeId === id) { 
                    activeId = null; 
                    document.getElementById('edit-area').style.display = 'none'; 
                } 
                
                await checkAndReloadData(); 
            } 
        }, 
        { 
            label: "Abbruch", 
            class: "btn-cancel", 
            action: () => {} 
        } 
    ]); 
}

function findNode(items, id) { 
    for (let i of items) { 
        if (i.id === id) {
            return i; 
        }
        
        if (i.children) { 
            const f = findNode(i.children, id); 
            
            if (f) {
                return f;
            } 
        } 
    } 
    
    return null; 
}

function getPath(items, id, path = []) { 
    for (let i of items) { 
        const n = [...path, {title: i.title, id: i.id}]; 
        
        if (i.id === id) {
            return n; 
        }
        
        if (i.children) { 
            const r = getPath(i.children, id, n); 
            
            if (r) {
                return r;
            } 
        } 
    } 
    
    return null; 
}

function applyAccentColor(hex) { 
    document.documentElement.style.setProperty('--accent', hex); 
    
    const r = parseInt(hex.slice(1,3), 16);
    const g = parseInt(hex.slice(3,5), 16);
    const b = parseInt(hex.slice(5,7), 16); 
    
    document.documentElement.style.setProperty('--accent-rgb', `${r}, ${g}, ${b}`); 
    
    const p = document.getElementById('accent-color-picker'); 
    
    if(p) {
        p.value = hex; 
    }
}

async function updateGlobalAccent(hex) { 
    await fetch('/api/settings', { 
        method: 'POST', 
        headers: {
            'Content-Type': 'application/json'
        }, 
        body: JSON.stringify({
            accent: hex
        })
    }); 
    
    fullTree.settings.accent = hex; 
    applyAccentColor(hex); 
}

async function toggleTheme() { 
    const newTheme = document.body.getAttribute('data-theme') === 'dark' ? 'light' : 'dark'; 
    
    await fetch('/api/settings', { 
        method: 'POST', 
        headers: {
            'Content-Type': 'application/json'
        }, 
        body: JSON.stringify({
            theme: newTheme
        })
    }); 
    
    fullTree.settings.theme = newTheme; 
    document.body.setAttribute('data-theme', newTheme); 
}

function updateMenuUI() {
    const pwdBtn = document.getElementById('pwd-toggle-text'); 
    const logoutBtn = document.getElementById('logout-btn'); 
    const whToggleText = document.getElementById('webhook-toggle-text');
    
    if(pwdBtn) {
        pwdBtn.innerText = fullTree.settings.password_enabled ? '🔓 Passwortschutz aus' : '🔒 Passwortschutz an';
    }
    
    if(logoutBtn) {
        logoutBtn.style.display = fullTree.settings.password_enabled ? 'flex' : 'none';
    }
    
    if(whToggleText) {
        whToggleText.innerText = fullTree.settings.webhook_enabled ? '🔔 Webhook (Aktiviert)' : '🔕 Webhook (Deaktiviert)';
    }
}

function renderTree() { 
    const container = document.getElementById('tree'); 
    container.innerHTML = ''; 
    
    const rootGroup = document.createElement('div'); 
    rootGroup.className = 'tree-group'; 
    container.appendChild(rootGroup); 
    
    renderItems(fullTree.content, rootGroup); 
    
    if (document.body.classList.contains('edit-mode-active')) {
        initSortables(); 
    }
}

function renderItems(items, parent) { 
    const isEdit = document.body.classList.contains('edit-mode-active'); 
    
    items.forEach(item => { 
        if (!item) {
            return;
        }
        
        const isFolder = item.children && item.children.length > 0; 
        const isCollapsed = isEdit ? false : collapsedIds.has(item.id); 
        
        const div = document.createElement('div'); 
        div.className = 'tree-item-container'; 
        div.setAttribute('data-id', item.id); 
        
        const wrapper = document.createElement('div'); 
        wrapper.className = 'tree-item' + (item.id === activeId ? ' active' : ''); 
        
        const handle = document.createElement('span'); 
        handle.className = 'drag-handle'; 
        handle.innerHTML = '⋮⋮';
        
        const icon = document.createElement('span'); 
        icon.className = 'tree-icon'; 
        
        if (isFolder) {
            icon.innerText = isCollapsed ? '📁' : '📂';
        } else {
            icon.innerText = '📄';
        }
        
        icon.onclick = (e) => { 
            e.stopPropagation(); 
            
            if (!isEdit && isFolder) { 
                if (collapsedIds.has(item.id)) {
                    collapsedIds.delete(item.id); 
                } else {
                    collapsedIds.add(item.id); 
                }
                
                saveCollapsedToLocal(); 
                renderTree(); 
            } 
        }; 
        
        const text = document.createElement('span'); 
        text.className = 'tree-text'; 
        text.innerText = item.title || 'Unbenannt'; 
        
        if (isReminderActive(item)) { 
            const rSpan = document.createElement('span'); 
            rSpan.className = 'reminder-icon'; 
            rSpan.innerText = '⏰'; 
            text.appendChild(rSpan); 
        }
        
        text.onclick = (e) => { 
            e.stopPropagation(); 
            
            if (!isEdit) {
                selectNode(item.id); 
            }
        }; 
        
        const addBtn = document.createElement('button'); 
        addBtn.className = 'add-sub-btn'; 
        addBtn.innerText = '+'; 
        
        addBtn.onclick = (e) => { 
            e.stopPropagation(); 
            addItem(item.id); 
        }; 
        
        const delBtn = document.createElement('button'); 
        delBtn.className = 'delete-btn'; 
        delBtn.innerText = '×'; 
        
        delBtn.onclick = (e) => { 
            e.stopPropagation(); 
            deleteItem(item.id); 
        }; 
        
        wrapper.append(handle, icon, text, addBtn, delBtn); 
        div.appendChild(wrapper); 
        
        const childGroup = document.createElement('div'); 
        childGroup.className = 'tree-group'; 
        
        if (isFolder && !isCollapsed) {
            renderItems(item.children, childGroup); 
        }
        
        div.appendChild(childGroup); 
        parent.appendChild(div); 
    }); 
}

function initSortables() { 
    sortables.forEach(s => {
        s.destroy();
    }); 
    
    sortables = []; 
    
    document.querySelectorAll('.tree-group').forEach(el => { 
        sortables.push(new Sortable(el, { 
            group: 'nested', 
            animation: 150, 
            handle: '.drag-handle', 
            fallbackOnBody: true, 
            onEnd: (evt) => { 
                if (evt.oldIndex !== evt.newIndex || evt.to !== evt.from) {
                    rebuildDataFromDOM(); 
                }
            } 
        })); 
    }); 
}

function renderMarkdown(text) { 
    if (!text) {
        return ''; 
    }
    
    let html = text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); 
    
    html = html.replace(/\[img:(.*?)\]/g, '<img src="/uploads/$1" class="note-img" onclick="openLightbox(this.src)">');
    html = html.replace(/\[sketch:([a-zA-Z0-9]+)\]/g, '<img src="/uploads/sketch_$1.png?v='+Date.now()+'" class="note-img sketch-img" title="Skizze bearbeiten" onclick="openSketch(\'$1\')">');
    html = html.replace(/\[file:([a-zA-Z0-9.\-]+)\|([^\]]+)\]/g, '<a href="/uploads/$1" target="_blank" class="note-link">📎 $2</a>');
    
    html = html.replace(/\[note:([a-zA-Z0-9]+)\|([^\]]+)\]/g, (match, id, title) => { 
        return '<a href="#" onclick="selectNode(\'' + id + '\'); return false;" class="note-link">@ ' + title + '</a>'; 
    });
    
    html = html.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer" style="color:var(--accent); text-decoration:underline;">$1</a>');
    
    html = html.replace(/\[s=(.*?)\]\n?([\s\S]*?)\n?\[\/s\]/g, '<details class="spoiler"><summary>$1</summary><div class="spoiler-content">$2</div></details>');

    let last = ""; 
    
    while (last !== html) { 
        last = html; 
        html = html.replace(/\[(#[0-9a-fA-F]{6})\]([\s\S]*?)\[\/#\]/g, '<span style="color:$1">$2</span>'); 
        html = html.replace(/\*\*(.*?)\*\*/g, '<b>$1</b>'); 
        html = html.replace(/_(.*?)_/g, '<i>$1</i>'); 
        html = html.replace(/~~(.*?)~~/g, '<s>$1</s>'); 
    } 
    
    let parts = html.split("'''"); 
    let res = ''; 
    window.taskIndexCounter = 0; 
    
    for (let i = 0; i < parts.length; i++) { 
        if (i % 2 === 1) { 
            let content = parts[i].trim(); 
            let lines = content.split('\n'); 
            let langClass = ''; 
            
            if (lines.length > 0 && lines[0].length < 15 && /^[a-z0-9]+$/.test(lines[0].trim())) { 
                langClass = ' class="language-' + lines[0].trim() + '"'; 
                content = lines.slice(1).join('\n'); 
            } 
            
            res += '<div class="code-container"><button class="copy-badge" onclick="copyToClipboard(this)">Copy</button><pre><code' + langClass + '>' + content + '</code></pre></div>'; 
        } else { 
            res += parts[i].split('\n').map(line => {
                let t = line.trim(); 
                
                if (t === '') {
                    return '<br>'; 
                }
                
                if (t === '---') {
                    return '<hr>';
                }
                
                if (t.startsWith('### ')) {
                    return '<h3>' + line.substring(4) + '</h3>'; 
                }
                
                if (t.startsWith('## ')) {
                    return '<h2>' + line.substring(3) + '</h2>'; 
                }
                
                if (t.startsWith('# ')) {
                    return '<h1>' + line.substring(2) + '</h1>';
                }
                
                if (t.startsWith('- [ ] ')) { 
                    let idx = window.taskIndexCounter++; 
                    return '<div class="task-list-item"><input type="checkbox" class="task-check" onclick="toggleTask(' + idx + ', false)"> <span>' + line.substring(line.indexOf('- [ ] ') + 6) + '</span></div>'; 
                }
                
                if (t.startsWith('- [x] ') || t.startsWith('- [X] ')) { 
                    let idx = window.taskIndexCounter++; 
                    return '<div class="task-list-item"><input type="checkbox" class="task-check" checked onclick="toggleTask(' + idx + ', true)"> <span><del>' + line.substring(line.indexOf('] ') + 2) + '</del></span></div>'; 
                }
                
                if (t.startsWith('- ')) {
                    return '<div style="margin-left: 20px;">• ' + line.substring(line.indexOf('- ')+2) + '</div>'; 
                }
                
                return '<div>' + line + '</div>';
            }).join(''); 
        } 
    } 
    
    return res; 
}

function isReminderActive(node) { 
    if (node.reminder && new Date(node.reminder) <= new Date()) {
        return true;
    }
    return false;
}

function openReminderModal() {
    if(!activeNoteData) {
        return;
    }
    
    document.getElementById('reminder-modal').style.display = 'flex';
    
    const hasTimeCb = document.getElementById('reminder-has-time'); 
    const dateInp = document.getElementById('reminder-date'); 
    const dtInp = document.getElementById('reminder-datetime');
    
    if (activeNoteData.reminder) { 
        if (activeNoteData.reminder.includes('T')) { 
            hasTimeCb.checked = true; 
            dtInp.value = activeNoteData.reminder; 
        } else { 
            hasTimeCb.checked = false; 
            dateInp.value = activeNoteData.reminder; 
        } 
    } else { 
        hasTimeCb.checked = false; 
        dateInp.value = ''; 
        dtInp.value = ''; 
    }
    
    toggleReminderInput();
}

function toggleReminderInput() { 
    const hasTime = document.getElementById('reminder-has-time').checked; 
    
    if (hasTime) {
        document.getElementById('reminder-date').style.display = 'none';
        document.getElementById('reminder-datetime').style.display = 'block';
    } else {
        document.getElementById('reminder-date').style.display = 'block';
        document.getElementById('reminder-datetime').style.display = 'none';
    }
}

async function saveReminder() {
    if(!activeNoteData) {
        return;
    }
    
    const hasTime = document.getElementById('reminder-has-time').checked; 
    let val = "";
    
    if (hasTime) {
        val = document.getElementById('reminder-datetime').value;
    } else {
        val = document.getElementById('reminder-date').value;
    }
    
    if(val) { 
        activeNoteData.reminder = val; 
        document.getElementById('reminder-modal').style.display = 'none'; 
        
        await fetch(`/api/notes/${activeId}`, { 
            method: 'PUT', 
            headers: {
                'Content-Type': 'application/json'
            }, 
            body: JSON.stringify(activeNoteData) 
        }); 
        
        await checkAndReloadData(); 
        renderDisplayArea(); 
    }
}

async function clearReminder() { 
    if(activeNoteData && activeNoteData.reminder) { 
        activeNoteData.reminder = null; 
        
        await fetch(`/api/notes/${activeId}`, { 
            method: 'PUT', 
            headers: {
                'Content-Type': 'application/json'
            }, 
            body: JSON.stringify(activeNoteData) 
        }); 
        
        await checkAndReloadData(); 
        renderDisplayArea(); 
    } 
}

function toggleWebhookModal() { 
    document.getElementById('webhook-modal').style.display = 'flex'; 
    document.getElementById('webhook-enabled').checked = fullTree.settings.webhook_enabled || false; 
    document.getElementById('webhook-method').value = fullTree.settings.webhook_method || 'GET'; 
    document.getElementById('webhook-url').value = fullTree.settings.webhook_url || ''; 
    document.getElementById('webhook-payload').value = fullTree.settings.webhook_payload || ''; 
    
    toggleWebhookPayload(); 
}

function toggleWebhookPayload() { 
    if (document.getElementById('webhook-method').value === 'POST') {
        document.getElementById('webhook-payload-container').style.display = 'block';
    } else {
        document.getElementById('webhook-payload-container').style.display = 'none';
    }
}

async function saveWebhook() {
    const payload = { 
        webhook_enabled: document.getElementById('webhook-enabled').checked, 
        webhook_method: document.getElementById('webhook-method').value, 
        webhook_url: document.getElementById('webhook-url').value, 
        webhook_payload: document.getElementById('webhook-payload').value 
    };
    
    await fetch('/api/settings', { 
        method: 'POST', 
        headers: {
            'Content-Type': 'application/json'
        }, 
        body: JSON.stringify(payload) 
    }); 
    
    fullTree.settings.webhook_enabled = payload.webhook_enabled; 
    document.getElementById('webhook-modal').style.display = 'none'; 
    updateMenuUI();
}

function showModal(title, text, buttons, showInput=false) { 
    document.getElementById('modal-title').innerText = title; 
    document.getElementById('modal-text').innerText = text; 
    
    const inp = document.getElementById('modal-input'); 
    
    if (showInput) {
        inp.style.display = 'block';
    } else {
        inp.style.display = 'none';
    }
    
    inp.value = ''; 
    
    const container = document.getElementById('modal-btns-container'); 
    container.innerHTML = ''; 
    
    buttons.forEach(btn => { 
        const b = document.createElement('button'); 
        b.innerText = btn.label; 
        b.className = btn.class; 
        
        b.onclick = () => { 
            document.getElementById('custom-modal').style.display = 'none'; 
            btn.action(); 
        }; 
        
        container.appendChild(b); 
    }); 
    
    document.getElementById('custom-modal').style.display = 'flex'; 
    
    if (showInput) {
        setTimeout(() => {
            inp.focus();
        }, 100); 
    }
}

function clearSearch() { 
    document.getElementById('search-input').value = ''; 
    document.getElementById('clear-search').style.display = 'none'; 
    renderTree(); 
}

function filterTree() {
    const term = document.getElementById('search-input').value.toLowerCase(); 
    const clearBtn = document.getElementById('clear-search');
    
    if (!term) { 
        clearBtn.style.display = 'none'; 
        renderTree(); 
        return; 
    }
    
    clearBtn.style.display = 'flex'; 
    
    const container = document.getElementById('tree'); 
    container.innerHTML = '';
    
    const rootGroup = document.createElement('div'); 
    rootGroup.className = 'tree-group'; 
    container.appendChild(rootGroup);
    
    function getFilteredItems(items) { 
        let results = []; 
        
        items.forEach(item => { 
            const matchInTitle = item.title && item.title.toLowerCase().includes(term); 
            
            let filteredChildren = [];
            if (item.children) {
                filteredChildren = getFilteredItems(item.children);
            }
            
            if (matchInTitle || filteredChildren.length > 0) {
                results.push({ 
                    ...item, 
                    children: filteredChildren 
                }); 
            }
        }); 
        
        return results; 
    }
    
    renderItems(getFilteredItems(fullTree.content), rootGroup);
}

function togglePassword() {
    if (fullTree.settings.password_enabled) { 
        showModal("Passwortschutz", "Deaktivieren?", [
            { 
                label: "Ja", 
                class: "btn-discard", 
                action: async () => { 
                    await fetch('/api/settings', { 
                        method: 'POST', 
                        headers: {
                            'Content-Type': 'application/json'
                        }, 
                        body: JSON.stringify({
                            password_enabled: false
                        }) 
                    }); 
                    
                    fullTree.settings.password_enabled = false; 
                    updateMenuUI(); 
                }
            }, 
            { 
                label: "Abbruch", 
                class: "btn-cancel", 
                action: () => {} 
            }
        ]); 
    } else { 
        showModal("Passwortschutz", "Neues Passwort:", [
            { 
                label: "Speichern", 
                class: "btn-save", 
                action: async () => { 
                    const pwd = document.getElementById('modal-input').value; 
                    
                    if(pwd) { 
                        await fetch('/api/settings', { 
                            method: 'POST', 
                            headers: {
                                'Content-Type': 'application/json'
                            }, 
                            body: JSON.stringify({
                                password_enabled: true, 
                                password: pwd
                            }) 
                        }); 
                        
                        fullTree.settings.password_enabled = true; 
                        updateMenuUI(); 
                    }
                }
            }, 
            { 
                label: "Abbruch", 
                class: "btn-cancel", 
                action: () => {} 
            }
        ], true); 
    }
}

function toggleAllFolders() {
    const searchTerm = document.getElementById('search-input').value; 
    let totalFolders = 0;
    
    function countFolders(items) { 
        items.forEach(i => { 
            if (i.children && i.children.length > 0) { 
                totalFolders++; 
                countFolders(i.children); 
            } 
        }); 
    }
    
    countFolders(fullTree.content);
    
    if (collapsedIds.size >= totalFolders / 2 && totalFolders > 0) {
        collapsedIds.clear();
    } else { 
        function collect(items) { 
            items.forEach(i => { 
                if(i.children && i.children.length > 0) { 
                    collapsedIds.add(i.id); 
                    collect(i.children); 
                } 
            }); 
        } 
        
        collect(fullTree.content); 
    }
    
    saveCollapsedToLocal(); 
    
    if (searchTerm) {
        filterTree(); 
    } else {
        renderTree();
    }
}

function confirmAutoSort() { 
    showModal("Sortieren?", "Automatisch alphabetisch sortieren?", [ 
        { 
            label: "Ja, Sortieren", 
            class: "btn-discard", 
            action: async () => { 
                await applyAutoSort(); 
            } 
        }, 
        { 
            label: "Abbrechen", 
            class: "btn-cancel", 
            action: () => {} 
        } 
    ]); 
}

async function applyAutoSort() { 
    const sortRecursive = (list) => { 
        list.sort((a, b) => { 
            const aIsFolder = a.children && a.children.length > 0; 
            const bIsFolder = b.children && b.children.length > 0; 
            
            if (aIsFolder && !bIsFolder) {
                return -1; 
            }
            
            if (!aIsFolder && bIsFolder) {
                return 1; 
            }
            
            return a.title.localeCompare(b.title, undefined, {
                numeric: true, 
                sensitivity: 'base'
            }); 
        }); 
        
        list.forEach(item => { 
            if(item.children) {
                sortRecursive(item.children); 
            }
        }); 
    }; 
    
    sortRecursive(fullTree.content); 
    
    document.body.classList.add('edit-mode-active'); 
    renderTree(); 
    await rebuildDataFromDOM(); 
    document.body.classList.remove('edit-mode-active'); 
    renderTree();
}

function wrapSelection(b, a, p = "") { 
    const ta = document.getElementById('node-text'); 
    const s = ta.selectionStart; 
    const e = ta.selectionEnd; 
    
    let txt = ta.value.substring(s, e);
    if (!txt) {
        txt = p;
    }
    
    ta.value = ta.value.substring(0, s) + b + txt + a + ta.value.substring(e); 
    ta.focus(); 
    ta.setSelectionRange(s + b.length, s + b.length + txt.length); 
}

function handleListAction(prefix, placeholder) {
    const ta = document.getElementById('node-text'); 
    const start = ta.selectionStart; 
    const end = ta.selectionEnd; 
    const text = ta.value; 
    const selectedText = text.substring(start, end);
    
    if (selectedText.includes('\n')) { 
        const newText = selectedText.split('\n').map(line => { 
            if (line.trim() === '' || line.trim().startsWith(prefix.trim())) {
                return line; 
            }
            return prefix + line; 
        }).join('\n'); 
        
        ta.value = text.substring(0, start) + newText + text.substring(end); 
        ta.setSelectionRange(start, start + newText.length); 
        ta.focus(); 
        return; 
    }
    
    const textBefore = text.substring(0, start);
    
    if (selectedText === placeholder && textBefore.endsWith(prefix)) { 
        const insertStr = '\n' + prefix + placeholder; 
        ta.value = text.substring(0, end) + insertStr + text.substring(end); 
        const newStart = end + '\n'.length + prefix.length; 
        ta.setSelectionRange(newStart, newStart + placeholder.length); 
        ta.focus(); 
        return; 
    }
    
    let insertPrefix = prefix; 
    
    if (textBefore.length > 0 && !textBefore.endsWith('\n')) {
        insertPrefix = '\n' + prefix;
    }
    
    let insertText = selectedText;
    if (!insertText) {
        insertText = placeholder;
    }
    
    const insertStr = insertPrefix + insertText; 
    ta.value = text.substring(0, start) + insertStr + text.substring(end); 
    
    const selectStart = start + insertPrefix.length; 
    ta.setSelectionRange(selectStart, selectStart + insertText.length); 
    ta.focus();
}

function insertCodeTag() { 
    wrapSelection("'''\n", "\n'''", "CODE"); 
}

function copyToClipboard(btn) { 
    const code = btn.nextElementSibling.innerText; 
    const el = document.createElement('textarea'); 
    el.value = code; 
    document.body.appendChild(el); 
    el.select(); 
    document.execCommand('copy'); 
    document.body.removeChild(el); 
    
    btn.innerText = 'Copied!'; 
    
    setTimeout(() => {
        btn.innerText = 'Copy';
    }, 2000); 
}

function toggleSettings(e) { 
    e.stopPropagation(); 
    const m = document.getElementById('dropdown-menu'); 
    
    if (m.style.display === 'block') {
        m.style.display = 'none';
    } else {
        m.style.display = 'block';
    }
}

document.addEventListener('click', () => { 
    const m = document.getElementById('dropdown-menu'); 
    if (m) {
        m.style.display = 'none'; 
    }
});

function exportData() { 
    window.location.href = '/api/export'; 
}

function toggleSidebar() { 
    const h = document.body.classList.toggle('sidebar-hidden'); 
    
    if (h) {
        localStorage.setItem('sidebarState', 'closed');
        document.querySelector('#mobile-toggle-btn span').innerText = '▶';
    } else {
        localStorage.setItem('sidebarState', 'open');
        document.querySelector('#mobile-toggle-btn span').innerText = '◀';
    }
}

async function uploadImage() { 
    const input = document.createElement('input'); 
    input.type = 'file'; 
    input.accept = 'image/*'; 
    
    input.onchange = async (e) => { 
        const file = e.target.files[0]; 
        
        if (!file) {
            return; 
        }
        
        const fd = new FormData(); 
        fd.append('image', file); 
        
        try { 
            const res = await fetch('/api/upload', { 
                method: 'POST', 
                body: fd 
            }); 
            
            const data = await res.json(); 
            
            if(data.filename) {
                wrapSelection(`[img:${data.filename}]`, '', ''); 
            } else { 
                showModal("Fehler", "Ungültig.", [
                    { 
                        label: "OK", 
                        class: "btn-cancel", 
                        action: () => {} 
                    }
                ]); 
            } 
        } catch(err) {
            console.error(err);
        } 
    }; 
    
    input.click(); 
}

async function uploadGenericFile() { 
    const input = document.createElement('input'); 
    input.type = 'file'; 
    
    input.onchange = async (e) => { 
        const file = e.target.files[0]; 
        
        if (!file) {
            return; 
        }
        
        if (file.size > 20 * 1024 * 1024) { 
            showModal("Zu groß", "Max. 20 MB.", [
                { 
                    label: "OK", 
                    class: "btn-cancel", 
                    action: () => {} 
                }
            ]); 
            return; 
        }
        
        const fd = new FormData(); 
        fd.append('file', file); 
        
        try { 
            const res = await fetch('/api/upload', { 
                method: 'POST', 
                body: fd 
            }); 
            
            const data = await res.json(); 
            
            if(data.filename) { 
                let txt = "";
                if (file.type.startsWith('image/')) {
                    txt = `[img:${data.filename}]`;
                } else {
                    txt = `[file:${data.filename}|${data.original}]`;
                }
                
                const s = ta.selectionStart; 
                ta.value = ta.value.substring(0, s) + txt + ta.value.substring(ta.selectionEnd); 
                ta.focus(); 
                ta.setSelectionRange(s + txt.length, s + txt.length); 
            } 
        } catch(err) {
            console.error(err);
        } 
    }; 
    
    input.click(); 
}

function openLightbox(src) { 
    document.getElementById('lightbox-img').src = src; 
    document.getElementById('lightbox').style.display = 'flex'; 
}

function closeLightbox() { 
    document.getElementById('lightbox').style.display = 'none'; 
    document.getElementById('lightbox-img').src = ''; 
}

function getAllNotesFlat(nodes, path="") { 
    let res = []; 
    
    nodes.forEach(n => { 
        let currentPath = "";
        if (path) {
            currentPath = path + " / " + n.title;
        } else {
            currentPath = n.title;
        }
        
        res.push({
            id: n.id, 
            title: n.title, 
            path: currentPath
        }); 
        
        if(n.children) {
            res = res.concat(getAllNotesFlat(n.children, currentPath)); 
        }
    }); 
    
    return res; 
}

function initMentionSystem() {
    const ta = document.getElementById('node-text'); 
    const dropdown = document.getElementById('mention-dropdown');
    
    ta.addEventListener('input', function() {
        let cursor = ta.selectionStart; 
        let textBefore = ta.value.substring(0, cursor); 
        let match = textBefore.match(/(?:^|\s)@([^\n]{0,30})$/);
        
        if (match) {
            let search = match[1].toLowerCase(); 
            let allNotes = getAllNotesFlat(fullTree.content).filter(n => n.id !== activeId);
            
            let filtered = allNotes.filter(n => {
                return n.title.toLowerCase().includes(search) || n.path.toLowerCase().includes(search);
            });
            
            if (filtered.length > 0) { 
                dropdown.innerHTML = ''; 
                
                filtered.forEach(n => { 
                    let div = document.createElement('div'); 
                    div.className = 'mention-item'; 
                    div.innerHTML = `<strong>${n.title}</strong><span class="mention-path">${n.path}</span>`; 
                    
                    div.onclick = () => {
                        insertMention(n.id, n.title, match[1].length + 1); 
                    };
                    
                    dropdown.appendChild(div); 
                }); 
                
                dropdown.style.display = 'block'; 
            } else {
                dropdown.style.display = 'none'; 
            }
        } else {
            dropdown.style.display = 'none'; 
        }
    });
    
    document.addEventListener('click', (e) => { 
        if(e.target !== ta && !dropdown.contains(e.target)) {
            dropdown.style.display = 'none'; 
        }
    });
}

function insertMention(id, title, replaceLength) { 
    let ta = document.getElementById('node-text'); 
    let cursor = ta.selectionStart; 
    let start = cursor - replaceLength; 
    let linkCode = `[note:${id}|${title}] `; 
    
    ta.value = ta.value.substring(0, start) + linkCode + ta.value.substring(cursor); 
    ta.focus(); 
    ta.setSelectionRange(start + linkCode.length, start + linkCode.length); 
    document.getElementById('mention-dropdown').style.display = 'none'; 
}

function triggerMentionButton() { 
    let ta = document.getElementById('node-text'); 
    let s = ta.selectionStart; 
    
    let prefix = "";
    if (s === 0 || ta.value.charAt(s - 1) === '\n' || ta.value.charAt(s - 1) === ' ') {
        prefix = '@';
    } else {
        prefix = ' @';
    }
    
    ta.value = ta.value.substring(0, s) + prefix + ta.value.substring(ta.selectionEnd); 
    ta.focus(); 
    ta.setSelectionRange(s + prefix.length, s + prefix.length); 
    ta.dispatchEvent(new Event('input')); 
}

let sketchCanvas;
let sketchCtx;
let isDrawing = false;
let sketchStrokes = [];
let currentStroke = null; 
let sketchColor = '#000000';
let sketchWidth = 8;
let sketchMode = 'pen';
let sketchBg = 'white';
let activeSketchId = null;

function initSketcher() {
    sketchCanvas = document.getElementById('sketch-canvas'); 
    sketchCtx = sketchCanvas.getContext('2d'); 
    sketchCanvas.width = 1200; 
    sketchCanvas.height = 900;
    
    const getPos = (e) => { 
        const r = sketchCanvas.getBoundingClientRect(); 
        const scaleX = sketchCanvas.width / r.width; 
        const scaleY = sketchCanvas.height / r.height; 
        let cx = e.clientX;
        let cy = e.clientY; 
        
        if(e.touches && e.touches.length > 0) { 
            cx = e.touches[0].clientX; 
            cy = e.touches[0].clientY; 
        } 
        
        return { 
            x: (cx - r.left) * scaleX, 
            y: (cy - r.top) * scaleY 
        }; 
    };
    
    const startDraw = (e) => { 
        e.preventDefault(); 
        isDrawing = true; 
        
        let strokeColor = sketchColor;
        if (sketchMode === 'eraser') {
            strokeColor = sketchBg;
        }
        
        currentStroke = { 
            color: strokeColor, 
            width: sketchWidth, 
            mode: sketchMode, 
            points: [getPos(e)] 
        }; 
        
        sketchStrokes.push(currentStroke); 
    };
    
    const draw = (e) => { 
        if (!isDrawing) {
            return; 
        }
        
        e.preventDefault(); 
        currentStroke.points.push(getPos(e)); 
        redrawSketch(); 
    };
    
    const endDraw = () => { 
        isDrawing = false; 
    };
    
    sketchCanvas.addEventListener('mousedown', startDraw); 
    sketchCanvas.addEventListener('mousemove', draw); 
    window.addEventListener('mouseup', endDraw);
    sketchCanvas.addEventListener('touchstart', startDraw, {passive: false}); 
    sketchCanvas.addEventListener('touchmove', draw, {passive: false}); 
    window.addEventListener('touchend', endDraw);
}

function redrawSketch() { 
    sketchCtx.globalAlpha = 1.0; 
    sketchCtx.fillStyle = sketchBg; 
    sketchCtx.fillRect(0, 0, sketchCanvas.width, sketchCanvas.height); 
    sketchCtx.lineCap = 'round'; 
    sketchCtx.lineJoin = 'round'; 
    
    for (let s of sketchStrokes) { 
        if (s.points.length < 2) {
            continue;
        }
        
        if (s.mode === 'highlighter') {
            sketchCtx.globalAlpha = 0.4;
        } else {
            sketchCtx.globalAlpha = 1.0;
        }
        
        sketchCtx.beginPath(); 
        sketchCtx.strokeStyle = s.color; 
        sketchCtx.lineWidth = s.width; 
        sketchCtx.moveTo(s.points[0].x, s.points[0].y); 
        
        for (let i = 1; i < s.points.length - 1; i++) { 
            let xc = (s.points[i].x + s.points[i + 1].x) / 2; 
            let yc = (s.points[i].y + s.points[i + 1].y) / 2; 
            sketchCtx.quadraticCurveTo(s.points[i].x, s.points[i].y, xc, yc); 
        } 
        
        sketchCtx.lineTo(s.points[s.points.length - 1].x, s.points[s.points.length - 1].y); 
        sketchCtx.stroke(); 
    } 
    
    sketchCtx.globalAlpha = 1.0; 
}

function undoSketch() { 
    if (sketchStrokes.length > 0) { 
        sketchStrokes.pop(); 
        redrawSketch(); 
    } 
}

function setSketchMode(mode) { 
    sketchMode = mode; 
    document.getElementById('btn-pen').classList.toggle('active', mode === 'pen'); 
    document.getElementById('btn-highlighter').classList.toggle('active', mode === 'highlighter'); 
    document.getElementById('btn-eraser').classList.toggle('active', mode === 'eraser'); 
}

function setSketchBg(bg) { 
    sketchBg = bg; 
    
    sketchStrokes.forEach(s => { 
        if (s.mode === 'eraser') {
            s.color = bg; 
        } else if (!s.mode && (s.color === 'white' || s.color === 'black')) { 
            if (s.color !== bg && sketchMode === 'eraser') {
                s.color = bg; 
            }
        } 
    }); 
    
    redrawSketch(); 
}

function initDragAndDrop() { 
    const ta = document.getElementById('node-text'); 
    
    ta.addEventListener('dragover', e => { 
        e.preventDefault(); 
        ta.style.border = '1px dashed var(--accent)'; 
    }); 
    
    ta.addEventListener('dragleave', e => { 
        e.preventDefault(); 
        ta.style.border = '1px solid var(--border-color)'; 
    }); 
    
    ta.addEventListener('drop', async e => { 
        e.preventDefault(); 
        ta.style.border = '1px solid var(--border-color)'; 
        
        if(e.dataTransfer.files && e.dataTransfer.files.length > 0) { 
            const f = e.dataTransfer.files[0]; 
            
            if (f.size > 20 * 1024 * 1024) {
                return;
            }
            
            const fd = new FormData(); 
            fd.append('file', f); 
            
            try { 
                const res = await fetch('/api/upload', { 
                    method: 'POST', 
                    body: fd 
                }); 
                
                const data = await res.json(); 
                
                if(data.filename) { 
                    let txt = "";
                    if (f.type.startsWith('image/')) {
                        txt = `[img:${data.filename}]`;
                    } else {
                        txt = `[file:${data.filename}|${data.original}]`;
                    }
                    
                    const s = ta.selectionStart; 
                    ta.value = ta.value.substring(0, s) + txt + ta.value.substring(ta.selectionEnd); 
                    ta.focus(); 
                    ta.setSelectionRange(s + txt.length, s + txt.length); 
                } 
            } catch(err) {
                console.error(err);
            } 
        } 
    }); 
}

document.addEventListener('keydown', function(e) {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') { 
        if (document.getElementById('edit-mode').style.display === 'block') { 
            e.preventDefault(); 
            saveChanges(); 
        } 
    }
    
    if (e.key === 'Escape') {
        if (document.getElementById('lightbox').style.display === 'flex') {
            closeLightbox();
        } else if (document.getElementById('sketch-modal').style.display === 'flex') {
            closeSketch();
        } else if (document.getElementById('custom-modal').style.display === 'flex') {
            document.getElementById('custom-modal').style.display = 'none';
        } else if (document.getElementById('reminder-modal').style.display === 'flex') {
            document.getElementById('reminder-modal').style.display = 'none';
        } else if (document.getElementById('webhook-modal').style.display === 'flex') {
            document.getElementById('webhook-modal').style.display = 'none';
        } else if (document.getElementById('restore-modal').style.display === 'flex') {
            document.getElementById('restore-modal').style.display = 'none';
        } else if (document.getElementById('edit-mode').style.display === 'block') {
            cancelEdit();
        }
    }
});

async function openRestoreModal() {
    document.getElementById('restore-modal').style.display = 'flex';
    document.getElementById('restore-status').style.display = 'none';
    document.getElementById('restore-file-upload').value = '';
    
    const select = document.getElementById('server-backups');
    select.innerHTML = '<option value="">-- Lade Backups... --</option>';
    
    try {
        const res = await fetch('/api/backups');
        const backups = await res.json();
        
        if (backups.length === 0) {
            select.innerHTML = '<option value="">Keine automatischen Backups gefunden</option>';
        } else {
            select.innerHTML = '<option value="">-- Auswählen --</option>';
            
            backups.forEach(b => {
                const opt = document.createElement('option');
                opt.value = b.filename;
                opt.innerText = `${b.date} (${b.size} MB) - ${b.filename}`;
                select.appendChild(opt);
            });
        }
    } catch(e) {
        select.innerHTML = '<option value="">Fehler beim Laden</option>';
    }
}

async function executeRestore() {
    const fileInput = document.getElementById('restore-file-upload');
    const select = document.getElementById('server-backups');
    const statusDiv = document.getElementById('restore-status');
    const btn = document.getElementById('btn-do-restore');

    const file = fileInput.files[0];
    const serverFile = select.value;

    if (!file && !serverFile) {
        statusDiv.innerText = "Bitte wähle ein Backup aus der Liste oder lade eine Datei hoch!";
        statusDiv.style.color = '#e74c3c';
        statusDiv.style.background = 'rgba(231, 76, 60, 0.1)';
        statusDiv.style.display = 'block';
        return;
    }

    const fd = new FormData();
    
    if (file) {
        fd.append('file', file);
    } else {
        fd.append('server_file', serverFile);
    }

    btn.disabled = true;
    btn.innerText = "Verifiziere & Lade...";
    statusDiv.style.display = 'none';

    try {
        const res = await fetch('/api/restore', {
            method: 'POST',
            body: fd
        });
        
        const data = await res.json();

        if (data.status === 'success') {
            statusDiv.style.color = '#27ae60';
            statusDiv.style.background = 'rgba(39, 174, 96, 0.1)';
            statusDiv.innerText = "Erfolgreich! Die Seite wird nun neu geladen...";
            statusDiv.style.display = 'block';
            
            setTimeout(() => {
                window.location.reload();
            }, 2000);
        } else {
            statusDiv.style.color = '#e74c3c';
            statusDiv.style.background = 'rgba(231, 76, 60, 0.1)';
            
            let errorText = data.error;
            if (!errorText) {
                errorText = "Unbekannter Serverfehler";
            }
            
            statusDiv.innerText = "Fehler: " + errorText;
            statusDiv.style.display = 'block';
            
            btn.disabled = false;
            btn.innerText = "Verifizieren & Wiederherstellen";
        }
    } catch (e) {
        statusDiv.style.color = '#e74c3c';
        statusDiv.style.background = 'rgba(231, 76, 60, 0.1)';
        statusDiv.innerText = "Netzwerkfehler beim Wiederherstellen.";
        statusDiv.style.display = 'block';
        
        btn.disabled = false;
        btn.innerText = "Verifizieren & Wiederherstellen";
    }
}

window.onload = () => { 
    loadData(); 
    initDragAndDrop(); 
    initMentionSystem(); 
    setInterval(checkAndReloadData, 30000); 
};
EOF

# Sicherheit & Rechte: Wir bleiben bei deinem alten "notizen" Nutzer, damit es zu 100 % keine Dateikonflikte gibt!
if ! id -u notizen > /dev/null 2>&1; then 
    useradd -r -s /bin/false notizen
fi

chown -R notizen:notizen $INSTALL_DIR
find $INSTALL_DIR -type d -exec chmod 750 {} \;
find $INSTALL_DIR -type f -exec chmod 640 {} \;

chmod 750 $INSTALL_DIR/backup.sh
chmod 750 $INSTALL_DIR/cleanup.py
chmod +x $INSTALL_DIR/app.py

# Systemd Autostart konfigurieren
if [[ "$AUTOSTART_CONFIRM" =~ ^[Yy]$ ]]; then
    cat << EOF > /etc/systemd/system/$SERVICE_NAME
[Unit]
Description=Notizen V2 (SQLite)
After=network.target

[Service]
User=notizen
Group=notizen
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
fi

# Cronjobs verwalten
if [[ "$CRON_CONFIRM" =~ ^[Yy]$ ]] || [[ "$BACKUP_CONFIRM" =~ ^[Yy]$ ]]; then
    echo "--- Richte Cronjobs ein ---"
    rm -f /etc/cron.d/notizen-tool
    if [[ "$CRON_CONFIRM" =~ ^[Yy]$ ]]; then 
        echo "0 3 * * * notizen /usr/bin/python3 $INSTALL_DIR/cleanup.py" >> /etc/cron.d/notizen-tool
    fi
    if [[ "$BACKUP_CONFIRM" =~ ^[Yy]$ ]]; then 
        echo "0 4 * * * notizen $INSTALL_DIR/backup.sh" >> /etc/cron.d/notizen-tool
    fi
    chmod 644 /etc/cron.d/notizen-tool
fi

# Neustart erzwingen (nur wenn Autostart auch angelegt wurde)
if [[ "$AUTOSTART_CONFIRM" =~ ^[Yy]$ ]]; then
    systemctl restart $SERVICE_NAME
    echo "--- V2 Setup abgeschlossen! Tool ist unter Port $USER_PORT als Systemdienst aktiv. ---"
else
    echo "--- V2 Setup abgeschlossen! ---"
    echo "HINWEIS: Du hast den Autostart deaktiviert. Du musst die App manuell mit 'python3 /opt/notiz-tool/app.py' starten!"
fi
