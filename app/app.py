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
import re
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
UPLOAD_FOLDER = 'uploads'
BACKUP_FOLDER = 'backups'

failed_attempts = {}

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
        
        try:
            conn.execute('ALTER TABLE notes ADD COLUMN is_trashed INTEGER DEFAULT 0')
        except sqlite3.OperationalError:
            pass
        
        try:
            conn.execute('ALTER TABLE notes ADD COLUMN share_id TEXT')
        except sqlite3.OperationalError:
            pass
            
        conn.execute('''
            CREATE TABLE IF NOT EXISTS note_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                note_id TEXT,
                title TEXT,
                text TEXT,
                saved_at REAL
            )
        ''')
        
        conn.execute('''
            CREATE TABLE IF NOT EXISTS media (
                id TEXT PRIMARY KEY,
                original_name TEXT,
                filename TEXT,
                file_type TEXT,
                uploaded_at REAL
            )
        ''')

        conn.execute('''
            CREATE TABLE IF NOT EXISTS contacts (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                phone_mobile TEXT,
                phone_landline TEXT,
                email TEXT,
                company TEXT,
                address TEXT,
                notes TEXT,
                image_filename TEXT,
                created_at REAL
            )
        ''')
        
        # Migration: add new columns if upgrading from old schema
        for col in ['phone_mobile', 'phone_landline', 'address', 'notes']:
            try:
                conn.execute(f'ALTER TABLE contacts ADD COLUMN {col} TEXT')
            except sqlite3.OperationalError:
                pass
        # Migration: rename old 'phone' column data to phone_mobile
        try:
            conn.execute("UPDATE contacts SET phone_mobile = phone WHERE phone_mobile IS NULL AND phone IS NOT NULL")
        except sqlite3.OperationalError:
            pass

        conn.execute('''
            CREATE TABLE IF NOT EXISTS tags (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                color TEXT DEFAULT '#27ae60'
            )
        ''')

        conn.execute('''
            CREATE TABLE IF NOT EXISTS note_tags (
                note_id TEXT,
                tag_id TEXT,
                PRIMARY KEY (note_id, tag_id)
            )
        ''')

        conn.execute('''
            CREATE TABLE IF NOT EXISTS templates (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                text TEXT,
                created_at REAL
            )
        ''')

        try:
            conn.execute('ALTER TABLE notes ADD COLUMN is_pinned INTEGER DEFAULT 0')
        except sqlite3.OperationalError:
            pass
        
        if not conn.execute("SELECT key FROM settings WHERE key='theme'").fetchone():
            conn.execute("INSERT INTO settings (key, value) VALUES ('theme', 'dark')")
            conn.execute("INSERT INTO settings (key, value) VALUES ('accent', '#27ae60')")
            conn.execute("INSERT INTO settings (key, value) VALUES ('password_enabled', 'false')")
            conn.execute("INSERT INTO settings (key, value) VALUES ('history_enabled', 'true')")
            conn.execute("INSERT INTO settings (key, value) VALUES ('history_days', '30')")
            conn.execute("INSERT INTO settings (key, value) VALUES ('tree_last_modified', '0')")
            
        conn.execute('DROP TRIGGER IF EXISTS update_tree_mod')
        conn.execute('''
            CREATE TRIGGER update_tree_mod AFTER UPDATE ON notes 
            WHEN COALESCE(OLD.title,'') != COALESCE(NEW.title,'')
              OR COALESCE(OLD.parent_id,'') != COALESCE(NEW.parent_id,'')
              OR COALESCE(OLD.sort_order,0) != COALESCE(NEW.sort_order,0)
              OR COALESCE(OLD.reminder,'') != COALESCE(NEW.reminder,'')
              OR COALESCE(OLD.is_trashed,0) != COALESCE(NEW.is_trashed,0)
              OR COALESCE(OLD.share_id,'') != COALESCE(NEW.share_id,'')
              OR COALESCE(OLD.text,'') != COALESCE(NEW.text,'')
              OR COALESCE(OLD.is_pinned,0) != COALESCE(NEW.is_pinned,0)
            BEGIN 
                UPDATE settings SET value = strftime('%s', 'now') WHERE key = 'tree_last_modified'; 
            END;
        ''')
        
        conn.execute('DROP TRIGGER IF EXISTS insert_tree_mod')
        conn.execute('''
            CREATE TRIGGER insert_tree_mod AFTER INSERT ON notes 
            BEGIN 
                UPDATE settings SET value = strftime('%s', 'now') WHERE key = 'tree_last_modified'; 
            END;
        ''')
        
        conn.execute('DROP TRIGGER IF EXISTS delete_tree_mod')
        conn.execute('''
            CREATE TRIGGER delete_tree_mod AFTER DELETE ON notes 
            BEGIN 
                UPDATE settings SET value = strftime('%s', 'now') WHERE key = 'tree_last_modified'; 
            END;
        ''')

def send_webhook(title, time_str):
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
                
                if url:
                    su = urllib.parse.quote(title)
                    st = urllib.parse.quote(time_str)
                    final_url = url.replace('{{TITLE}}', su).replace('{{TIME}}', st)
                    
                    if method == 'GET':
                        requests.get(final_url, timeout=5)
                    else:
                        sj = title.replace('"', '\\"').replace('\n', ' ')
                        pd = payload.replace('{{TITLE}}', sj).replace('{{TIME}}', time_str)
                        requests.post(final_url, data=pd.encode('utf-8'), headers={'Content-Type': 'application/json'}, timeout=5)
    except Exception as e:
        print(f"Webhook error: {e}")

