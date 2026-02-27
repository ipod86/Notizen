#!/bin/bash

# Root-Rechte prüfen
if [ "$EUID" -ne 0 ]; then
  echo "FEHLER: Bitte führe dieses Skript als Root (z. B. mit sudo) aus!"
  exit 1
fi

# 1. Port abfragen
echo "Welcher Port soll für das Notiz-Tool genutzt werden? (Standard: 8080)"
read -p "Port: " USER_PORT
if [ -z "$USER_PORT" ]; then 
    USER_PORT=8080
fi

# 2. Autostart abfragen
echo "Soll das Notiz-Tool automatisch beim Systemstart geladen werden? (Y/n)"
read -p "Autostart: " AUTOSTART_CONFIRM
if [ -z "$AUTOSTART_CONFIRM" ]; then 
    AUTOSTART_CONFIRM="y"
fi

# 3. Cronjob Abfragen
echo "Soll ein nächtlicher Cronjob (03:00 Uhr) zum Bereinigen ungenutzter Dateien angelegt werden? (Y/n)"
read -p "Cleanup-Cronjob: " CRON_CONFIRM
if [ -z "$CRON_CONFIRM" ]; then 
    CRON_CONFIRM="y"
fi

echo "Soll ein tägliches Voll-Backup (JSON + Uploads als .tar.gz) um 04:00 Uhr eingerichtet werden? (Y/n)"
read -p "Backup-Cronjob: " BACKUP_CONFIRM
if [ -z "$BACKUP_CONFIRM" ]; then 
    BACKUP_CONFIRM="y"
fi

# 4. Variablen definieren
INSTALL_DIR="/opt/notiz-tool"
SERVICE_NAME="notizen.service"

echo "--- Starte Setup in $INSTALL_DIR auf Port $USER_PORT ---"

# 5. System-Abhängigkeiten
apt update && apt install -y python3 python3-pip python3-venv cron

# 6. Verzeichnisstruktur erstellen
mkdir -p $INSTALL_DIR/static $INSTALL_DIR/templates $INSTALL_DIR/uploads $INSTALL_DIR/backups

# 7. Python Umgebung (angepasst für Debian 13 / Trixie)
python3 -m venv $INSTALL_DIR/venv
$INSTALL_DIR/venv/bin/python3 -m pip install flask werkzeug

# 8. Dateien schreiben

# app.py
cat << 'EOF' > $INSTALL_DIR/app.py
from flask import Flask, render_template, request, jsonify, send_from_directory, session, redirect, url_for, send_file
from werkzeug.security import generate_password_hash, check_password_hash
import json
import os
import uuid
import tarfile
import io
import shutil
import time
import base64

app = Flask(__name__)
app.secret_key = os.urandom(24)

app.config['MAX_CONTENT_LENGTH'] = 50 * 1024 * 1024 

ALLOWED_EXTENSIONS = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'bmp', 'ico', 'pdf', 'zip', 'tar', 'gz', 'rar', 'txt', 'csv', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'mp3', 'mp4', 'mkv', 'avi'}

DATA_FILE = 'data.json'
UPLOAD_FOLDER = 'uploads'

# In-Memory Sperre (Global)
locks = {}

@app.after_request
def add_header(response):
    if request.path.startswith('/uploads/'):
        response.headers['Cache-Control'] = 'public, max-age=31536000'
        return response
    response.headers['Cache-Control'] = 'no-store, no-cache, must-revalidate, post-check=0, pre-check=0, max-age=0'
    response.headers['Pragma'] = 'no-cache'
    response.headers['Expires'] = '-1'
    return response

def allowed_file(filename):
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS

def check_auth():
    if os.path.exists(DATA_FILE):
        with open(DATA_FILE, 'r') as f:
            data = json.load(f)
        if data.get('settings', {}).get('password_enabled') and not session.get('logged_in'):
            return False
    return True

