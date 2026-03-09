import sqlite3
import os
import time

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DB = os.path.join(BASE_DIR, 'data.db')
UPL = os.path.join(BASE_DIR, 'uploads')

if not os.path.exists(DB) or not os.path.exists(UPL): 
    exit()

conn = sqlite3.connect(DB)

sets = dict(conn.execute("SELECT key, value FROM settings").fetchall())
hist_enabled = sets.get('history_enabled', 'true') == 'true'
hist_days = int(sets.get('history_days', '30'))

if hist_enabled:
    cutoff = time.time() - (hist_days * 86400)
    conn.execute("DELETE FROM note_history WHERE saved_at < ?", (cutoff,))
else:
    conn.execute("DELETE FROM note_history")
conn.commit()

used_files = set()
rows = conn.execute("SELECT text FROM notes WHERE text IS NOT NULL").fetchall()
hist_rows = conn.execute("SELECT text FROM note_history WHERE text IS NOT NULL").fetchall()

all_texts = [r[0] for r in rows] + [r[0] for r in hist_rows]

for text in all_texts:
    for f in os.listdir(UPL):
        if f in text: 
            used_files.add(f)
        if f.startswith('sketch_') and f.endswith('.png'):
            sid = f.replace('sketch_', '').replace('.png', '')
            if f"[sketch:{sid}]" in text:
                used_files.add(f)
                used_files.add(f"sketch_{sid}.json")
                
for f in os.listdir(UPL):
    if f == 'contacts':
        continue
    if f not in used_files:
        try: 
            os.remove(os.path.join(UPL, f))
            conn.execute("DELETE FROM media WHERE filename=?", (f,))
        except Exception: 
            pass
            
conn.commit()