def trigger_webhook_async(title, time_str):
    threading.Thread(target=send_webhook, args=(title, time_str), daemon=True).start()

def webhook_worker():
    sent_reminders = set()
    while True:
        try:
            with get_db() as conn:
                reminders = conn.execute("SELECT id, title, reminder FROM notes WHERE reminder IS NOT NULL AND reminder != '' AND is_trashed=0").fetchall()
                now = datetime.now()
                
                for r in reminders:
                    try:
                        r_str = r['reminder'].replace('Z', '')
                        if len(r_str) == 10: 
                            r_dt = datetime.strptime(r_str, '%Y-%m-%d')
                        else: 
                            r_dt = datetime.fromisoformat(r_str)
                            
                        key = f"{r['id']}_{r_str}"
                        
                        if r_dt <= now and key not in sent_reminders:
                            send_webhook(r['title'], r_str)
                            sent_reminders.add(key)
                    except Exception: 
                        pass
        except Exception: 
            pass
        time.sleep(30)

init_db()
os.makedirs(os.path.join(UPLOAD_FOLDER, 'contacts'), exist_ok=True)
threading.Thread(target=webhook_worker, daemon=True).start()

@app.after_request
def add_header(response):
    if request.path.startswith('/uploads/') or request.path.startswith('/api/download/'):
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
            if v == 'true': v = True
            elif v == 'false': v = False
            sets[r['key']] = v
        return sets

@app.before_request
def require_login():
    if request.endpoint in ['login', 'static', 'view_shared_note', 'uploaded_file', 'download_file', 'contact_image']: 
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
    
    client_ip = request.headers.get('X-Forwarded-For', request.remote_addr).split(',')[0].strip()
    now = time.time()
    
    if client_ip not in failed_attempts:
        failed_attempts[client_ip] = {'count': 0, 'lock_until': 0, 'first_attempt': now}
    
    if failed_attempts[client_ip]['lock_until'] > now:
        remaining_secs = int(failed_attempts[client_ip]['lock_until'] - now)
        return render_template('login.html', theme=sets.get('theme', 'dark'), accent=sets.get('accent', '#27ae60'), error=f"Zu viele Fehlversuche. Login gesperrt für {remaining_secs} Sekunde(n).", v=str(time.time()))
    
    if failed_attempts[client_ip]['lock_until'] != 0 and failed_attempts[client_ip]['lock_until'] <= now:
        if failed_attempts[client_ip]['count'] >= 5:
            failed_attempts[client_ip] = {'count': 0, 'lock_until': 0, 'first_attempt': now}
        else:
            failed_attempts[client_ip]['lock_until'] = 0

    if request.method == 'POST':
        if check_password_hash(sets.get('password_hash', ''), request.form.get('password')):
            session['logged_in'] = True
            failed_attempts.pop(client_ip, None)
            return redirect(url_for('index'))
        
        failed_attempts[client_ip]['count'] += 1
        trigger_webhook_async(f"Achtung, fehlgeschlagener Login bei Notizen von IP: {client_ip}", datetime.now().strftime('%Y-%m-%d %H:%M:%S'))
        
        if failed_attempts[client_ip]['count'] >= 5:
            failed_attempts[client_ip]['lock_until'] = now + 300
            return render_template('login.html', theme=sets.get('theme', 'dark'), accent=sets.get('accent', '#27ae60'), error="5 Fehlversuche! Login für 5 Minuten gesperrt.", v=str(time.time()))
        
        failed_attempts[client_ip]['lock_until'] = now + 5
        return render_template('login.html', theme=sets.get('theme', 'dark'), accent=sets.get('accent', '#27ae60'), error=f"Falsches Passwort. 5 Sekunden Wartezeit aktiv.", v=str(time.time()))
        
    return render_template('login.html', theme=sets.get('theme', 'dark'), accent=sets.get('accent', '#27ae60'), v=str(time.time()))

@app.route('/logout')
def logout():
    session.pop('logged_in', None)
    return redirect(url_for('login'))

@app.route('/')
def index():
    sets = get_settings()
    return render_template('index.html', 
                           v=str(time.time()), 
                           theme=sets.get('theme', 'dark'), 
                           accent=sets.get('accent', '#27ae60'))

@app.route('/api/tree', methods=['GET'])
def get_tree():
    with get_db() as conn:
        rows = conn.execute("SELECT id, parent_id, sort_order, title, reminder, is_pinned FROM notes WHERE is_trashed=0 ORDER BY sort_order").fetchall()
        sets = get_settings()

        tag_rows = conn.execute("SELECT nt.note_id, t.id as tag_id, t.name, t.color FROM note_tags nt JOIN tags t ON nt.tag_id = t.id").fetchall()
        tags_by_note = {}
        for tr in tag_rows:
            if tr['note_id'] not in tags_by_note:
                tags_by_note[tr['note_id']] = []
            tags_by_note[tr['note_id']].append({'id': tr['tag_id'], 'name': tr['name'], 'color': tr['color']})

        all_ids = {r['id'] for r in rows}
        nodes_by_parent = {}
        for r in rows:
            pid = r['parent_id']
            if pid is not None and pid not in all_ids: 
                pid = None
            if pid not in nodes_by_parent: 
                nodes_by_parent[pid] = []
            node = dict(r)
            node['tags'] = tags_by_note.get(r['id'], [])
            nodes_by_parent[pid].append(node)
            
        def build_tree(pid=None):
            children = nodes_by_parent.get(pid, [])
            for c in children: 
                c['children'] = build_tree(c['id'])
            return children
            
        return jsonify({"content": build_tree(None), "settings": sets, "last_modified": sets.get('tree_last_modified', 0)})