@app.before_request
def require_login():
    if request.endpoint in ['login', 'static']: 
        return
    if not check_auth():
        if request.path.startswith('/api/'): 
            return jsonify({"error": "Unauthorized"}), 401
        return redirect(url_for('login'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    with open(DATA_FILE, 'r') as f: 
        data = json.load(f)
    settings = data.get('settings', {})
    v = str(time.time())
    
    if not settings.get('password_enabled'): 
        return redirect(url_for('index'))
        
    if request.method == 'POST':
        if check_password_hash(settings.get('password_hash', ''), request.form.get('password')):
            session['logged_in'] = True
            return redirect(url_for('index'))
        return render_template('login.html', theme=settings.get('theme', 'dark'), accent=settings.get('accent', '#27ae60'), error="Falsches Passwort", v=v)
        
    return render_template('login.html', theme=settings.get('theme', 'dark'), accent=settings.get('accent', '#27ae60'), v=v)

@app.route('/logout')
def logout():
    session.pop('logged_in', None)
    return redirect(url_for('login'))

@app.route('/')
def index():
    return render_template('index.html', v=str(time.time()))

@app.route('/api/password', methods=['POST'])
def set_password():
    req = request.json
    with open(DATA_FILE, 'r') as f: 
        data = json.load(f)
        
    if not data.get('settings'): 
        data['settings'] = {}
        
    if req.get('enabled'):
        data['settings']['password_enabled'] = True
        data['settings']['password_hash'] = generate_password_hash(req.get('password'))
    else:
        data['settings']['password_enabled'] = False
        data['settings']['password_hash'] = ""
        
    with open(DATA_FILE, 'w') as f: 
        json.dump(data, f, indent=4)
        
    return jsonify({"status": "success", "last_modified": int(os.path.getmtime(DATA_FILE) * 1000)})

@app.route('/api/lock', methods=['POST'])
def handle_lock():
    req = request.json
    client_id = req.get('client_id')
    action = req.get('action')
    now = time.time()

    # Abgelaufene Sperren aufräumen
    expired = [k for k, v in list(locks.items()) if v['expires'] < now]
    for k in expired: 
        del locks[k]

    # Globaler Schlüssel für das gesamte System
    lock_key = 'global'

    if action == 'release':
        if lock_key in locks and locks[lock_key]['client_id'] == client_id:
            del locks[lock_key]
        return jsonify({"status": "released"})

    if action in ['acquire', 'override']:
        if action == 'override' or lock_key not in locks or locks[lock_key]['client_id'] == client_id:
            locks[lock_key] = {'client_id': client_id, 'expires': now + 30}
            return jsonify({"status": "acquired"})
        else:
            return jsonify({"status": "locked"})

    if action == 'heartbeat':
        if lock_key in locks and locks[lock_key]['client_id'] == client_id:
            locks[lock_key]['expires'] = now + 30
            return jsonify({"status": "acquired"})
        else:
            return jsonify({"status": "lost"})

    return jsonify({"error": "invalid action"}), 400

@app.route('/api/notes', methods=['GET', 'POST'])
def handle_notes():
    if request.method == 'POST':
        req_data = request.json
        client_time = req_data.pop('last_modified', None)
        
        if os.path.exists(DATA_FILE) and client_time is not None:
            if int(os.path.getmtime(DATA_FILE) * 1000) > client_time + 100:
                return jsonify({"status": "error", "message": "Konflikt"}), 409
                
        with open(DATA_FILE, 'w') as f: 
            json.dump(req_data, f, indent=4)
            
        return jsonify({"status": "success", "last_modified": int(os.path.getmtime(DATA_FILE) * 1000)})
        
    with open(DATA_FILE, 'r') as f:
        data = json.load(f)
        data['last_modified'] = int(os.path.getmtime(DATA_FILE) * 1000)
        return jsonify(data)

@app.route('/uploads/<filename>')
def uploaded_file(filename):
    return send_from_directory(UPLOAD_FOLDER, filename)

@app.route('/api/upload', methods=['POST'])
def upload_file():
    file = request.files.get('file') or request.files.get('image')
    if not file: 
        return jsonify({"error": "Fehler: Keine Datei gefunden"}), 400
        
    if file and allowed_file(file.filename):
        ext = file.filename.rsplit('.', 1)[1].lower()
        filename = f"{uuid.uuid4().hex}.{ext}"
        file.save(os.path.join(UPLOAD_FOLDER, filename))
        return jsonify({"filename": filename, "original": file.filename})
        
    return jsonify({"error": "Unerlaubter Dateityp"}), 400

@app.route('/api/sketch', methods=['POST'])
def save_sketch():
    data = request.json
    sketch_id = data.get('id')
    if not sketch_id: 
        sketch_id = uuid.uuid4().hex
    
    png_data = data['image'].split(',')[1]
    with open(os.path.join(UPLOAD_FOLDER, f"sketch_{sketch_id}.png"), "wb") as fh:
        fh.write(base64.b64decode(png_data))
        
    with open(os.path.join(UPLOAD_FOLDER, f"sketch_{sketch_id}.json"), "w") as fh:
        json.dump({"bg": data['bg'], "strokes": data['strokes']}, fh)
        
    return jsonify({"id": sketch_id})

@app.route('/api/sketch/<sketch_id>', methods=['GET'])
def load_sketch(sketch_id):
    path = os.path.join(UPLOAD_FOLDER, f"sketch_{sketch_id}.json")
    if os.path.exists(path):
        with open(path, 'r') as f: 
            return jsonify(json.load(f))
    return jsonify({"error": "not found"}), 404

@app.route('/api/export', methods=['GET'])
def export_backup():
    memory_file = io.BytesIO()
    with tarfile.open(fileobj=memory_file, mode='w:gz') as tar:
        tar.add(DATA_FILE, arcname='data.json')
        if os.path.exists(UPLOAD_FOLDER):
            tar.add(UPLOAD_FOLDER, arcname='uploads')
    memory_file.seek(0)
    return send_file(memory_file, download_name='notes_backup.tar.gz', as_attachment=True)

@app.route('/api/import', methods=['POST'])
def import_backup():
    if 'file' not in request.files: 
        return jsonify({"error": "Keine Datei"}), 400
        
    file = request.files['file']
    
    if file.filename.lower().endswith('.json'):
        file.save(DATA_FILE)
        return jsonify({"status": "success"})
        
    try:
        with tarfile.open(fileobj=file, mode='r:*') as tar:
            names = tar.getnames()
            has_data = any(n == 'data.json' or n.endswith('/data.json') for n in names)
            
            if not has_data:
                return jsonify({"error": "Kein gültiges Backup! (data.json fehlt)"}), 400
            
            for f in os.listdir(UPLOAD_FOLDER):
                try: 
                    os.remove(os.path.join(UPLOAD_FOLDER, f))
                except: 
                    pass
                
            for member in tar.getmembers():
                if member.name == 'data.json' or member.name.endswith('/data.json'):
                    source = tar.extractfile(member)
                    if source:
                        with open(DATA_FILE, "wb") as target:
                            shutil.copyfileobj(source, target)
                elif 'uploads/' in member.name and member.isfile():
                    filename = os.path.basename(member.name)
                    source = tar.extractfile(member)
                    if source:
                        with open(os.path.join(UPLOAD_FOLDER, filename), "wb") as target:
                            shutil.copyfileobj(source, target)
                            
        return jsonify({"status": "success"})
        
    except tarfile.TarError:
        return jsonify({"error": f"Datei ist kein gültiges Archiv. Name war: {file.filename}"}), 400
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    pass
EOF

echo "app.run(host='0.0.0.0', port=$USER_PORT, debug=False)" >> $INSTALL_DIR/app.py

# cleanup.py
cat << 'EOF' > $INSTALL_DIR/cleanup.py
import json
import os

DATA_FILE = '/opt/notiz-tool/data.json'
UPLOAD_FOLDER = '/opt/notiz-tool/uploads'

if not os.path.exists(DATA_FILE) or not os.path.exists(UPLOAD_FOLDER): 
    exit()

with open(DATA_FILE, 'r') as f: 
    data = json.load(f)

used_files = set()

def extract_files(nodes):
    for node in nodes:
        text = node.get('text', '')
        for file_name in os.listdir(UPLOAD_FOLDER):
            if file_name in text: 
                used_files.add(file_name)
            
            if file_name.startswith('sketch_') and file_name.endswith('.png'):
                sketch_id = file_name.replace('sketch_', '').replace('.png', '')
                if f"[sketch:{sketch_id}]" in text:
                    used_files.add(file_name)
                    used_files.add(f"sketch_{sketch_id}.json")
                    
        if 'children' in node: 
            extract_files(node['children'])

extract_files(data.get('content', []))

for file_name in os.listdir(UPLOAD_FOLDER):
    if file_name not in used_files:
        try: 
            os.remove(os.path.join(UPLOAD_FOLDER, file_name))
        except: 
            pass
EOF

# backup.sh
cat << 'EOF' > $INSTALL_DIR/backup.sh
#!/bin/bash
cd /opt/notiz-tool
if [ -f data.json ]; then
    tar -czf backups/backup_$(date +%u).tar.gz data.json uploads/
fi
EOF

# static/style.css
cat << 'EOF' > $INSTALL_DIR/static/style.css
:root { 
    --bg-color: #1a1a1a; 
    --sidebar-bg: #252525; 
    --text-color: #e0e0e0; 
    --accent: #27ae60; 
    --accent-rgb: 39, 174, 96; 
    --border-color: #333; 
    --sidebar-width: 300px; 
    --code-bg: #2d2d2d; 
    --code-text: #f8f8f2; 
}

[data-theme="light"] { 
    --bg-color: #f5f5f5; 
    --sidebar-bg: #ffffff; 
    --text-color: #333; 
    --border-color: #ddd; 
    --code-bg: #f0f0f0; 
    --code-text: #222; 
}

html { overscroll-behavior: none; }

body { 
    margin: 0; 
    display: flex; 
    font-family: sans-serif; 
    background: var(--bg-color); 
    color: var(--text-color); 
    overflow: hidden; 
    height: 100dvh; 
    width: 100vw; 
    position: fixed; 
    top: 0; 
    left: 0; 
}

#sidebar { 
    width: var(--sidebar-width); 
    height: 100%; 
    background: var(--sidebar-bg); 
    border-right: 1px solid var(--border-color); 
    display: flex; 
    flex-direction: column; 
    transition: margin-left 0.3s ease; 
    flex-shrink: 0; 
    z-index: 10; 
}

body.sidebar-hidden #sidebar { 
    margin-left: calc(-1 * var(--sidebar-width)); 
}

.sidebar-header { 
    height: 60px; 
    min-height: 60px; 
    flex-shrink: 0; 
    display: flex; 
    justify-content: space-between; 
    align-items: center; 
    padding: 0 15px; 
    border-bottom: 1px solid var(--border-color); 
    box-sizing: border-box; 
    background: var(--sidebar-bg); 
}

#tree { 
    flex-grow: 1; 
    overflow-y: auto; 
    padding: 10px 0 50px 0; 
}

.tree-group { 
    min-height: 10px; 
    padding-left: 15px; 
}

.tree-item-container { 
    margin: 2px 0; 
}

.tree-item { 
    display: flex; 
    align-items: center; 
    padding: 5px; 
    border-radius: 4px; 
    cursor: pointer; 
}

.tree-item.active { 
    background: rgba(var(--accent-rgb), 0.2); 
    color: var(--accent); 
    font-weight: bold; 
}

.search-wrapper { 
    position: relative; 
    margin-bottom: 10px; 
    height: 40px; 
}

#search-input { 
    width: 100%; 
    height: 100%; 
    background: rgba(255,255,255,0.05); 
    border: 1px solid var(--border-color); 
    color: inherit; 
    padding: 0 35px 0 12px; 
    border-radius: 5px; 
    box-sizing: border-box; 
    font-size: 0.95em; 
}

#search-input:focus { 
    outline: none; 
    border-color: var(--accent); 
}

#clear-search { 
    position: absolute; 
    right: 5px; 
    top: 50%; 
    transform: translateY(-50%); 
    width: 30px; 
    height: 30px; 
    display: none; 
    align-items: center; 
    justify-content: center; 
    cursor: pointer; 
    opacity: 0.5; 
    font-size: 1.1em; 
    user-select: none; 
    line-height: 1; 
}

#clear-search:hover { 
    opacity: 1; 
    color: var(--accent); 
}

.drag-handle { 
    display: none; 
    padding: 0 5px 0 0; 
    cursor: grab; 
    color: #888; 
    font-weight: bold; 
    user-select: none; 
    font-size: 1.2em; 
}

body.edit-mode-active .drag-handle { 
    display: inline-block; 
}

body.edit-mode-active .tree-item { 
    cursor: default; 
    border: 1px dashed transparent; 
}

body.edit-mode-active .tree-item:hover { 
    border: 1px dashed rgba(255,255,255,0.1); 
}

body.edit-mode-active #toggle-all-btn { 
    display: none; 
}

#sort-btn { 
    display: none; 
}

body.edit-mode-active #sort-btn { 
    display: inline-block; 
}

.tree-icon { 
    padding: 0 8px; 
    font-size: 1.1em; 
    user-select: none; 
}

.tree-text { 
    flex-grow: 1; 
    padding: 2px 5px; 
    overflow-wrap: anywhere;
    word-break: break-word;
}

button { 
    background: none; 
    border: none; 
    color: inherit; 
    cursor: pointer; 
    font-family: inherit; 
    font-size: inherit; 
}

.add-sub-btn, 
.delete-btn { 
    display: none; 
    font-weight: bold; 
    margin-left: 5px; 
}

body.edit-mode-active .add-sub-btn, 
body.edit-mode-active .delete-btn { 
    display: inline-block; 
}

.add-sub-btn { 
    color: var(--accent) !important; 
    margin-left: auto; 
}

.delete-btn { 
    color: #e74c3c !important; 
}

.toolbar { 
    margin-bottom: 12px; 
    display: flex; 
    flex-wrap: wrap; 
    gap: 4px; 
    align-items: stretch; 
    position: relative; 
    z-index: 20; 
}

.tool-btn { 
    display: flex; 
    flex-direction: column; 
    align-items: center; 
    justify-content: center; 
    min-width: 40px; 
    min-height: 40px; 
    border: 1px solid var(--border-color); 
    border-radius: 4px; 
    padding: 2px 4px; 
    background: rgba(255,255,255,0.02); 
    transition: background 0.2s; 
}

.tool-btn:hover { 
    background: rgba(255,255,255,0.08); 
}

.tool-btn span { 
    font-size: 0.6em; 
    margin-top: 2px; 
    opacity: 0.8; 
    white-space: nowrap;
}

.tool-btn i { 
    font-style: normal; 
    font-size: 1em; 
}

.color-tool { 
    min-width: 46px; 
}

.color-row { 
    display: flex; 
    align-items: center; 
    justify-content: center; 
    gap: 3px; 
    width: 100%; 
    height: 20px; 
    margin-top: 0; 
}

.color-row span { 
    font-size: 1em !important; 
    cursor: pointer; 
    margin: 0 !important; 
    line-height: 20px; 
    display: flex; 
    align-items: center; 
}

#text-color-input { 
    width: 16px; 
    height: 16px; 
    padding: 0; 
    border: 1px solid var(--border-color); 
    background: none; 
    cursor: pointer; 
    border-radius: 3px; 
    appearance: none; 
    -webkit-appearance: none; 
    display: block; 
    margin: 0; 
    flex-shrink: 0; 
}

#text-color-input::-webkit-color-swatch-wrapper { padding: 0; }
#text-color-input::-webkit-color-swatch { border: none; border-radius: 2px; }

#editor { 
    flex-grow: 1; 
    height: 100%; 
    overflow-y: auto; 
    padding: 60px 40px; 
    box-sizing: border-box; 
    position: relative; 
}

#display-area { 
    line-height: 1.5; 
    overflow-wrap: break-word; 
    min-height: 1.5em; 
}

#display-area div { 
    min-height: 1.2em; 
}

b, strong { font-weight: bold; }

input, textarea { 
    width: 100%; 
    background: rgba(255,255,255,0.05); 
    color: inherit; 
    border: 1px solid var(--border-color); 
    padding: 12px; 
    border-radius: 5px; 
    box-sizing: border-box; 
    margin-bottom: 10px; 
    font-family: inherit; 
    transition: border-color 0.2s; 
}

.code-container { 
    position: relative; 
    background: var(--code-bg); 
    color: var(--code-text); 
    padding: 15px; 
    border-radius: 5px; 
    margin: 10px 0; 
    border: 1px solid var(--border-color); 
}

.copy-badge { 
    position: absolute; 
    top: 5px; 
    right: 5px; 
    background: var(--accent) !important; 
    color: white; 
    padding: 2px 8px !important; 
    font-size: 0.7em; 
    border-radius: 3px; 
    opacity: 0.7; 
}

.modal-overlay { 
    display: none; 
    position: fixed; 
    top: 0; 
    left: 0; 
    width: 100%; 
    height: 100%; 
    background: rgba(0,0,0,0.7); 
    z-index: 2000; 
    justify-content: center; 
    align-items: center; 
}

.modal { 
    background: var(--sidebar-bg); 
    padding: 25px; 
    border-radius: 12px; 
    border: 1px solid var(--border-color); 
    text-align: center; 
    max-width: 400px; 
}

.modal-btns { 
    display: flex; 
    gap: 10px; 
    justify-content: center; 
    margin-top: 20px; 
}

.btn-save { 
    background: var(--accent) !important; 
    color: white; 
    padding: 8px 20px; 
    border-radius: 5px; 
}

.btn-discard { 
    background: #e74c3c !important; 
    color: white; 
    padding: 8px 20px; 
    border-radius: 5px; 
}

.btn-cancel { 
    border: 1px solid var(--border-color) !important; 
    padding: 8px 20px; 
    border-radius: 5px; 
}

#mobile-toggle-btn { 
    position: fixed; 
    left: var(--sidebar-width); 
    top: 20px; 
    z-index: 1010; 
    background: var(--accent) !important; 
    color: white; 
    padding: 10px !important; 
    border-radius: 0 5px 5px 0; 
    transition: left 0.3s ease; 
}

body.sidebar-hidden #mobile-toggle-btn { 
    left: 0; 
}

.header-actions { 
    position: fixed; 
    top: 15px; 
    right: 20px; 
    z-index: 1000; 
}

.dropdown-content { 
    display: none; 
    position: absolute; 
    right: 0; 
    top: 40px; 
    background: var(--sidebar-bg); 
    border: 1px solid var(--border-color); 
    min-width: 220px; 
    border-radius: 8px; 
    overflow: hidden; 
    box-shadow: 0 4px 15px rgba(0,0,0,0.3); 
}

.menu-row { 
    display: flex; 
    align-items: center; 
    height: 50px; 
    border-bottom: 1px solid var(--border-color); 
    padding: 0 15px; 
    box-sizing: border-box; 
    cursor: pointer; 
    font-size: 14px; 
    transition: background 0.2s; 
}

.menu-row:last-child { border-bottom: none; }
.menu-row:hover { background: rgba(255,255,255,0.05); }
.menu-row span { flex-grow: 1; }

#accent-color-picker { 
    width: 40px; 
    height: 25px; 
    border: none; 
    background: none; 
    cursor: pointer; 
    padding: 0; 
}

.note-img { 
    max-width: 250px; 
    max-height: 250px; 
    border-radius: 4px; 
    cursor: pointer; 
    border: 1px solid var(--border-color); 
    margin: 10px 0; 
    object-fit: cover; 
    transition: opacity 0.2s; 
}

.note-img:hover { opacity: 0.8; }
.sketch-img { border: 2px dashed var(--accent); } 

#lightbox { 
    display: none; 
    position: fixed; 
    top: 0; 
    left: 0; 
    width: 100vw; 
    height: 100vh; 
    background: rgba(0,0,0,0.85); 
    z-index: 3000; 
    justify-content: center; 
    align-items: center; 
}

#lightbox img { 
    max-width: 90%; 
    max-height: 90%; 
    border-radius: 8px; 
    box-shadow: 0 5px 25px rgba(0,0,0,0.5); 
}

#edit-mode { position: relative; }

#mention-dropdown { 
    display: none; 
    position: absolute; 
    top: 65px; 
    left: 0; 
    width: 100%; 
    max-width: 400px; 
    background: var(--sidebar-bg); 
    border: 1px solid var(--accent); 
    border-radius: 8px; 
    max-height: 250px; 
    overflow-y: auto; 
    z-index: 1000; 
    box-shadow: 0 10px 30px rgba(0,0,0,0.5); 
}

.mention-item { 
    padding: 10px 15px; 
    cursor: pointer; 
    border-bottom: 1px solid var(--border-color); 
}

.mention-item:last-child { border-bottom: none; }
.mention-item:hover { background: rgba(var(--accent-rgb), 0.2); }

.mention-path { 
    font-size: 0.75em; 
    color: #888; 
    display: block; 
    margin-top: 3px; 
}

.note-link { 
    color: var(--accent); 
    text-decoration: none; 
    font-weight: bold; 
    padding: 2px 6px; 
    background: rgba(var(--accent-rgb), 0.1); 
    border-radius: 4px; 
    border: 1px solid rgba(var(--accent-rgb), 0.3); 
    transition: all 0.2s; 
    cursor: pointer; 
    display: inline-block; 
    margin: 0 2px;
    max-width: 100%;
    box-sizing: border-box;
    overflow-wrap: anywhere;
    word-break: break-all;
    white-space: normal;
}

.note-link:hover { 
    background: var(--accent); 
    color: white; 
}

.dead-link { 
    color: #888; 
    text-decoration: none; 
    padding: 2px 6px; 
    background: rgba(255,255,255,0.05); 
    border-radius: 4px; 
    border: 1px solid var(--border-color); 
    display: inline-block; 
    margin: 0 2px; 
    cursor: not-allowed; 
}

blockquote { 
    border-left: 4px solid var(--accent); 
    margin: 10px 0; 
    padding: 10px 15px; 
    background: rgba(var(--accent-rgb), 0.05); 
    border-radius: 0 5px 5px 0; 
    font-style: italic; 
    color: #aaa; 
}

hr { 
    border: 0; 
    border-top: 1px solid var(--border-color); 
    margin: 20px 0; 
}

.task-list-item { 
    list-style-type: none; 
    display: flex; 
    align-items: center; 
    gap: 8px; 
    margin: 5px 0; 
}