@app.route('/api/tree', methods=['POST'])
def update_tree():
    items = request.json
    with get_db() as conn:
        update_data = [(item.get('parent_id'), item.get('sort_order'), item['id']) for item in items]
        conn.executemany("UPDATE notes SET parent_id=?, sort_order=? WHERE id=?", update_data)
    return jsonify({"status": "success"})

@app.route('/api/search', methods=['GET'])
def search_notes():
    q = request.args.get('q', '')
    if not q: return jsonify([])
    safe_q = f'%{q}%'
    with get_db() as conn:
        rows = conn.execute("SELECT id FROM notes WHERE is_trashed=0 AND (title LIKE ? OR text LIKE ?)", (safe_q, safe_q)).fetchall()
        return jsonify([r['id'] for r in rows])

@app.route('/api/notes/<note_id>', methods=['GET'])
def get_note(note_id):
    with get_db() as conn:
        row = conn.execute("SELECT id, title, text, reminder FROM notes WHERE id=? AND is_trashed=0", (note_id,)).fetchone()
        if row: return jsonify(dict(row))
        return jsonify({"error": "Not found"}), 404

@app.route('/api/notes/<note_id>/backlinks', methods=['GET'])
def get_backlinks(note_id):
    with get_db() as conn:
        rows = conn.execute("SELECT id, title FROM notes WHERE is_trashed=0 AND text LIKE ?", (f'%[note:{note_id}|%',)).fetchall()
        return jsonify([dict(r) for r in rows])

@app.route('/api/notes/<note_id>/history', methods=['GET'])
def get_history(note_id):
    with get_db() as conn:
        rows = conn.execute("SELECT id, title, text, saved_at FROM note_history WHERE note_id=? ORDER BY saved_at DESC", (note_id,)).fetchall()
        return jsonify([dict(r) for r in rows])

@app.route('/api/notes/<note_id>/history/<int:history_id>', methods=['POST'])
def restore_history(note_id, history_id):
    cid = request.json.get('client_id')
    now = time.time()
    with get_db() as conn:
        row = conn.execute("SELECT locked_by, locked_at FROM notes WHERE id=?", (note_id,)).fetchone()
        if row:
            lock_owner = row['locked_by']
            lock_time = row['locked_at'] or 0
            if lock_owner and (now - lock_time) < 30 and lock_owner != cid:
                return jsonify({"error": "Locked"}), 403
                
        hist = conn.execute("SELECT title, text FROM note_history WHERE id=? AND note_id=?", (history_id, note_id)).fetchone()
        if hist:
            sets = get_settings()
            if sets.get('history_enabled', True):
                current = conn.execute("SELECT title, text FROM notes WHERE id=?", (note_id,)).fetchone()
                if current:
                    conn.execute("INSERT INTO note_history (note_id, title, text, saved_at) VALUES (?, ?, ?, ?)",
                                 (note_id, current['title'] or '', current['text'] or '', now))
            conn.execute("UPDATE notes SET title=?, text=? WHERE id=?", (hist['title'], hist['text'], note_id))
    return jsonify({"status": "success"})

@app.route('/api/notes', methods=['POST'])
def create_note():
    data = request.json
    with get_db() as conn:
        conn.execute('''INSERT INTO notes (id, parent_id, sort_order, title, text) VALUES (?, ?, ?, ?, ?)''', 
                     (data['id'], data.get('parent_id'), data.get('sort_order', 999), data.get('title', 'Neu'), data.get('text', '')))
    return jsonify({"status": "success", "id": data['id']})

@app.route('/api/notes/<note_id>', methods=['PUT'])
def update_note(note_id):
    data = request.json
    cid = data.get('client_id')
    now = time.time()
    with get_db() as conn:
        row = conn.execute("SELECT locked_by, locked_at FROM notes WHERE id=?", (note_id,)).fetchone()
        if row:
            lock_owner = row['locked_by']
            lock_time = row['locked_at'] or 0
            is_locked = lock_owner and (now - lock_time) < 30
            if is_locked and lock_owner != cid: return jsonify({"error": "Locked by another client"}), 403

        sets = get_settings()
        if sets.get('history_enabled', True):
            old_row = conn.execute("SELECT title, text FROM notes WHERE id=?", (note_id,)).fetchone()
            if old_row:
                old_title = old_row['title'] or ''
                old_text = old_row['text'] or ''
                new_title = data.get('title') or ''
                new_text = data.get('text') or ''
                if old_title != new_title or old_text != new_text:
                    conn.execute("INSERT INTO note_history (note_id, title, text, saved_at) VALUES (?, ?, ?, ?)",
                                 (note_id, old_title, old_text, now))

        conn.execute('''UPDATE notes SET title=?, text=?, reminder=? WHERE id=?''', (data.get('title'), data.get('text'), data.get('reminder'), note_id))
    return jsonify({"status": "success"})