input[type="checkbox"].task-check { 
    width: 16px; 
    height: 16px; 
    margin: 0; 
    cursor: pointer; 
    accent-color: var(--accent); 
    flex-shrink: 0; 
}

.spoiler { 
    margin: 15px 0; 
    border: 1px solid var(--border-color); 
    border-radius: 6px; 
    background: rgba(255,255,255,0.02); 
    overflow: hidden; 
}

.spoiler summary { 
    font-weight: bold; 
    cursor: pointer; 
    padding: 12px 15px; 
    background: rgba(var(--accent-rgb), 0.1); 
    user-select: none; 
    outline: none; 
    transition: background 0.2s; 
}

.spoiler summary:hover { 
    background: rgba(var(--accent-rgb), 0.2); 
}

.spoiler[open] summary { 
    border-bottom: 1px solid var(--border-color); 
}

.spoiler-content { 
    padding: 15px; 
}

.reminder-icon {
    color: #e74c3c;
    margin-left: 6px;
    font-size: 0.9em;
    animation: pulse 2s infinite;
}

@keyframes pulse {
    0% { opacity: 1; }
    50% { opacity: 0.4; }
    100% { opacity: 1; }
}

/* Sketch Modal CSS */
#sketch-modal .modal { 
    width: 1000px;
    max-width: 95vw; 
    max-height: 95vh; 
    display: flex; 
    flex-direction: column; 
    padding: 15px; 
    box-sizing: border-box;
}

#sketch-toolbar { 
    display: flex; 
    gap: 15px; 
    margin-bottom: 10px; 
    align-items: center; 
    flex-wrap: wrap; 
    background: rgba(255,255,255,0.05); 
    padding: 10px; 
    border-radius: 8px; 
    flex-shrink: 0;
    max-height: 40vh; 
    overflow-y: auto;
}

#canvas-wrapper {
    display: flex;
    justify-content: center;
    align-items: center;
    width: 100%;
}

#sketch-canvas { 
    width: 100%; 
    max-width: calc((95vh - 220px) * 1.333); 
    aspect-ratio: 4 / 3; 
    border: 1px solid var(--border-color); 
    border-radius: 5px; 
    touch-action: none; 
    cursor: crosshair; 
    box-shadow: 0 5px 25px rgba(0,0,0,0.4); 
}

.sketch-tool { display: flex; align-items: center; gap: 5px; font-size: 0.9em; }
.sketch-tool input[type="color"] { width: 30px; height: 30px; padding: 0; border: none; border-radius: 4px; cursor: pointer; }
.sketch-btn { padding: 5px 10px; border-radius: 4px; border: 1px solid var(--border-color); cursor: pointer; background: var(--sidebar-bg); color: var(--text-color); }
.sketch-btn.active { background: var(--accent); color: white; border-color: var(--accent); }
EOF

# templates/login.html
cat << 'EOF' > $INSTALL_DIR/templates/login.html
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width,initial-scale=1.0">
    <title>Login - Notes</title>
    <link rel="stylesheet" href="/static/style.css?v={{ v }}">
    <style> 
        body { 
            display: flex; 
            justify-content: center; 
            align-items: center; 
        } 
        
        .login-box { 
            background: var(--sidebar-bg); 
            padding: 30px; 
            border-radius: 8px; 
            border: 1px solid var(--border-color); 
            text-align: center; 
            width: 300px; 
            box-shadow: 0 5px 20px rgba(0,0,0,0.2); 
        } 
    </style>
</head>
<body data-theme="{{ theme }}">
    <div class="login-box">
        <h2 style="margin-top: 0">Login</h2>
        {% if error %}<p style="color:#e74c3c; font-size: 0.9em; margin-bottom: 15px;">{{ error }}</p>{% endif %}
        <form method="POST">
            <input type="password" name="password" placeholder="Passwort eingeben" required autofocus>
            <button type="submit" style="width:100%; background:{{ accent }} !important; color:white; padding:10px; border-radius:5px; margin-top:10px; font-weight:bold;">Einloggen</button>
        </form>
    </div>
</body>
</html>
EOF

# templates/index.html
cat << 'EOF' > $INSTALL_DIR/templates/index.html
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width,initial-scale=1.0">
    <title>Notes</title>
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
                <div class="menu-row"><span>🎨 Akzentfarbe</span><input type="color" id="accent-color-picker" onchange="updateGlobalAccent(this.value)" onclick="event.stopPropagation()"></div>
                <div class="menu-row" onclick="exportData()"><span>📤 Backup laden (Vollständig)</span></div>
                <div class="menu-row" onclick="document.getElementById('import-file').click()"><span>📥 Restore (tar.gz / json)</span></div>
                <div class="menu-row" onclick="togglePassword()"><span id="pwd-toggle-text">🔒 Passwortschutz an</span></div>
                <div class="menu-row" id="logout-btn" style="display:none; color:#e74c3c;" onclick="window.location.href='/logout'"><span>🚪 Abmelden</span></div>
                <input type="file" id="import-file" style="display:none" onchange="importData(event)">
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
                <button onclick="toggleEditMode()" title="Bearbeiten">✏️</button>
            </div>
        </div>
        <div style="padding:15px; flex-shrink: 0;">
            <div class="search-wrapper">
                <input type="text" id="search-input" placeholder="Suchen..." oninput="filterTree()">
                <span id="clear-search" onclick="clearSearch()">✕</span>
            </div>
            <button onclick="addItem()" style="width:100%;background:var(--accent) !important;color:white;padding:8px;border-radius:4px;font-weight:bold;">+ Hauptkategorie</button>
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
                    <button class="tool-btn" onclick="saveChanges();disableEdit();" style="background:var(--accent) !important; color:white;"><i>💾</i><span>OK</span></button>
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
    
    <div id="sketch-modal" class="modal-overlay">
        <div class="modal">
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
                    <button class="btn-cancel" onclick="document.getElementById('sketch-modal').style.display='none'">Abbruch</button>
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

# static/script.js
cat << 'EOF' > $INSTALL_DIR/static/script.js
var fullData = {content: [], settings: {accent: '#27ae60', theme: 'dark', password_enabled: false}};
var activeId = null;
var collapsedIds = new Set();
var sortables = [];
var currentLastModified = 0;

// --- SPERR-LOGIK (Globales Pessimistic Locking) ---
let myClientId = sessionStorage.getItem('clientId');
if (!myClientId) {
    myClientId = 'client_' + Math.random().toString(36).substring(2, 10);
    sessionStorage.setItem('clientId', myClientId);
}
let lockInterval = null;
let currentlyLocked = false;

async function acquireLock(override = false) {
    try {
        const res = await fetch('/api/lock', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({client_id: myClientId, action: override ? 'override' : 'acquire'})
        });
        const data = await res.json();
        if (data.status === 'acquired') {
            currentlyLocked = true;
            startHeartbeat();
            return true;
        }
    } catch(e) { console.error(e); }
    return false;
}

async function releaseLock() {
    if (!currentlyLocked) return;
    currentlyLocked = false; 
    if (lockInterval) {
        clearInterval(lockInterval);
        lockInterval = null;
    }
    try {
        await fetch('/api/lock', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({client_id: myClientId, action: 'release'})
        });
    } catch(e) { console.error(e); }
}

function startHeartbeat() {
    if (lockInterval) clearInterval(lockInterval);
    lockInterval = setInterval(async () => {
        try {
            const res = await fetch('/api/lock', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({client_id: myClientId, action: 'heartbeat'})
            });
            const data = await res.json();
            if (data.status === 'lost') {
                if (lockInterval) clearInterval(lockInterval);
                lockInterval = null;
                currentlyLocked = false;
                
                showModal("Sperre verloren!", "Jemand anderes hat die Bearbeitung auf einem anderen Gerät erzwungen.", [
                    {label: "Verstanden", class: "btn-cancel", action: () => { 
                        if (document.body.classList.contains('edit-mode-active')) {
                            deactivateTreeEdit();
                        } else {
                            disableEdit(); 
                        }
                    }}
                ]);
            }
        } catch(e) { console.error(e); }
    }, 10000);
}

window.addEventListener('beforeunload', () => {
    if (currentlyLocked) {
        const blob = new Blob([JSON.stringify({client_id: myClientId, action: 'release'})], {type: 'application/json'});
        navigator.sendBeacon('/api/lock', blob);
    }
});
// --- ENDE SPERR-LOGIK ---

// --- ERINNERUNGEN LOGIK ---
function isReminderActive(node) {
    if (!node.reminder) return false;
    return new Date(node.reminder) <= new Date();
}

function hasActiveReminderInChildren(node) {
    if (isReminderActive(node)) return true;
    if (node.children) {
        for (let c of node.children) {
            if (hasActiveReminderInChildren(c)) return true;
        }
    }
    return false;
}

function openReminderModal() {
    const node = findNode(fullData.content, activeId);
    if(!node) return;
    
    document.getElementById('reminder-modal').style.display = 'flex';
    const hasTimeCb = document.getElementById('reminder-has-time');
    const dateInp = document.getElementById('reminder-date');
    const dtInp = document.getElementById('reminder-datetime');
    
    if (node.reminder) {
        if (node.reminder.includes('T')) {
            hasTimeCb.checked = true;
            dtInp.value = node.reminder;
        } else {
            hasTimeCb.checked = false;
            dateInp.value = node.reminder;
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
    document.getElementById('reminder-date').style.display = hasTime ? 'none' : 'block';
    document.getElementById('reminder-datetime').style.display = hasTime ? 'block' : 'none';
}

async function saveReminder() {
    const node = findNode(fullData.content, activeId);
    if(!node) return;
    
    const hasTime = document.getElementById('reminder-has-time').checked;
    const val = hasTime ? document.getElementById('reminder-datetime').value : document.getElementById('reminder-date').value;
    
    if(val) {
        node.reminder = val;
        document.getElementById('reminder-modal').style.display = 'none';
        await saveToServer();
        renderTree();
        selectNode(activeId); 
    }
}

async function clearReminder() {
    const node = findNode(fullData.content, activeId);
    if(node && node.reminder) {
        delete node.reminder;
        await saveToServer();
        renderTree();
        selectNode(activeId);
    }
}

// --- SKETCH LOGIK ---
let sketchCanvas, sketchCtx, isDrawing = false, sketchStrokes = [], currentStroke = null;
let sketchColor = '#000000', sketchWidth = 8, sketchMode = 'pen', sketchBg = 'white', activeSketchId = null;

function initSketcher() {
    sketchCanvas = document.getElementById('sketch-canvas');
    sketchCtx = sketchCanvas.getContext('2d');
    
    sketchCanvas.width = 1200;
    sketchCanvas.height = 900;

    const getPos = (e) => {
        const r = sketchCanvas.getBoundingClientRect();
        const scaleX = sketchCanvas.width / r.width;
        const scaleY = sketchCanvas.height / r.height;
        let cx = e.clientX, cy = e.clientY;
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
        const p = getPos(e);
        
        currentStroke = { 
            color: sketchMode === 'eraser' ? sketchBg : sketchColor, 
            width: sketchWidth, 
            mode: sketchMode, 
            points: [p] 
        };
        sketchStrokes.push(currentStroke);
    };

    const draw = (e) => {
        if (!isDrawing) return; 
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
        if (s.points.length < 2) continue;
        
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

async function openSketch(id = null) {
    document.getElementById('sketch-modal').style.display = 'flex';
    if(!sketchCanvas) initSketcher();
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
            console.error("Konnte Skizze nicht laden.");
        }
    } else {
        sketchBg = document.getElementById('sketch-bg-select').value;
    }
    setSketchMode('pen');
    redrawSketch();
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
            if (s.color !== bg && sketchMode === 'eraser') s.color = bg;
        }
    });
    redrawSketch();
}

function updateCurrentNode() {
    const n = findNode(fullData.content, activeId);
    if(n) { 
        n.text = document.getElementById('node-text').value; 
    }
}

async function saveSketch() {
    const dataUrl = sketchCanvas.toDataURL("image/png");
    const payload = { 
        id: activeSketchId, 
        bg: sketchBg, 
        strokes: sketchStrokes, 
        image: dataUrl 
    };
    
    const res = await fetch('/api/sketch', { 
        method: 'POST', 
        headers: {'Content-Type': 'application/json'}, 
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
        updateCurrentNode();
    }
    
    document.querySelectorAll('.sketch-img').forEach(img => {
        if (img.src.includes(data.id)) {
            img.src = `/uploads/sketch_${data.id}.png?v=` + Date.now();
        }
    });
}
// --- SKETCH LOGIK ENDE ---

function cleanDataArray(arr) {
    if (!arr) return [];
    return arr.filter(item => item !== null && item !== undefined).map(item => ({
        ...item,
        children: cleanDataArray(item.children)
    }));
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
    
    try { 
        const res = await fetch('/api/notes?_t=' + Date.now()); 
        const data = await res.json(); 
        currentLastModified = data.last_modified || 0;
        
        fullData = data && data.content ? data : {content: [], settings: {accent: '#27ae60', theme: 'dark', password_enabled: false}}; 
        if(!fullData.settings) {
            fullData.settings = {accent: '#27ae60', theme: 'dark', password_enabled: false}; 
        }
        
        fullData.content = cleanDataArray(fullData.content);
        
        document.body.setAttribute('data-theme', fullData.settings.theme || 'dark'); 
        applyAccentColor(fullData.settings.accent); 
        updateMenuUI();
        
        if (!savedCollapsed && fullData.content.length > 0) {
            initAllCollapsed(fullData.content);
        }
        
        renderTree(); 
        
        const lastId = localStorage.getItem('lastActiveId'); 
        if (lastId && findNode(fullData.content, lastId)) {
            selectNode(lastId); 
        }
    } catch (e) {
        console.error(e);
    } 
}

async function checkAndReloadData() {
    // Wenn der User tippt ODER die Ordner sortiert -> Nichts tun, um UI nicht zurückzusetzen!
    if (document.getElementById('edit-mode').style.display === 'block') return;
    if (document.body.classList.contains('edit-mode-active')) return;
    
    try {
        const res = await fetch('/api/notes?_t=' + Date.now());
        if (!res.ok) return;
        const data = await res.json();
        
        if (data.last_modified && data.last_modified > currentLastModified) {
            currentLastModified = data.last_modified;
            fullData = data && data.content ? data : {content: [], settings: {accent: '#27ae60', theme: 'dark', password_enabled: false}}; 
            if(!fullData.settings) {
                fullData.settings = {accent: '#27ae60', theme: 'dark', password_enabled: false}; 
            }
            fullData.content = cleanDataArray(fullData.content);
            
            updateMenuUI();
            renderTree();
            
            if (activeId) {
                const n = findNode(fullData.content, activeId);
                if (n) {
                    document.getElementById('view-title').innerText = n.title;
                    document.getElementById('display-area').innerHTML = renderMarkdown(n.text);
                    if(window.hljs) hljs.highlightAll();
                } else {
                    document.getElementById('no-selection').style.display = 'block';
                    document.getElementById('edit-area').style.display = 'none';
                    activeId = null;
                }
            }
        }
    } catch (e) {
        console.error("Auto-sync error:", e);
    }
}

function updateMenuUI() {
    const pwdBtn = document.getElementById('pwd-toggle-text'); 
    const logoutBtn = document.getElementById('logout-btn');
    if(pwdBtn) {
        pwdBtn.innerText = fullData.settings.password_enabled ? '🔓 Passwortschutz aus' : '🔒 Passwortschutz an';
    }
    if(logoutBtn) {
        logoutBtn.style.display = fullData.settings.password_enabled ? 'flex' : 'none';
    }
}

function togglePassword() {
    if (fullData.settings.password_enabled) {
        showModal("Passwortschutz", "Deaktivieren?", [
            { label: "Ja", class: "btn-discard", action: async () => {
                const res = await fetch('/api/password', { 
                    method: 'POST', 
                    headers: {'Content-Type': 'application/json'}, 
                    body: JSON.stringify({enabled: false}) 
                });
                const data = await res.json(); 
                if(data.status === 'success') {
                    currentLastModified = data.last_modified;
                }
                fullData.settings.password_enabled = false; 
                updateMenuUI();
            }}, 
            { label: "Abbruch", class: "btn-cancel", action: () => {} }
        ]);
    } else {
        showModal("Passwortschutz", "Neues Passwort:", [
            { label: "Speichern", class: "btn-save", action: async () => {
                const pwd = document.getElementById('modal-input').value;
                if(pwd) {
                    const res = await fetch('/api/password', { 
                        method: 'POST', 
                        headers: {'Content-Type': 'application/json'}, 
                        body: JSON.stringify({enabled: true, password: pwd}) 
                    });
                    const data = await res.json(); 
                    if(data.status === 'success') {
                        currentLastModified = data.last_modified;
                    }
                    fullData.settings.password_enabled = true; 
                    updateMenuUI();
                }
            }}, 
            { label: "Abbruch", class: "btn-cancel", action: () => {} }
        ], true);
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
    countFolders(fullData.content);

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
        collect(fullData.content);
    }
    saveCollapsedToLocal(); 
    if (searchTerm) filterTree(); else renderTree();
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
            const matchInText = item.text && item.text.toLowerCase().includes(term); 
            const filteredChildren = item.children ? getFilteredItems(item.children) : []; 
            if (matchInTitle || matchInText || filteredChildren.length > 0) {
                results.push({ ...item, children: filteredChildren }); 
            }
        }); 
        return results; 
    }
    
    renderItems(getFilteredItems(fullData.content), rootGroup);
}