@app.route('/api/notes/<note_id>', methods=['DELETE'])
def delete_note(note_id):
    now = time.time()
    with get_db() as conn:
        row = conn.execute("SELECT locked_by, locked_at FROM notes WHERE id=?", (note_id,)).fetchone()
        if row:
            lock_owner = row['locked_by']
            lock_time = row['locked_at'] or 0
            if lock_owner and (now - lock_time) < 30:
                return jsonify({"error": "Diese Notiz wird gerade bearbeitet und kann nicht gelöscht werden."}), 403
        def trash_recursive(nid):
            children = conn.execute("SELECT id FROM notes WHERE parent_id=?", (nid,)).fetchall()
            for c in children: 
                trash_recursive(c['id'])
            conn.execute("UPDATE notes SET is_trashed=1 WHERE id=?", (nid,))
        trash_recursive(note_id)
    return jsonify({"status": "success"})

@app.route('/api/trash', methods=['GET'])
def get_trash():
    with get_db() as conn:
        rows = conn.execute("SELECT id, title, parent_id FROM notes WHERE is_trashed=1").fetchall()
        return jsonify([dict(r) for r in rows])

@app.route('/api/trash/restore/<note_id>', methods=['POST'])
def restore_trash(note_id):
    with get_db() as conn:
        def do_restore(nid, check_parent=True):
            row = conn.execute("SELECT parent_id FROM notes WHERE id=?", (nid,)).fetchone()
            pid = row['parent_id'] if row else None
            
            if check_parent and pid:
                p_row = conn.execute("SELECT is_trashed FROM notes WHERE id=?", (pid,)).fetchone()
                if not p_row or p_row['is_trashed'] == 1:
                    pid = None 
                    
            conn.execute("UPDATE notes SET is_trashed=0, parent_id=? WHERE id=?", (pid, nid))
            
            children = conn.execute("SELECT id FROM notes WHERE parent_id=? AND is_trashed=1", (nid,)).fetchall()
            for c in children:
                do_restore(c['id'], False) 
                
        do_restore(note_id, True)
    return jsonify({"status": "success"})

@app.route('/api/trash/empty', methods=['DELETE'])
def empty_trash():
    with get_db() as conn:
        rows = conn.execute("SELECT id FROM notes WHERE is_trashed=1").fetchall()
        for r in rows:
            conn.execute("DELETE FROM note_history WHERE note_id=?", (r['id'],))
        conn.execute("DELETE FROM notes WHERE is_trashed=1")
    return jsonify({"status": "success"})

@app.route('/api/shares', methods=['GET'])
def get_shares():
    with get_db() as conn:
        rows = conn.execute("SELECT id, title, share_id FROM notes WHERE share_id IS NOT NULL AND is_trashed=0").fetchall()
        return jsonify([dict(r) for r in rows])

@app.route('/api/notes/<note_id>/share', methods=['POST'])
def share_note(note_id):
    with get_db() as conn:
        row = conn.execute("SELECT share_id FROM notes WHERE id=?", (note_id,)).fetchone()
        if row and row['share_id']:
            sid = row['share_id']
        else:
            sid = uuid.uuid4().hex
            conn.execute("UPDATE notes SET share_id=? WHERE id=?", (sid, note_id))
    return jsonify({"url": request.host_url + 'share/' + sid})

@app.route('/api/notes/<note_id>/unshare', methods=['POST'])
def unshare_note(note_id):
    with get_db() as conn:
        conn.execute("UPDATE notes SET share_id=NULL WHERE id=?", (note_id,))
    return jsonify({"status": "success"})

@app.route('/share/<share_id>')
def view_shared_note(share_id):
    sets = get_settings()
    with get_db() as conn:
        row = conn.execute("SELECT title, text FROM notes WHERE share_id=? AND is_trashed=0", (share_id,)).fetchone()
        if not row: 
            return "Notiz nicht gefunden oder Freigabe wurde vom Inhaber beendet.", 404
        
        text_b64 = base64.b64encode((row['text'] or '').encode('utf-8')).decode('utf-8')
        return render_template('share.html', 
                               title=row['title'], 
                               text_b64=text_b64, 
                               theme=sets.get('theme', 'dark'), 
                               accent=sets.get('accent', '#27ae60'),
                               v=str(time.time()))

@app.route('/api/todos', methods=['GET'])
def get_todos():
    with get_db() as conn:
        rows = conn.execute("SELECT id, title, text FROM notes WHERE is_trashed=0 AND (text LIKE '%- [ ]%' OR text LIKE '%- [x]%' OR text LIKE '%- [X]%')").fetchall()
        todos = []
        for r in rows:
            text = r['text'] or ''
            lines = text.split('\n')
            t_idx = 0
            for line in lines:
                t = line.strip()
                if t.startswith('- [ ]') or t.startswith('- [x]') or t.startswith('- [X]'):
                    is_checked = not t.startswith('- [ ]')
                    task_text = t[5:].strip()
                    todos.append({
                        "note_id": r['id'],
                        "note_title": r['title'],
                        "task_index": t_idx,
                        "text": task_text,
                        "checked": is_checked
                    })
                    t_idx += 1
        return jsonify(todos)

@app.route('/api/todos/toggle', methods=['POST'])
def toggle_todo_global():
    data = request.json
    nid = data['note_id']
    t_idx = data['task_index']
    with get_db() as conn:
        row = conn.execute("SELECT text FROM notes WHERE id=?", (nid,)).fetchone()
        if not row: 
            return jsonify({"error": "not found"}), 404
        lines = row['text'].split('\n')
        curr_idx = 0
        for i, line in enumerate(lines):
            t = line.strip()
            if t.startswith('- [ ]') or t.startswith('- [x]') or t.startswith('- [X]'):
                if curr_idx == t_idx:
                    if t.startswith('- [ ]'): 
                        lines[i] = line.replace('- [ ]', '- [x]', 1)
                    else: 
                        lines[i] = line.replace('- [x]', '- [ ]', 1).replace('- [X]', '- [ ]', 1)
                    break
                curr_idx += 1
        new_text = '\n'.join(lines)
        conn.execute("UPDATE notes SET text=? WHERE id=?", (new_text, nid))
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

@app.route('/api/webhook/test', methods=['POST'])
def test_webhook():
    data = request.json
    url = data.get('url', '')
    method = data.get('method', 'GET')
    payload = data.get('payload', '')

    if not url: return jsonify({"error": "Keine Ziel-URL angegeben."}), 400

    title = "TEST-ERINNERUNG"
    now_str = datetime.now().strftime('%Y-%m-%d %H:%M')

    try:
        if method == 'GET':
            su = urllib.parse.quote(title)
            st = urllib.parse.quote(now_str)
            final_url = url.replace('{{TITLE}}', su).replace('{{TIME}}', st)
            r = requests.get(final_url, timeout=10)
        else:
            su = urllib.parse.quote(title)
            st = urllib.parse.quote(now_str)
            final_url = url.replace('{{TITLE}}', su).replace('{{TIME}}', st)
            sj = title.replace('"', '\\"').replace('\n', ' ')
            pd = payload.replace('{{TITLE}}', sj).replace('{{TIME}}', now_str)
            r = requests.post(final_url, data=pd.encode('utf-8'), headers={'Content-Type': 'application/json'}, timeout=10)
            
        return jsonify({"status_code": r.status_code, "response_text": r.text[:500]})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/api/lock/<note_id>', methods=['POST'])
def handle_lock(note_id):
    req = request.json
    cid = req.get('client_id')
    action = req.get('action')
    now = time.time()
    with get_db() as conn:
        row = conn.execute("SELECT locked_by, locked_at FROM notes WHERE id=?", (note_id,)).fetchone()
        if not row: return jsonify({"error": "Note not found"}), 404
        c_owner = row['locked_by']
        lock_time = row['locked_at'] or 0
        is_locked = c_owner and (now - lock_time) < 30
        
        if action == 'release':
            if c_owner == cid or not is_locked: 
                conn.execute("UPDATE notes SET locked_by=NULL, locked_at=NULL WHERE id=?", (note_id,))
            return jsonify({"status": "released"})
        elif action == 'heartbeat':
            if c_owner == cid:
                conn.execute("UPDATE notes SET locked_at=? WHERE id=?", (now, note_id))
                return jsonify({"status": "acquired"})
            else: 
                return jsonify({"status": "lost"})
        elif action in ['acquire', 'override']:
            if action == 'override' or not is_locked or c_owner == cid:
                conn.execute("UPDATE notes SET locked_by=?, locked_at=? WHERE id=?", (cid, now, note_id))
                return jsonify({"status": "acquired"})
            else: 
                return jsonify({"status": "locked"})
    return jsonify({"error": "invalid action"}), 400

@app.route('/uploads/<filename>')
def uploaded_file(filename): 
    return send_from_directory(UPLOAD_FOLDER, filename)

@app.route('/uploads/contacts/<filename>')
def contact_image(filename):
    return send_from_directory(os.path.join(UPLOAD_FOLDER, 'contacts'), filename)

@app.route('/api/download/<filename>')
def download_file(filename):
    with get_db() as conn:
        row = conn.execute("SELECT original_name FROM media WHERE filename=?", (filename,)).fetchone()
        orig_name = row['original_name'] if row and row['original_name'] else filename
    return send_from_directory(UPLOAD_FOLDER, filename, as_attachment=True, download_name=orig_name)

@app.route('/api/upload', methods=['POST'])
def upload_file():
    file = request.files.get('file') or request.files.get('image')
    if file:
        ext = file.filename.rsplit('.', 1)[1].lower() if '.' in file.filename else ''
        filename = f"{uuid.uuid4().hex}.{ext}"
        file.save(os.path.join(UPLOAD_FOLDER, filename))
        
        file_type = 'file'
        if file.mimetype.startswith('image/'): file_type = 'image'
        elif file.mimetype.startswith('audio/'): file_type = 'audio'
        
        with get_db() as conn:
            conn.execute("INSERT INTO media (id, original_name, filename, file_type, uploaded_at) VALUES (?, ?, ?, ?, ?)",
                         (uuid.uuid4().hex, file.filename, filename, file_type, time.time()))
                         
        return jsonify({"filename": filename, "original": file.filename})
    return jsonify({"error": "error"}), 400

@app.route('/api/sketch', methods=['POST'])
def save_sketch():
    data = request.json
    is_new = not bool(data.get('id'))
    sid = data.get('id') or uuid.uuid4().hex
    
    filename = f"sketch_{sid}.png"
    
    with open(os.path.join(UPLOAD_FOLDER, filename), "wb") as f: 
        f.write(base64.b64decode(data['image'].split(',')[1]))
    with open(os.path.join(UPLOAD_FOLDER, f"sketch_{sid}.json"), "w") as f: 
        json.dump({"bg": data['bg'], "strokes": data['strokes']}, f)
        
    if is_new:
        with get_db() as conn:
            conn.execute("INSERT INTO media (id, original_name, filename, file_type, uploaded_at) VALUES (?, ?, ?, ?, ?)",
                         (sid, f"Skizze_{sid[:6]}.png", filename, 'sketch', time.time()))
                         
    return jsonify({"id": sid})