function applyAccentColor(hex) { 
    document.documentElement.style.setProperty('--accent', hex); 
    const r = parseInt(hex.slice(1,3), 16), 
          g = parseInt(hex.slice(3,5), 16), 
          b = parseInt(hex.slice(5,7), 16); 
    document.documentElement.style.setProperty('--accent-rgb', `${r}, ${g}, ${b}`); 
    const p = document.getElementById('accent-color-picker'); 
    if(p) p.value = hex; 
}

function updateGlobalAccent(hex) { 
    fullData.settings.accent = hex; 
    applyAccentColor(hex); 
    saveToServer(); 
}

function toggleTheme() { 
    const newTheme = document.body.getAttribute('data-theme') === 'dark' ? 'light' : 'dark'; 
    fullData.settings.theme = newTheme; 
    document.body.setAttribute('data-theme', newTheme); 
    saveToServer(); 
}

function renderTree() { 
    const container = document.getElementById('tree'); 
    container.innerHTML = ''; 
    const rootGroup = document.createElement('div'); 
    rootGroup.className = 'tree-group'; 
    container.appendChild(rootGroup); 
    renderItems(fullData.content, rootGroup); 
    if (document.body.classList.contains('edit-mode-active')) {
        initSortables(); 
    }
}

function renderItems(items, parent) { 
    const isEdit = document.body.classList.contains('edit-mode-active'); 
    items.forEach(item => { 
        if (!item) return;
        
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
        icon.innerText = isFolder ? (isCollapsed ? '📁' : '📂') : '📄'; 
        
        icon.onclick = (e) => { 
            e.stopPropagation(); 
            if (!isEdit && isFolder) { 
                if (collapsedIds.has(item.id)) collapsedIds.delete(item.id); 
                else collapsedIds.add(item.id); 
                saveCollapsedToLocal(); 
                const searchTerm = document.getElementById('search-input').value; 
                if (searchTerm) filterTree(); else renderTree(); 
            } 
        }; 
        
        const text = document.createElement('span'); 
        text.className = 'tree-text'; 
        text.innerText = item.title || 'Unbenannt'; 

        if (hasActiveReminderInChildren(item)) {
            const rSpan = document.createElement('span');
            rSpan.className = 'reminder-icon';
            rSpan.innerText = '⏰';
            text.appendChild(rSpan);
        }
        
        text.onclick = (e) => { 
            e.stopPropagation(); 
            if (!isEdit) tryNavigation(item.id); 
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
    sortables.forEach(s => s.destroy()); 
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

async function toggleEditMode() { 
    const isCurrentlyEdit = document.body.classList.contains('edit-mode-active'); 
    
    if (!isCurrentlyEdit) {
        const locked = await acquireLock();
        if (!locked) {
            showModal("System gesperrt", "Das Notizbuch wird gerade auf einem anderen Gerät bearbeitet.\n\nSperre ignorieren und erzwingen?", [
                { label: "Ja, erzwingen", class: "btn-discard", action: async () => {
                    await acquireLock(true);
                    activateTreeEdit();
                }},
                { label: "Abbrechen", class: "btn-cancel", action: () => {} }
            ]);
            return;
        }
        activateTreeEdit();
    } else {
        deactivateTreeEdit();
    }
}

function activateTreeEdit() {
    document.body.classList.add('edit-mode-active');
    renderTree();
}

function deactivateTreeEdit() {
    document.body.classList.remove('edit-mode-active');
    sortables.forEach(s => s.destroy()); 
    sortables = []; 
    renderTree(); 
    releaseLock(); 
}

function rebuildDataFromDOM() { 
    if (!document.body.classList.contains('edit-mode-active')) return;
    
    function parse(container) { 
        return Array.from(container.querySelectorAll(':scope > .tree-item-container')).map(div => { 
            const id = div.getAttribute('data-id'); 
            const original = findNode(fullData.content, id); 
            const sub = div.querySelector(':scope > .tree-group'); 
            let parsedChildren = sub ? parse(sub) : [];
            if (parsedChildren.length === 0 && original && original.children && original.children.length > 0 && collapsedIds.has(id)) { 
                parsedChildren = original.children; 
            }
            return { 
                id: id, 
                title: original ? original.title : 'Unbenannt', 
                text: original ? original.text : '', 
                reminder: original ? original.reminder : null,
                children: parsedChildren 
            }; 
        }); 
    } 
    
    const rg = document.querySelector('#tree > .tree-group'); 
    if(rg) { 
        const newData = parse(rg);
        if (newData.length >= (fullData.content.length / 2) || fullData.content.length === 0) { 
            fullData.content = newData; 
            saveToServer(); 
        }
    } 
}

function selectNode(id) { 
    activeId = id; 
    localStorage.setItem('lastActiveId', id); 
    const node = findNode(fullData.content, id); 
    
    if (node) { 
        document.getElementById('no-selection').style.display = 'none'; 
        document.getElementById('edit-area').style.display = 'block'; 
        document.getElementById('node-title').value = node.title; 
        document.getElementById('node-text').value = node.text; 
        
        const viewBadge = document.getElementById('view-reminder-badge');
        const viewAck = document.getElementById('view-reminder-ack');
        if (isReminderActive(node)) {
            viewBadge.style.display = 'inline-block';
            viewAck.style.display = 'inline-block';
        } else {
            viewBadge.style.display = 'none';
            viewAck.style.display = 'none';
        }

        const editRemBtnText = document.getElementById('edit-reminder-text');
        const editRemClearBtn = document.getElementById('edit-reminder-clear');
        
        if (node.reminder) {
            editRemBtnText.innerText = node.reminder.replace('T', ' ');
            editRemClearBtn.style.display = 'flex';
        } else {
            editRemBtnText.innerText = 'Erinnerung';
            editRemClearBtn.style.display = 'none';
        }

        const pathData = getPath(fullData.content, id) || []; 
        const breadcrumbEl = document.getElementById('breadcrumb'); 
        breadcrumbEl.innerHTML = '';
        
        pathData.forEach((p, idx) => { 
            const span = document.createElement('span'); 
            span.innerText = p.title; 
            span.style.cursor = 'pointer'; 
            span.onclick = () => tryNavigation(p.id); 
            span.onmouseover = () => span.style.textDecoration = 'underline'; 
            span.onmouseout = () => span.style.textDecoration = 'none'; 
            breadcrumbEl.appendChild(span); 
            if(idx < pathData.length - 1) {
                breadcrumbEl.appendChild(document.createTextNode(' / ')); 
            }
        });
        
        disableEdit(); 
        
        document.querySelectorAll('.tree-item').forEach(el => el.classList.remove('active')); 
        const activeEl = document.querySelector(`.tree-item-container[data-id="${id}"] > .tree-item`); 
        if(activeEl) activeEl.classList.add('active'); 
    } 
}

async function saveChanges() { 
    const node = findNode(fullData.content, activeId); 
    if (node) { 
        node.title = document.getElementById('node-title').value; 
        node.text = document.getElementById('node-text').value; 
        await saveToServer(); 
        renderTree(); 
    } 
}

async function saveToServer() { 
    fullData.last_modified = currentLastModified; 
    const res = await fetch('/api/notes', { 
        method: 'POST', 
        headers: {'Content-Type': 'application/json'}, 
        body: JSON.stringify(fullData) 
    }); 
    
    if (res.status === 409) { 
        showModal("⚠️ Achtung!", "Geändert auf anderem Gerät! Lade neu (F5).", [
            { label: "OK", class: "btn-cancel", action: () => {} }
        ]); 
        return false; 
    }
    
    const data = await res.json(); 
    if (data.status === 'success') { 
        currentLastModified = data.last_modified; 
        return true; 
    } 
    return false;
}

function findNode(items, id) { 
    for (let item of items) { 
        if (item.id === id) return item; 
        if (item.children) { 
            const f = findNode(item.children, id); 
            if (f) return f; 
        } 
    } 
    return null; 
}

function getPath(items, id, path = []) { 
    for (let item of items) { 
        const n = [...path, {title: item.title, id: item.id}]; 
        if (item.id === id) return n; 
        if (item.children) { 
            const r = getPath(item.children, id, n); 
            if (r) return r; 
        } 
    } 
    return null; 
}

function tryNavigation(id) { 
    const node = findNode(fullData.content, activeId); 
    if (node && document.getElementById('edit-mode').style.display === 'block') { 
        if (document.getElementById('node-title').value !== node.title || document.getElementById('node-text').value !== node.text) { 
            showModal("Ungespeichert", "Speichern?", [ 
                { label: "Ja", class: "btn-save", action: () => { saveChanges(); selectNode(id); } }, 
                { label: "Nein", class: "btn-discard", action: () => selectNode(id) }, 
                { label: "Abbruch", class: "btn-cancel", action: () => {} } 
            ]); 
            return; 
        } 
    } 
    selectNode(id); 
}

window.toggleTask = async function(targetIdx, currentlyChecked) {
    const node = findNode(fullData.content, activeId); 
    if(!node) return;
    
    let tIndex = 0;
    let lines = node.text.split('\n');
    
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
    
    node.text = lines.join('\n'); 
    const ta = document.getElementById('node-text'); 
    if(ta) ta.value = node.text;
    
    disableEdit(); 
    await saveToServer();
};

function renderMarkdown(text) { 
    if (!text) return ''; 
    let html = text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); 
    
    html = html.replace(/\[img:(.*?)\]/g, '<img src="/uploads/$1" class="note-img" onclick="openLightbox(this.src)">');
    html = html.replace(/\[sketch:([a-zA-Z0-9]+)\]/g, '<img src="/uploads/sketch_$1.png?v='+Date.now()+'" class="note-img sketch-img" title="Skizze bearbeiten" onclick="openSketch(\'$1\')">');
    html = html.replace(/\[file:([a-zA-Z0-9.\-]+)\|([^\]]+)\]/g, '<a href="/uploads/$1" target="_blank" class="note-link">📎 $2</a>');
    html = html.replace(/\[file:([a-zA-Z0-9.\-]+)\]/g, '<a href="/uploads/$1" target="_blank" class="note-link">📎 Datei Herunterladen</a>');
    
    html = html.replace(/\[note:([a-zA-Z0-9]+)\|([^\]]+)\]/g, (match, id, title) => {
        if (findNode(fullData.content, id)) { 
            return '<a href="#" onclick="tryNavigation(\'' + id + '\'); return false;" class="note-link">@ ' + title + '</a>'; 
        } else { 
            return '<span class="dead-link" title="Notiz wurde gelöscht">@ <del>' + title + '</del></span>'; 
        }
    });
    
    html = html.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer" style="color:var(--accent); text-decoration:underline;">$1</a>');

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
                if (t === '') return '<br>'; 
                if (t === '---') return '<hr>';
                if (t.startsWith('### ')) return '<h3>' + line.substring(4) + '</h3>'; 
                if (t.startsWith('## ')) return '<h2>' + line.substring(3) + '</h2>'; 
                if (t.startsWith('# ')) return '<h1>' + line.substring(2) + '</h1>';
                
                if (t.startsWith('&gt;')) { 
                    let quoteText = line.substring(line.indexOf('&gt;') + 4); 
                    if(quoteText.startsWith(' ')) quoteText = quoteText.substring(1); 
                    return '<blockquote>' + quoteText + '</blockquote>'; 
                }
                
                if (t.startsWith('[s=')) { 
                    let endIdx = t.indexOf(']'); 
                    if (endIdx !== -1) { 
                        let title = t.substring(3, endIdx) || 'Spoiler'; 
                        let rest = t.substring(endIdx + 1).trim(); 
                        let out = '<details class="spoiler"><summary>' + title + '</summary><div class="spoiler-content">'; 
                        if (rest) { 
                            if (rest.endsWith('[/s]')) { 
                                out += rest.substring(0, rest.length - 4) + '</div></details>'; 
                            } else { 
                                out += rest; 
                            } 
                        } 
                        return out; 
                    } 
                }
                
                if (t.endsWith('[/s]')) { 
                    let rest = t.substring(0, t.length - 4).trim(); 
                    let out = ''; 
                    if (rest) out = '<div>' + rest + '</div>'; 
                    return out + '</div></details>'; 
                }
                
                if (t.startsWith('- [ ] ')) { 
                    let text = line.substring(line.indexOf('- [ ] ') + 6); 
                    let idx = window.taskIndexCounter++; 
                    return '<div class="task-list-item"><input type="checkbox" class="task-check" onclick="toggleTask(' + idx + ', false)"> <span>' + text + '</span></div>'; 
                }
                
                if (t.startsWith('- [x] ') || t.startsWith('- [X] ')) { 
                    let text = line.substring(line.indexOf('] ') + 2); 
                    let idx = window.taskIndexCounter++; 
                    return '<div class="task-list-item"><input type="checkbox" class="task-check" checked onclick="toggleTask(' + idx + ', true)"> <span><del>' + text + '</del></span></div>'; 
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

function showModal(title, text, buttons, showInput=false) { 
    document.getElementById('modal-title').innerText = title; 
    document.getElementById('modal-text').innerText = text; 
    const inp = document.getElementById('modal-input'); 
    inp.style.display = showInput ? 'block' : 'none'; 
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
    if (showInput) setTimeout(() => inp.focus(), 100); 
}

function deleteItem(id) { 
    showModal("Löschen", "Sicher?", [ 
        { label: "Löschen", class: "btn-discard", action: () => { 
            removeFromArr(fullData.content, id); 
            if (activeId === id) activeId = null; 
            renderTree(); 
            saveToServer(); 
        } }, 
        { label: "Abbruch", class: "btn-cancel", action: () => {} } 
    ]); 
}

function removeFromArr(arr, id) { 
    for (let i = 0; i < arr.length; i++) { 
        if (arr[i].id === id) { 
            arr.splice(i, 1); 
            return true; 
        } 
        if (arr[i].children && removeFromArr(arr[i].children, id)) return true; 
    } 
    return false; 
}

async function addItem(parentId) { 
    document.getElementById('search-input').value = ''; 
    document.getElementById('clear-search').style.display = 'none';
    
    const newId = Date.now().toString() + Math.random().toString(36).substring(2, 6); 
    const newItem = { id: newId, title: 'Neu', text: '', children: [] }; 
    
    if (parentId) { 
        const p = findNode(fullData.content, parentId); 
        if(p) { 
            if(!p.children) p.children = []; 
            p.children.push(newItem); 
            collapsedIds.delete(parentId); 
            saveCollapsedToLocal(); 
        } 
    } else {
        fullData.content.push(newItem); 
    }
    
    renderTree(); 
    selectNode(newItem.id); 
    enableEdit(); 
    await saveToServer();
}

function wrapSelection(b, a, p = "") { 
    const ta = document.getElementById('node-text'); 
    const s = ta.selectionStart;
    const e = ta.selectionEnd; 
    const txt = ta.value.substring(s, e) || p; 
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
        const lines = selectedText.split('\n');
        const newLines = lines.map(line => {
            if (line.trim() === '') return line; 
            if (line.trim().startsWith(prefix.trim())) return line; 
            return prefix + line;
        });
        const newText = newLines.join('\n');
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

    const insertStr = insertPrefix + (selectedText || placeholder);
    ta.value = text.substring(0, start) + insertStr + text.substring(end);
    const selectStart = start + insertPrefix.length;
    ta.setSelectionRange(selectStart, selectStart + (selectedText || placeholder).length);
    ta.focus();
}

function applyColor() { 
    wrapSelection(`[${document.getElementById('text-color-input').value}]`, `[/#]`, "Farbe"); 
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
    setTimeout(() => btn.innerText = 'Copy', 2000); 
}

function toggleSettings(e) { 
    e.stopPropagation(); 
    const m = document.getElementById('dropdown-menu'); 
    m.style.display = m.style.display === 'block' ? 'none' : 'block'; 
}

document.addEventListener('click', () => { 
    const m = document.getElementById('dropdown-menu'); 
    if (m) m.style.display = 'none'; 
});

function exportData() { 
    window.location.href = '/api/export'; 
}

async function importData(e) { 
    const f = e.target.files[0]; 
    if (!f) return; 
    
    const fd = new FormData(); 
    fd.append('file', f); 
    document.getElementById('import-file').value = '';
    
    try { 
        const res = await fetch('/api/import', { method: 'POST', body: fd }); 
        if(res.ok) { 
            location.reload(); 
        } else { 
            const errData = await res.json(); 
            showModal("Fehler beim Import", "Die Datei konnte nicht verarbeitet werden:\n\n" + (errData.error || "Unbekannter Fehler"), [
                { label: "Verstanden", class: "btn-cancel", action: () => {} }
            ]); 
        } 
    } catch(e) { 
        showModal("Verbindungsfehler", "Upload fehlgeschlagen.", [
            { label: "OK", class: "btn-cancel", action: () => {} }
        ]); 
    }
}

async function enableEdit() { 
    if (!activeId) return;
    
    const locked = await acquireLock();
    if (!locked) {
        showModal("System gesperrt", "Das Notizbuch wird gerade auf einem anderen Gerät bearbeitet.\n\nSperre ignorieren und überschreiben?", [
            { label: "Ja, erzwingen", class: "btn-discard", action: async () => {
                await acquireLock(true);
                showEditArea();
            }},
            { label: "Abbrechen", class: "btn-cancel", action: () => {} }
        ]);
        return;
    }
    showEditArea();
}

function showEditArea() {
    document.getElementById('view-mode').style.display = 'none'; 
    document.getElementById('edit-mode').style.display = 'block'; 
}

function disableEdit() { 
    const n = findNode(fullData.content, activeId); 
    if (n) { 
        document.getElementById('view-title').innerText = n.title; 
        document.getElementById('display-area').innerHTML = renderMarkdown(n.text); 
        if(window.hljs) hljs.highlightAll(); 
    } 
    document.getElementById('view-mode').style.display = 'block'; 
    document.getElementById('edit-mode').style.display = 'none'; 
    releaseLock(); 
}

function cancelEdit() {
    const n = findNode(fullData.content, activeId);
    if (n) {
        document.getElementById('node-title').value = n.title;
        document.getElementById('node-text').value = n.text;
    }
    disableEdit();
}

function toggleSidebar() { 
    const h = document.body.classList.toggle('sidebar-hidden'); 
    localStorage.setItem('sidebarState', h ? 'closed' : 'open'); 
    document.querySelector('#mobile-toggle-btn span').innerText = h ? '▶' : '◀'; 
}

async function uploadImage() { 
    const input = document.createElement('input'); 
    input.type = 'file'; 
    input.accept = 'image/*'; 
    
    input.onchange = async (e) => { 
        const file = e.target.files[0]; 
        if (!file) return; 
        
        const fd = new FormData(); 
        fd.append('image', file); 
        
        try { 
            const res = await fetch('/api/upload', { method: 'POST', body: fd }); 
            const data = await res.json(); 
            if(data.filename) {
                wrapSelection(`[img:${data.filename}]`, '', ''); 
            } else {
                showModal("Fehler", "Ungültiger Dateityp oder Datei zu groß.", [
                    { label: "OK", class: "btn-cancel", action: () => {} }
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
        if (!file) return; 
        
        if (file.size > 20 * 1024 * 1024) {
            showModal("Zu groß", "Die Datei darf maximal 20 MB groß sein.", [{ label: "Verstanden", class: "btn-cancel", action: () => {} }]);
            return;
        }

        const fd = new FormData(); 
        fd.append('file', file); 
        
        try { 
            const res = await fetch('/api/upload', { method: 'POST', body: fd }); 
            const data = await res.json(); 
            if(data.filename) {
                const isImg = file.type.startsWith('image/');
                if (isImg) {
                    wrapSelection(`[img:${data.filename}]`, '', ''); 
                } else {
                    wrapSelection(`[file:${data.filename}|${data.original}]`, '', ''); 
                }
            } else {
                showModal("Fehler", "Ungültiger Dateityp oder Datei zu groß.", [
                    { label: "OK", class: "btn-cancel", action: () => {} }
                ]); 
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
                showModal("Zu groß", "Maximal 20 MB erlaubt.", [{label: "OK", class: "btn-cancel", action: () => {}}]);
                return;
            }

            const fd = new FormData(); 
            fd.append('file', f); 
            try { 
                const res = await fetch('/api/upload', { method: 'POST', body: fd }); 
                const data = await res.json(); 
                if(data.filename) { 
                    const isImg = f.type.startsWith('image/');
                    const txt = isImg ? `[img:${data.filename}]` : `[file:${data.filename}|${data.original}]`; 
                    
                    const s = ta.selectionStart;
                    const end = ta.selectionEnd;
                    ta.value = ta.value.substring(0, s) + txt + ta.value.substring(end); 
                    ta.focus(); 
                    ta.setSelectionRange(s + txt.length, s + txt.length); 
                } 
            } catch(err) {
                console.error(err);
            } 
        } 
    }); 
}

function getAllNotesFlat(nodes, path="") { 
    let res = []; 
    nodes.forEach(n => { 
        let currentPath = path ? path + " / " + n.title : n.title; 
        res.push({id: n.id, title: n.title, path: currentPath}); 
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
            let allNotes = getAllNotesFlat(fullData.content).filter(n => n.id !== activeId);
            let filtered = allNotes.filter(n => n.title.toLowerCase().includes(search) || n.path.toLowerCase().includes(search));
            
            if (filtered.length > 0) {
                dropdown.innerHTML = '';
                filtered.forEach(n => { 
                    let div = document.createElement('div'); 
                    div.className = 'mention-item'; 
                    div.innerHTML = `<strong>${n.title}</strong><span class="mention-path">${n.path}</span>`; 
                    div.onclick = () => insertMention(n.id, n.title, match[1].length + 1); 
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
    let text = ta.value;
    
    let linkCode = `[note:${id}|${title}] `; 
    ta.value = text.substring(0, start) + linkCode + text.substring(cursor); 
    ta.focus();
    
    let newCursor = start + linkCode.length; 
    ta.setSelectionRange(newCursor, newCursor); 
    document.getElementById('mention-dropdown').style.display = 'none';
}

function triggerMentionButton() {
    let ta = document.getElementById('node-text'); 
    let s = ta.selectionStart; 
    let prefix = (s === 0 || ta.value.charAt(s - 1) === '\n' || ta.value.charAt(s - 1) === ' ') ? '@' : ' @';
    
    ta.value = ta.value.substring(0, s) + prefix + ta.value.substring(ta.selectionEnd); 
    ta.focus(); 
    ta.setSelectionRange(s + prefix.length, s + prefix.length); 
    ta.dispatchEvent(new Event('input'));
}

function confirmAutoSort() { 
    showModal("Sortieren?", "Automatisch sortieren?\nAchtung: Dies kann nicht automatisch rückgängig gemacht werden.", [ 
        { label: "Ja, Sortieren", class: "btn-discard", action: async () => { await applyAutoSort(); } }, 
        { label: "Abbrechen", class: "btn-cancel", action: () => {} } 
    ]); 
}

async function applyAutoSort() { 
    const sortRecursive = (list) => { 
        list.sort((a, b) => { 
            const aIsFolder = a.children && a.children.length > 0; 
            const bIsFolder = b.children && b.children.length > 0; 
            if (aIsFolder && !bIsFolder) return -1; 
            if (!aIsFolder && bIsFolder) return 1; 
            return a.title.localeCompare(b.title, undefined, {numeric: true, sensitivity: 'base'}); 
        }); 
        list.forEach(item => { 
            if(item.children) sortRecursive(item.children); 
        }); 
    }; 
    sortRecursive(fullData.content); 
    await saveToServer(); 
    renderTree(); 
}

// --- TASTATUR-SHORTCUTS ---
document.addEventListener('keydown', function(e) {
    // Strg + S (oder Cmd + S) zum Speichern
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') {
        if (document.getElementById('edit-mode').style.display === 'block') {
            e.preventDefault(); // Verhindert den Browser-Speichern-Dialog
            saveChanges();
            disableEdit();
        }
    }
    
    // Escape zum Schließen von Fenstern oder Abbrechen des Bearbeitungsmodus
    if (e.key === 'Escape') {
        if (document.getElementById('lightbox').style.display === 'flex') {
            closeLightbox();
        } else if (document.getElementById('sketch-modal').style.display === 'flex') {
            document.getElementById('sketch-modal').style.display = 'none';
        } else if (document.getElementById('custom-modal').style.display === 'flex') {
            document.getElementById('custom-modal').style.display = 'none';
        } else if (document.getElementById('reminder-modal').style.display === 'flex') {
            document.getElementById('reminder-modal').style.display = 'none';
        } else if (document.getElementById('edit-mode').style.display === 'block') {
            cancelEdit();
        }
    }
});

window.onload = () => { 
    loadData(); 
    initDragAndDrop(); 
    initMentionSystem();
    // Hintergrund-Sync aufrufen
    setInterval(checkAndReloadData, 30000);
};
EOF

# Sicherheit & Rechte
echo "--- Richte Berechtigungen ein ---"

if ! id -u notizen > /dev/null 2>&1; then 
    useradd -r -s /bin/false notizen
fi

if [ ! -f $INSTALL_DIR/data.json ]; then 
    echo '{"settings": {"accent": "#27ae60", "theme": "dark", "password_enabled": false, "password_hash": ""}, "content": []}' > $INSTALL_DIR/data.json
fi

chown -R notizen:notizen $INSTALL_DIR
find $INSTALL_DIR -type d -exec chmod 750 {} \;
find $INSTALL_DIR -type f -exec chmod 640 {} \;

chmod 750 $INSTALL_DIR/backup.sh
chmod 750 $INSTALL_DIR/cleanup.py

# 10. Autostart Logik
if [[ "$AUTOSTART_CONFIRM" =~ ^[Yy]$ ]]; then
    echo "--- Erstelle Systemd Service ---"
    cat << EOF > /etc/systemd/system/$SERVICE_NAME
[Unit]
Description=Notizen Flask App
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
    systemctl restart $SERVICE_NAME
    echo "Autostart wurde aktiviert."
fi

# 11. Cronjobs verwalten
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

echo "------------------------------------------------"
echo "Installation abgeschlossen!"
echo "------------------------------------------------"