@app.route('/api/sketch/<sid>', methods=['GET'])
def load_sketch(sid):
    p = os.path.join(UPLOAD_FOLDER, f"sketch_{sid}.json")
    if os.path.exists(p):
        with open(p, 'r') as f: 
            return jsonify(json.load(f))
    return jsonify({"error": "404"}), 404

@app.route('/api/media', methods=['GET'])
def get_media_list():
    with get_db() as conn:
        rows = conn.execute("SELECT id, original_name, filename, file_type, uploaded_at FROM media ORDER BY uploaded_at DESC").fetchall()
        return jsonify([dict(r) for r in rows])

@app.route('/api/media/<filename>/refs', methods=['GET'])
def get_media_refs(filename):
    with get_db() as conn:
        safe_name = f'%{filename}%'
        rows = conn.execute("SELECT id, title FROM notes WHERE is_trashed=0 AND text LIKE ?", (safe_name,)).fetchall()
        return jsonify([dict(r) for r in rows])

@app.route('/api/media/<filename>', methods=['DELETE'])
def delete_media_item(filename):
    with get_db() as conn:
        media_row = conn.execute("SELECT original_name, file_type FROM media WHERE filename=?", (filename,)).fetchone()
        orig_name = media_row['original_name'] if media_row and media_row['original_name'] else filename
        file_type = media_row['file_type'] if media_row else 'file'
        
        conn.execute("DELETE FROM media WHERE filename=?", (filename,))
        
        search_term = filename
        sid = None
        if filename.startswith('sketch_') and filename.endswith('.png'):
            sid = filename.replace('sketch_', '').replace('.png', '')
            search_term = sid
            
        rows = conn.execute("SELECT id, text FROM notes WHERE text LIKE ?", (f'%{search_term}%',)).fetchall()
        for r in rows:
            new_text = r['text']
            if sid:
                new_text = re.sub(r'\[sketch:' + re.escape(sid) + r'\]', f'[media_deleted:{orig_name}]', new_text)
            else:
                new_text = re.sub(r'\[(img|file|audio):' + re.escape(filename) + r'(\|[^\]]+)?\]', f'[media_deleted:{orig_name}]', new_text)
            conn.execute("UPDATE notes SET text=? WHERE id=?", (new_text, r['id']))
            
        hist_rows = conn.execute("SELECT id, text FROM note_history WHERE text LIKE ?", (f'%{search_term}%',)).fetchall()
        for r in hist_rows:
            new_text = r['text']
            if sid:
                new_text = re.sub(r'\[sketch:' + re.escape(sid) + r'\]', f'[media_deleted:{orig_name}]', new_text)
            else:
                new_text = re.sub(r'\[(img|file|audio):' + re.escape(filename) + r'(\|[^\]]+)?\]', f'[media_deleted:{orig_name}]', new_text)
            conn.execute("UPDATE note_history SET text=? WHERE id=?", (new_text, r['id']))
            
    try:
        os.remove(os.path.join(UPLOAD_FOLDER, filename))
        if filename.startswith('sketch_'):
            json_file = filename.replace('.png', '.json')
            if os.path.exists(os.path.join(UPLOAD_FOLDER, json_file)):
                os.remove(os.path.join(UPLOAD_FOLDER, json_file))
    except Exception:
        pass
        
    return jsonify({"status": "success"})

# --- CONTACTS API ---
@app.route('/api/contacts', methods=['GET'])
def get_contacts():
    with get_db() as conn:
        rows = conn.execute("SELECT id, name, phone_mobile, phone_landline, email, company, address, notes, image_filename, created_at FROM contacts ORDER BY name").fetchall()
        return jsonify([dict(r) for r in rows])

@app.route('/api/contacts', methods=['POST'])
def create_contact():
    data = request.json
    cid = uuid.uuid4().hex
    with get_db() as conn:
        conn.execute("INSERT INTO contacts (id, name, phone_mobile, phone_landline, email, company, address, notes, image_filename, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                     (cid, data.get('name', ''), data.get('phone_mobile', ''), data.get('phone_landline', ''), data.get('email', ''), data.get('company', ''), data.get('address', ''), data.get('notes', ''), None, time.time()))
    return jsonify({"status": "success", "id": cid})

@app.route('/api/contacts/<contact_id>', methods=['PUT'])
def update_contact(contact_id):
    data = request.json
    with get_db() as conn:
        conn.execute("UPDATE contacts SET name=?, phone_mobile=?, phone_landline=?, email=?, company=?, address=?, notes=? WHERE id=?",
                     (data.get('name', ''), data.get('phone_mobile', ''), data.get('phone_landline', ''), data.get('email', ''), data.get('company', ''), data.get('address', ''), data.get('notes', ''), contact_id))
    return jsonify({"status": "success"})

@app.route('/api/contacts/<contact_id>', methods=['DELETE'])
def delete_contact(contact_id):
    with get_db() as conn:
        row = conn.execute("SELECT name, image_filename FROM contacts WHERE id=?", (contact_id,)).fetchone()
        if not row:
            return jsonify({"error": "not found"}), 404
        
        contact_name = row['name'] or 'Unbekannt'
        
        notes = conn.execute("SELECT id, text FROM notes WHERE text LIKE ?", (f'%[contact:{contact_id}]%',)).fetchall()
        for n in notes:
            new_text = n['text'].replace(f'[contact:{contact_id}]', f'[contact_deleted:{contact_name}]')
            conn.execute("UPDATE notes SET text=? WHERE id=?", (new_text, n['id']))
        
        hist_notes = conn.execute("SELECT id, text FROM note_history WHERE text LIKE ?", (f'%[contact:{contact_id}]%',)).fetchall()
        for n in hist_notes:
            new_text = n['text'].replace(f'[contact:{contact_id}]', f'[contact_deleted:{contact_name}]')
            conn.execute("UPDATE note_history SET text=? WHERE id=?", (new_text, n['id']))
        
        if row['image_filename']:
            try:
                os.remove(os.path.join(UPLOAD_FOLDER, 'contacts', row['image_filename']))
            except:
                pass
        
        conn.execute("DELETE FROM contacts WHERE id=?", (contact_id,))
    return jsonify({"status": "success"})

@app.route('/api/contacts/<contact_id>/image', methods=['POST'])
def upload_contact_image(contact_id):
    file = request.files.get('image')
    if not file:
        return jsonify({"error": "no file"}), 400
    
    ext = file.filename.rsplit('.', 1)[1].lower() if '.' in file.filename else 'png'
    filename = f"{contact_id}.{ext}"
    
    os.makedirs(os.path.join(UPLOAD_FOLDER, 'contacts'), exist_ok=True)
    
    with get_db() as conn:
        old = conn.execute("SELECT image_filename FROM contacts WHERE id=?", (contact_id,)).fetchone()
        if old and old['image_filename']:
            try:
                os.remove(os.path.join(UPLOAD_FOLDER, 'contacts', old['image_filename']))
            except:
                pass
    
    file.save(os.path.join(UPLOAD_FOLDER, 'contacts', filename))
    
    with get_db() as conn:
        conn.execute("UPDATE contacts SET image_filename=? WHERE id=?", (filename, contact_id))
    
    return jsonify({"status": "success", "filename": filename})

# --- PIN API ---
@app.route('/api/notes/<note_id>/pin', methods=['POST'])
def toggle_pin(note_id):
    with get_db() as conn:
        row = conn.execute("SELECT is_pinned FROM notes WHERE id=?", (note_id,)).fetchone()
        if not row:
            return jsonify({"error": "not found"}), 404
        new_val = 0 if row['is_pinned'] else 1
        conn.execute("UPDATE notes SET is_pinned=? WHERE id=?", (new_val, note_id))
    return jsonify({"status": "success", "is_pinned": bool(new_val)})

# --- DUPLICATE API ---
@app.route('/api/notes/<note_id>/duplicate', methods=['POST'])
def duplicate_note(note_id):
    with get_db() as conn:
        row = conn.execute("SELECT parent_id, sort_order, title, text, reminder FROM notes WHERE id=? AND is_trashed=0", (note_id,)).fetchone()
        if not row:
            return jsonify({"error": "not found"}), 404
        new_id = uuid.uuid4().hex
        conn.execute("INSERT INTO notes (id, parent_id, sort_order, title, text, reminder) VALUES (?, ?, ?, ?, ?, ?)",
                     (new_id, row['parent_id'], (row['sort_order'] or 0) + 1, (row['title'] or '') + ' (Kopie)', row['text'], None))
        tag_rows = conn.execute("SELECT tag_id FROM note_tags WHERE note_id=?", (note_id,)).fetchall()
        for tr in tag_rows:
            conn.execute("INSERT OR IGNORE INTO note_tags (note_id, tag_id) VALUES (?, ?)", (new_id, tr['tag_id']))
    return jsonify({"status": "success", "id": new_id})

# --- TAGS API ---
@app.route('/api/tags', methods=['GET'])
def get_tags():
    with get_db() as conn:
        rows = conn.execute("SELECT id, name, color FROM tags ORDER BY name").fetchall()
        return jsonify([dict(r) for r in rows])

@app.route('/api/tags', methods=['POST'])
def create_tag():
    data = request.json
    tid = uuid.uuid4().hex
    with get_db() as conn:
        conn.execute("INSERT INTO tags (id, name, color) VALUES (?, ?, ?)",
                     (tid, data.get('name', ''), data.get('color', '#27ae60')))
    return jsonify({"status": "success", "id": tid})

@app.route('/api/tags/<tag_id>', methods=['PUT'])
def update_tag(tag_id):
    data = request.json
    with get_db() as conn:
        conn.execute("UPDATE tags SET name=?, color=? WHERE id=?",
                     (data.get('name', ''), data.get('color', '#27ae60'), tag_id))
        conn.execute("UPDATE settings SET value = strftime('%s', 'now') WHERE key = 'tree_last_modified'")
    return jsonify({"status": "success"})

@app.route('/api/tags/<tag_id>', methods=['DELETE'])
def delete_tag(tag_id):
    with get_db() as conn:
        conn.execute("DELETE FROM note_tags WHERE tag_id=?", (tag_id,))
        conn.execute("DELETE FROM tags WHERE id=?", (tag_id,))
        conn.execute("UPDATE settings SET value = strftime('%s', 'now') WHERE key = 'tree_last_modified'")
    return jsonify({"status": "success"})

@app.route('/api/notes/<note_id>/tags', methods=['GET'])
def get_note_tags(note_id):
    with get_db() as conn:
        rows = conn.execute("SELECT t.id, t.name, t.color FROM note_tags nt JOIN tags t ON nt.tag_id = t.id WHERE nt.note_id=?", (note_id,)).fetchall()
        return jsonify([dict(r) for r in rows])

@app.route('/api/notes/<note_id>/tags', methods=['POST'])
def set_note_tags(note_id):
    data = request.json
    tag_ids = data.get('tag_ids', [])
    with get_db() as conn:
        conn.execute("DELETE FROM note_tags WHERE note_id=?", (note_id,))
        for tid in tag_ids:
            conn.execute("INSERT OR IGNORE INTO note_tags (note_id, tag_id) VALUES (?, ?)", (note_id, tid))
        conn.execute("UPDATE settings SET value = strftime('%s', 'now') WHERE key = 'tree_last_modified'")
    return jsonify({"status": "success"})

# --- TEMPLATES API ---
@app.route('/api/templates', methods=['GET'])
def get_templates():
    with get_db() as conn:
        rows = conn.execute("SELECT id, title, text, created_at FROM templates ORDER BY title").fetchall()
        return jsonify([dict(r) for r in rows])

@app.route('/api/templates', methods=['POST'])
def create_template():
    data = request.json
    tid = uuid.uuid4().hex
    with get_db() as conn:
        conn.execute("INSERT INTO templates (id, title, text, created_at) VALUES (?, ?, ?, ?)",
                     (tid, data.get('title', ''), data.get('text', ''), time.time()))
    return jsonify({"status": "success", "id": tid})

@app.route('/api/templates/<template_id>', methods=['DELETE'])
def delete_template(template_id):
    with get_db() as conn:
        conn.execute("DELETE FROM templates WHERE id=?", (template_id,))
    return jsonify({"status": "success"})

# --- DASHBOARD API ---
@app.route('/api/dashboard', methods=['GET'])
def get_dashboard():
    with get_db() as conn:
        recent = conn.execute("SELECT id, title FROM notes WHERE is_trashed=0 ORDER BY rowid DESC LIMIT 8").fetchall()
        pinned = conn.execute("SELECT id, title FROM notes WHERE is_trashed=0 AND is_pinned=1 ORDER BY title").fetchall()
        
        upcoming = []
        overdue = []
        rem_rows = conn.execute("SELECT id, title, reminder FROM notes WHERE reminder IS NOT NULL AND reminder != '' AND is_trashed=0 ORDER BY reminder").fetchall()
        now = datetime.now()
        for r in rem_rows:
            try:
                r_str = r['reminder'].replace('Z', '')
                r_dt = datetime.fromisoformat(r_str) if 'T' in r_str else datetime.strptime(r_str, '%Y-%m-%d')
                if r_dt >= now:
                    if len(upcoming) < 5:
                        upcoming.append(dict(r))
                else:
                    overdue.append(dict(r))
            except:
                pass
        
        open_tasks = 0
        task_rows = conn.execute("SELECT text FROM notes WHERE is_trashed=0 AND text LIKE '%- [ ]%'").fetchall()
        for tr in task_rows:
            open_tasks += (tr['text'] or '').count('- [ ]')
        
        total_notes = conn.execute("SELECT COUNT(*) as c FROM notes WHERE is_trashed=0").fetchone()['c']
        
        recent_media = conn.execute("SELECT id, original_name, filename, file_type, uploaded_at FROM media ORDER BY uploaded_at DESC LIMIT 6").fetchall()
        
        return jsonify({
            "recent": [dict(r) for r in recent],
            "pinned": [dict(r) for r in pinned],
            "upcoming_reminders": upcoming,
            "overdue_reminders": overdue,
            "open_tasks": open_tasks,
            "total_notes": total_notes,
            "recent_media": [dict(r) for r in recent_media]
        })

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
    return send_file(mem, download_name=filename, as_attachment=True, mimetype='application/gzip')

@app.route('/api/backups', methods=['GET'])
def list_backups():
    backups = []
    if os.path.exists(BACKUP_FOLDER):
        for f in os.listdir(BACKUP_FOLDER):
            if f.endswith('.tar.gz'):
                p = os.path.join(BACKUP_FOLDER, f)
                st = os.stat(p)
                dt = datetime.fromtimestamp(st.st_mtime).strftime('%d.%m.%Y %H:%M:%S')
                backups.append({"filename": f, "date": dt, "ts": st.st_mtime, "size": round(st.st_size / 1024 / 1024, 2)})
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
            except: 
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
                    return jsonify({"error": "Die Datenbank im Backup ist korrupt"}), 400
            except Exception as e: 
                return jsonify({"error": f"Datenbank-Prüfung fehlgeschlagen: {str(e)}"}), 400
            
            if os.path.exists(DB_FILE): 
                shutil.copy2(DB_FILE, DB_FILE + '.pre-restore')
            for ext in ['-wal', '-shm']:
                if os.path.exists(DB_FILE + ext):
                    try: 
                        os.remove(DB_FILE + ext)
                    except: 
                        pass
            
            shutil.copy2(db_path, DB_FILE)
            uploads_ext = os.path.join(tmpdir, 'uploads')
            if os.path.exists(uploads_ext):
                if os.path.exists(UPLOAD_FOLDER): 
                    shutil.rmtree(UPLOAD_FOLDER)
                shutil.copytree(uploads_ext, UPLOAD_FOLDER)
            elif not os.path.exists(UPLOAD_FOLDER): 
                os.makedirs(UPLOAD_FOLDER)

        def restart_app():
            time.sleep(1.5)
            os._exit(0)
        threading.Thread(target=restart_app, daemon=True).start()
        return jsonify({"status": "success"})
        
    except Exception as e: 
        return jsonify({"error": str(e)}), 500
    finally:
        if file and tar_path and os.path.exists(tar_path): 
            os.remove(tar_path)

if __name__ == '__main__':
    port = int(os.environ.get('FLASK_PORT', 8080))
    app.run(host='0.0.0.0', port=port, debug=False)
