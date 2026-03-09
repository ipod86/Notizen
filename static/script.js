var fullTree = { content: [], settings: {} };
var activeId = null;
var activeNoteData = null; 
var collapsedIds = new Set();
var sortables = [];
var currentTreeLastMod = null;
var searchTimeout = null;

var currentTodosList = [];
var contactsCache = [];

let myClientId = sessionStorage.getItem('clientId');
if (!myClientId) {
    myClientId = 'client_' + Math.random().toString(36).substring(2, 10);
    sessionStorage.setItem('clientId', myClientId);
}

let lockInterval = null;
let currentLockedNote = null;

function fallbackCopyTextToClipboard(text) {
    var textArea = document.createElement("textarea");
    textArea.value = text;
    textArea.style.top = "0";
    textArea.style.left = "0";
    textArea.style.position = "fixed";
    document.body.appendChild(textArea);
    textArea.focus();
    textArea.select();
    try {
        document.execCommand('copy');
    } catch (err) {
        console.error('Fallback: Oops, unable to copy', err);
    }
    document.body.removeChild(textArea);
}

function copyText(text) {
    if (!navigator.clipboard) {
        fallbackCopyTextToClipboard(text);
        return;
    }
    navigator.clipboard.writeText(text).catch(function(err) {
        fallbackCopyTextToClipboard(text);
    });
}

function closeAllMenus() {
    const m = document.getElementById('dropdown-menu');
    if (m) m.style.display = 'none';
    const m2 = document.getElementById('note-menu-content');
    if (m2) m2.style.display = 'none';
    document.querySelectorAll('.submenu-content').forEach(s => s.style.display = 'none');
}

function handleMenuAction(e, actionFunc) {
    if (e) e.stopPropagation();
    closeAllMenus();
    actionFunc();
}

function toggleSubmenu(el, e) {
    if (e) e.stopPropagation();
    const sub = el.querySelector('.submenu-content');
    const isVisible = sub && sub.style.display === 'block';

    document.querySelectorAll('.submenu-content').forEach(s => s.style.display = 'none');

    if (!isVisible && sub) {
        sub.style.display = 'block';
    }
}

async function acquireLock(noteId, override = false) {
    try {
        const res = await fetch(`/api/lock/${noteId}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ client_id: myClientId, action: override ? 'override' : 'acquire' })
        });
        const data = await res.json();
        if (data.status === 'acquired') {
            currentLockedNote = noteId;
            startHeartbeat(noteId);
            return true;
        }
    } catch(e) { 
        console.error("Lock-Fehler:", e); 
    }
    return false;
}

async function releaseLock() {
    if (!currentLockedNote) return;
    let nidToRelease = currentLockedNote;
    currentLockedNote = null; 
    
    if (lockInterval) { 
        clearInterval(lockInterval); 
        lockInterval = null; 
    }
    try {
        await fetch(`/api/lock/${nidToRelease}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ client_id: myClientId, action: 'release' })
        });
    } catch(e) { 
        console.error(e); 
    }
}

function startHeartbeat(noteId) {
    if (lockInterval) clearInterval(lockInterval);
    
    lockInterval = setInterval(async () => {
        try {
            const res = await fetch(`/api/lock/${noteId}`, {
                method: 'POST', 
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ client_id: myClientId, action: 'heartbeat' })
            });
            const data = await res.json();
            
            if (data.status === 'lost') {
                if (lockInterval) clearInterval(lockInterval);
                lockInterval = null;
                currentLockedNote = null;
                
                showModal("Sperre verloren!", "Ein anderes Gerät hat die Bearbeitung erzwungen und diese Notiz übernommen.", [
                    { label: "Verstanden", class: "btn-cancel", action: () => { 
                        cancelEdit(); 
                        if (document.getElementById('sketch-modal').style.display === 'flex') closeSketch();
                        if (document.getElementById('history-modal').style.display === 'flex') document.getElementById('history-modal').style.display = 'none';
                    }}
                ]);
            }
        } catch(e) { 
            console.error(e); 
        }
    }, 5000); 
}

window.addEventListener('beforeunload', () => {
    if (currentLockedNote) {
        const blob = new Blob([JSON.stringify({ client_id: myClientId, action: 'release' })], { type: 'application/json' });
        navigator.sendBeacon(`/api/lock/${currentLockedNote}`, blob);
    }
});

async function loadContacts() {
    try {
        const res = await fetch('/api/contacts');
        if (res.ok) {
            contactsCache = await res.json();
        }
    } catch(e) { console.error("Kontakte laden:", e); }
}

async function updateBadges() {
    try {
        const resT = await fetch('/api/todos');
        if (resT.ok) {
            currentTodosList = await resT.json();
            const openTasks = currentTodosList.filter(t => !t.checked).length;
            const badge = document.getElementById('todo-badge');
            if (openTasks > 0) {
                badge.innerText = openTasks;
                badge.style.display = 'inline-block';
            } else {
                badge.style.display = 'none';
            }
        }
        
        const resTr = await fetch('/api/trash');
        if (resTr.ok) {
            const trashData = await resTr.json();
            const badge = document.getElementById('trash-badge');
            if (trashData.length > 0) {
                badge.innerText = trashData.length;
                badge.style.display = 'inline-block';
            } else {
                badge.style.display = 'none';
            }
        }
    } catch(e) {}
}

function updateNotificationBadge() {
    let overdueNotes = [];
    function findOverdue(nodes) {
        if (!Array.isArray(nodes)) return;
        nodes.forEach(n => {
            if (isReminderActive(n)) {
                overdueNotes.push(n);
            }
            if (n.children) findOverdue(n.children);
        });
    }
    findOverdue(fullTree.content);
    
    const badge = document.getElementById('notification-badge');
    if (badge) {
        if (overdueNotes.length > 0) {
            badge.innerText = overdueNotes.length;
            badge.style.display = 'inline-block';
        } else {
            badge.style.display = 'none';
        }
    }
    return overdueNotes;
}

function openNotificationsModal() {
    const overdueNotes = updateNotificationBadge();
    const listEl = document.getElementById('notifications-list');
    listEl.innerHTML = '';
    
    if (overdueNotes.length === 0) {
        listEl.innerHTML = '<p style="text-align:center; opacity:0.5; margin-top:20px;">Keine überfälligen Termine.</p>';
    } else {
        overdueNotes.forEach(n => {
            const div = document.createElement('div');
            div.style.display = 'flex';
            div.style.justifyContent = 'space-between';
            div.style.alignItems = 'center';
            div.style.padding = '10px';
            div.style.borderBottom = '1px solid var(--border-color)';
            
            const infoDiv = document.createElement('div');
            const titleA = document.createElement('a');
            titleA.href = '#';
            titleA.innerText = n.title || 'Unbenannt';
            titleA.style.color = 'var(--accent)';
            titleA.style.fontWeight = 'bold';
            titleA.style.textDecoration = 'none';
            titleA.onclick = (e) => {
                e.preventDefault();
                document.getElementById('notifications-modal').style.display = 'none';
                selectNode(n.id);
            };
            
            const timeSpan = document.createElement('div');
            timeSpan.style.fontSize = '0.8em';
            timeSpan.style.color = '#888';
            timeSpan.innerText = n.reminder.replace('T', ' ');
            
            infoDiv.appendChild(titleA);
            infoDiv.appendChild(timeSpan);
            
            const ackBtn = document.createElement('button');
            ackBtn.innerText = 'Bestätigen';
            ackBtn.style.background = '#e74c3c';
            ackBtn.style.color = 'white';
            ackBtn.style.padding = '5px 10px';
            ackBtn.style.borderRadius = '4px';
            ackBtn.style.fontSize = '0.8em';
            ackBtn.style.cursor = 'pointer';
            ackBtn.style.border = 'none';
            ackBtn.onclick = async () => {
                await clearReminderById(n.id);
                openNotificationsModal();
            };
            
            div.appendChild(infoDiv);
            div.appendChild(ackBtn);
            listEl.appendChild(div);
        });
    }
    
    document.getElementById('notifications-modal').style.display = 'flex';
}

async function clearReminderById(id) {
    try {
        const res = await fetch(`/api/notes/${id}`);
        if (res.ok) {
            const noteData = await res.json();
            noteData.reminder = null;
            noteData.client_id = myClientId;
            
            const putRes = await fetch(`/api/notes/${id}`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(noteData)
            });
            
            if (putRes.status === 403) {
                showModal("Gesperrt", "Diese Erinnerung kann nicht bestätigt werden, da die Notiz gerade bearbeitet wird.", [{ label: "Verstanden", class: "btn-cancel", action: () => {} }]);
                return;
            }
            
            if (id === activeId && activeNoteData) {
                activeNoteData.reminder = null;
                const editRemBtnText = document.getElementById('edit-reminder-text');
                const editRemClearBtn = document.getElementById('edit-reminder-clear');
                if(editRemBtnText) editRemBtnText.innerText = 'Erinnerung';
                if(editRemClearBtn) editRemClearBtn.style.display = 'none';
            }
            
            await checkAndReloadData();
            if (activeId === id && document.getElementById('view-mode').style.display === 'block') {
                renderDisplayArea();
            }
        }
    } catch(e) {
        console.error(e);
    }
}

function updateToggleAllIcon() {
    const btn = document.getElementById('toggle-all-btn');
    if (!btn) return;
    
    let totalFolders = 0;
    function countFolders(items) { 
        if (!Array.isArray(items)) return;
        items.forEach(i => { 
            if (i.children && i.children.length > 0) { 
                totalFolders++; 
                countFolders(i.children); 
            } 
        }); 
    }
    countFolders(fullTree.content);
    
    if (totalFolders === 0) {
        btn.innerHTML = '<i class="icon icon-folder_open"></i>';
        btn.title = "Alle aufklappen";
        return;
    }

    if (collapsedIds.size >= totalFolders / 2) { 
        btn.innerHTML = '<i class="icon icon-folder_open"></i>';
        btn.title = "Alle aufklappen";
    } else { 
        btn.innerHTML = '<i class="icon icon-folder"></i>';
        btn.title = "Alle zuklappen";
    }
}

async function checkAndReloadData() {
    try {
        const res = await fetch('/api/tree?_t=' + Date.now());
        if (!res.ok) return;
        
        const data = await res.json();
        const serverMod = String(data.last_modified);
        const localMod = String(currentTreeLastMod);
        
        if (currentTreeLastMod === null || serverMod !== localMod) {
            currentTreeLastMod = data.last_modified;
            if (Array.isArray(data.content)) {
                fullTree.content = cleanDataArray(data.content);
            } else {
                fullTree.content = [];
            }
            
            fullTree.settings = data.settings || {};
            document.body.setAttribute('data-theme', fullTree.settings.theme || 'dark'); 
            applyAccentColor(fullTree.settings.accent || '#27ae60');
            updateMenuUI();
            updateNotificationBadge();
            
            if (!document.body.classList.contains('edit-mode-active')) {
                const term = document.getElementById('search-input').value.trim();
                if (term) {
                    filterTree();
                } else {
                    renderTree();
                }
            }
        }
        
        await updateBadges();
        await loadContacts();
        await loadAllTags();
        renderTagFilterBar();
        updateToggleAllIcon();

        if (activeId) {
            const editModeEl = document.getElementById('edit-mode');
            if (editModeEl && editModeEl.style.display !== 'block') {
                const freshData = await fetchNoteData(activeId);
                if (freshData) { 
                    activeNoteData = freshData; 
                    renderDisplayArea(); 
                }
            }
        }
    } catch (e) { 
        console.error("Sync error:", e); 
    }
}

async function fetchNoteData(id) {
    try {
        const res = await fetch(`/api/notes/${id}?_t=` + Date.now());
        if(res.ok) return await res.json();
    } catch(e) { 
        console.error(e); 
    }
    return null;
}

function cleanDataArray(arr) {
    if (!arr || !Array.isArray(arr)) return [];
    return arr.map(item => {
        if (!item) return null;
        return { ...item, children: cleanDataArray(item.children) };
    }).filter(item => item !== null);
}

async function loadData() { 
    const savedCollapsed = localStorage.getItem('collapsedNodes');
    if (savedCollapsed) {
        try { 
            collapsedIds = new Set(JSON.parse(savedCollapsed)); 
        } catch(e) { 
            collapsedIds = new Set(); 
        }
    }
    
    await checkAndReloadData();
    updateNotificationBadge();
    
    if (!savedCollapsed && fullTree.content.length > 0) {
        initAllCollapsed(fullTree.content);
    }
    
    renderTree(); 
    updateToggleAllIcon();
    
    const hash = window.location.hash;
    const hashMatch = hash.match(/^#note=(.+)$/);
    if (hashMatch && findNode(fullTree.content, hashMatch[1])) {
        history.replaceState({ noteId: hashMatch[1] }, '', hash);
        doSelectNode(hashMatch[1], true);
    } else {
        const lastId = localStorage.getItem('lastActiveId'); 
        if (lastId && findNode(fullTree.content, lastId)) {
            history.replaceState({ noteId: lastId }, '', '#note=' + lastId);
            doSelectNode(lastId, true);
        } else {
            history.replaceState({ noteId: null }, '', '#');
        }
    }
}

function initAllCollapsed(items) { 
    if (!Array.isArray(items)) return;
    items.forEach(item => { 
        if (item && item.children && item.children.length > 0) { 
            collapsedIds.add(item.id); 
            initAllCollapsed(item.children); 
        } 
    }); 
    saveCollapsedToLocal(); 
}

function saveCollapsedToLocal() { 
    localStorage.setItem('collapsedNodes', JSON.stringify(Array.from(collapsedIds))); 
}

function uploadWithProgress(file, onSuccess) {
    if (file.size > 50 * 1024 * 1024) { 
        showModal("Upload fehlgeschlagen", "Die ausgewählte Datei ist zu groß. Bitte wähle eine Datei mit maximal 50 MB aus.", [{ label: "Verstanden", class: "btn-cancel", action: () => {} }]); 
        return; 
    }
    
    const fd = new FormData(); 
    fd.append('file', file);
    
    const modal = document.getElementById('upload-modal');
    const bar = document.getElementById('upload-progress-bar');
    const percentTxt = document.getElementById('upload-percent');
    
    modal.style.display = 'flex';
    bar.style.width = '0%';
    percentTxt.innerText = '0%';
    
    const xhr = new XMLHttpRequest();
    xhr.open('POST', '/api/upload', true);
    
    xhr.upload.onprogress = function(e) {
        if (e.lengthComputable) {
            const percent = Math.round((e.loaded / e.total) * 100);
            bar.style.width = percent + '%';
            percentTxt.innerText = percent + '%';
        }
    };
    
    xhr.onload = function() {
        modal.style.display = 'none';
        if (xhr.status === 200) {
            const data = JSON.parse(xhr.responseText);
            onSuccess(data);
        } else {
            showModal("Fehler", "Der Upload ist leider fehlgeschlagen. Bitte versuche es noch einmal.", [{ label: "OK", class: "btn-cancel", action: () => {} }]); 
        }
    };
    
    xhr.onerror = function() {
        modal.style.display = 'none';
        showModal("Netzwerkfehler", "Upload wurde durch ein Netzwerkproblem abgebrochen.", [{ label: "OK", class: "btn-cancel", action: () => {} }]);
    };
    
    xhr.send(fd);
}

async function enableEdit() { 
    if (!activeId) return;
    activeNoteData = await fetchNoteData(activeId);
    if (!activeNoteData) { alert("Notiz nicht gefunden!"); return; }
    
    const locked = await acquireLock(activeId);
    if (!locked) {
        showModal("System gesperrt", "Diese Notiz wird aktuell von einem anderen Gerät oder Tab bearbeitet.\n\nMöchtest du die Sperre wirklich erzwingen? Achtung: Dabei könnten ungespeicherte Änderungen des anderen Nutzers überschrieben werden!", [
            { label: "Ja, Bearbeitung erzwingen", class: "btn-discard", action: async () => { await acquireLock(activeId, true); showEditArea(); } },
            { label: "Abbrechen", class: "btn-cancel", action: () => {} }
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
    if (!activeId || !activeNoteData) return;
    activeNoteData.title = document.getElementById('node-title').value; 
    activeNoteData.text = document.getElementById('node-text').value; 
    activeNoteData.client_id = myClientId; 
    
    try {
        const res = await fetch(`/api/notes/${activeId}`, { 
            method: 'PUT', 
            headers: { 'Content-Type': 'application/json' }, 
            body: JSON.stringify(activeNoteData) 
        });
        if (res.status === 403) {
            showModal("Speichern blockiert", "Dein Gerät hat die Sperre für diese Notiz verloren. Deine letzten Änderungen wurden NICHT gespeichert.", [{ label: "Verstanden", class: "btn-cancel", action: () => {} }]);
            return;
        }
    } catch(e) { 
        console.error(e); 
    }
    
    await releaseLock();
    await checkAndReloadData(); 
    renderDisplayArea();
}

function cancelEdit() { 
    releaseLock(); 
    renderDisplayArea(); 
}

function getContactById(id) {
    return contactsCache.find(c => c.id === id) || null;
}

function renderContactCardHTML(contact) {
    if (!contact) return '';
    let avatarHtml = '<i class="icon icon-contact"></i>';
    if (contact.image_filename) {
        avatarHtml = '<img src="/uploads/contacts/' + contact.image_filename + '?v=' + Date.now() + '">';
    }
    let detailParts = [];
    if (contact.phone_mobile) detailParts.push(contact.phone_mobile);
    if (contact.phone_landline) detailParts.push(contact.phone_landline);
    if (contact.email) detailParts.push(contact.email);
    if (contact.company) detailParts.push(contact.company);
    let detailHtml = detailParts.length > 0 ? '<div class="contact-card-inline-detail">' + detailParts.join(' · ') + '</div>' : '';
    let clickAttr = window.isShareView ? '' : ' onclick="openContactFromNote(\'' + contact.id + '\')" style="cursor:pointer;" title="Klick zum Bearbeiten"';
    return '<span class="contact-card-inline"' + clickAttr + '><span class="contact-avatar">' + avatarHtml + '</span><span class="contact-card-inline-info"><span class="contact-card-inline-name">' + (contact.name || 'Unbenannt') + '</span>' + detailHtml + '</span></span>';
}

async function openContactFromNote(contactId) {
    await loadContacts();
    editContact(contactId);
}

function renderMarkdown(text) { 
    if (!text) return ''; 
    let html = text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); 
    
    // Process deleted-tags BEFORE bold/italic to prevent underscores being eaten by _..._
    html = html.replace(/\[contact_deleted:([^\]]+)\]/g, '<span class="contact-deleted-inline"><i class="icon icon-contact"></i> Kontakt gelöscht ($1)</span>');
    html = html.replace(/\[media_deleted:([^\]]+)\]/g, '<span class="media-deleted-inline"><i class="icon icon-media"></i> Medium gelöscht ($1)</span>');

    let last = ""; 
    while (last !== html) { 
        last = html; 
        html = html.replace(/\[(#[0-9a-fA-F]{6})\]([\s\S]*?)\[\/#\]/g, '<span style="color:$1">$2</span>'); 
        html = html.replace(/\*\*(.*?)\*\*/g, '<b>$1</b>'); 
        html = html.replace(/_(.*?)_/g, '<i>$1</i>'); 
        html = html.replace(/~~(.*?)~~/g, '<s>$1</s>'); 
    } 

    html = html.replace(/\[img:(.*?)\]/g, '<img src="/uploads/$1" class="note-img" onclick="openLightbox(this.src)">');
    html = html.replace(/\[sketch:([a-zA-Z0-9]+)\]/g, '<img src="/uploads/sketch_$1.png?v='+Date.now()+'" class="note-img sketch-img" title="Skizze bearbeiten" onclick="openSketch(\'$1\')">');
    html = html.replace(/\[file:([a-zA-Z0-9.\-]+)\|([^\]]+)\]/g, '<a href="/api/download/$1" class="note-link"><i class="icon icon-file"></i> $2</a>');
    html = html.replace(/\[audio:(.*?)\]/g, '<audio controls src="/uploads/$1" style="max-width: 100%; margin: 10px 0; outline: none; border-radius: 5px;"></audio>');
    
    html = html.replace(/\[contact:([a-zA-Z0-9]+)\]/g, function(match, cid) {
        const contact = getContactById(cid);
        if (contact) return renderContactCardHTML(contact);
        return '<span class="contact-deleted-inline"><i class="icon icon-contact"></i> Kontakt nicht gefunden</span>';
    });
    
    html = html.replace(/\[note:([a-zA-Z0-9]+)\|([^\]]+)\]/g, (match, id, title) => `<a href="#" onclick="if(!window.isShareView){selectNode('${id}'); return false;}" class="note-link"><i class="icon icon-mention"></i> ${title}</a>`);
    html = html.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer" style="color:var(--accent); text-decoration:underline;">$1</a>');
    html = html.replace(/\[s=(.*?)\]\n?([\s\S]*?)\n?\[\/s\]/g, '<details class="spoiler"><summary>$1</summary><div class="spoiler-content">$2</div></details>');

    let tableRegex = /((?:\|[^\n]+\|\n?)+)/g;
    html = html.replace(tableRegex, function(match) {
        let rows = match.trim().split('\n');
        let table = '<table class="md-table">';
        let isHeader = true;
        for(let r of rows) {
            r = r.trim();
            if(r.match(/^\|[-:| ]+\|$/)) { isHeader = false; continue; }
            let cells = r.split('|').map(c=>c.trim());
            cells.shift(); cells.pop();
            if (cells.length === 0) continue;
            table += '<tr>' + cells.map(c => isHeader ? `<th>${c}</th>` : `<td>${c}</td>`).join('') + '</tr>';
        }
        table += '</table>';
        return table;
    });
    
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
                if (t.startsWith('<table') || t.startsWith('</table') || t.startsWith('<tr') || t.startsWith('</tr') || t.startsWith('<td') || t.startsWith('</th') || t.startsWith('</th')) return line;
                
                if (t === '') return '<br>'; 
                if (t === '---') return '<hr>';
                if (t.startsWith('### ')) return '<h3>' + line.substring(4) + '</h3>'; 
                if (t.startsWith('## ')) return '<h2>' + line.substring(3) + '</h2>'; 
                if (t.startsWith('# ')) return '<h1>' + line.substring(2) + '</h1>';
                
                if (t.startsWith('&gt; ')) return '<blockquote>' + line.substring(line.indexOf('&gt; ') + 5) + '</blockquote>'; 
                
                if (t.startsWith('- [ ] ')) { 
                    let idx = window.taskIndexCounter++; 
                    let dis = window.isShareView ? 'disabled' : `onclick="toggleTask(${idx}, false)"`;
                    return '<div class="task-list-item"><input type="checkbox" class="task-check" ' + dis + '> <span>' + line.substring(line.indexOf('- [ ] ') + 6) + '</span></div>'; 
                }
                if (t.startsWith('- [x] ') || t.startsWith('- [X] ')) { 
                    let idx = window.taskIndexCounter++; 
                    let dis = window.isShareView ? 'disabled' : `onclick="toggleTask(${idx}, true)"`;
                    return '<div class="task-list-item"><input type="checkbox" class="task-check" checked ' + dis + '> <span><del>' + line.substring(line.indexOf('] ') + 2) + '</del></span></div>'; 
                }
                
                if (t.startsWith('- ')) return '<div style="margin-left: 20px;">• ' + line.substring(line.indexOf('- ')+2) + '</div>'; 
                
                return '<div>' + line + '</div>';
            }).join(''); 
        } 
    } 
    return res; 
}

function renderDisplayArea() {
    if (!activeNoteData) return;
    
    document.getElementById('view-title').innerText = activeNoteData.title || 'Unbenannt'; 
    document.getElementById('display-area').innerHTML = renderMarkdown(activeNoteData.text); 
    
    if(window.hljs) {
        hljs.highlightAll(); 
    }

    updatePinMenuText();

    const viewTagsEl = document.getElementById('view-tags');
    if (viewTagsEl) {
        const node = findNode(fullTree.content, activeId);
        if (node && node.tags && node.tags.length > 0) {
            viewTagsEl.innerHTML = '';
            node.tags.forEach(t => {
                const chip = document.createElement('span');
                chip.className = 'tag-chip';
                chip.style.background = t.color;
                chip.innerText = t.name;
                viewTagsEl.appendChild(chip);
            });
            viewTagsEl.style.display = 'flex';
        } else {
            viewTagsEl.innerHTML = '';
            viewTagsEl.style.display = 'none';
        }
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
    
    const menuRowHistory = document.getElementById('menu-row-history');
    if (menuRowHistory) {
        menuRowHistory.style.display = (fullTree.settings.history_enabled) ? 'flex' : 'none';
    }
    
    fetch(`/api/notes/${activeId}/backlinks`).then(r => r.json()).then(bl => {
        if (bl && bl.length > 0 && activeId === activeNoteData.id) {
            let blHtml = '<div style="margin-top:40px; padding-top:15px; border-top:1px dashed var(--border-color); color:#888;"><strong><i class="icon icon-link"></i> Wird erwähnt in:</strong><br><div style="margin-top:8px;">';
            bl.forEach(b => {
                blHtml += `<a href="#" onclick="selectNode('${b.id}'); return false;" class="note-link"><i class="icon icon-mention"></i> ${b.title}</a> `;
            });
            blHtml += '</div></div>';
            document.getElementById('display-area').innerHTML += blHtml;
        }
    }).catch(e => console.error(e));
}

async function selectNode(id, fromPopState) { 
    if (document.getElementById('edit-mode').style.display === 'block') {
        if (activeNoteData && (document.getElementById('node-title').value !== activeNoteData.title || document.getElementById('node-text').value !== activeNoteData.text)) { 
            showModal("Ungespeicherte Änderungen", "Du hast diese Notiz bearbeitet, aber noch nicht gespeichert. Möchtest du deine Änderungen jetzt speichern?", [ 
                { label: "Ja, speichern", class: "btn-save", action: async () => { await saveChanges(); doSelectNode(id, fromPopState); } }, 
                { label: "Nein, verwerfen", class: "btn-discard", action: () => { cancelEdit(); doSelectNode(id, fromPopState); } }, 
                { label: "Abbruch", class: "btn-cancel", action: () => {} } 
            ]); 
            return; 
        } 
    }
    doSelectNode(id, fromPopState);
}

async function doSelectNode(id, fromPopState) {
    activeId = id; 
    localStorage.setItem('lastActiveId', id); 
    
    activeNoteData = await fetchNoteData(id);
    if (!activeNoteData) return;
    
    document.getElementById('no-selection').style.display = 'none'; 
    document.getElementById('edit-area').style.display = 'block'; 

    if (!fromPopState) {
        history.pushState({ noteId: id }, '', '#note=' + id);
    }
    
    const pathData = getPath(fullTree.content, id) || []; 
    const breadcrumbEl = document.getElementById('breadcrumb'); 
    breadcrumbEl.innerHTML = '';
    
    pathData.forEach((p, idx) => { 
        const span = document.createElement('span'); 
        span.innerText = p.title || 'Unbenannt'; 
        span.style.cursor = 'pointer'; 
        span.onclick = () => selectNode(p.id);
        span.onmouseover = () => span.style.textDecoration = 'underline';
        span.onmouseout = () => span.style.textDecoration = 'none';
        
        breadcrumbEl.appendChild(span); 
        if(idx < pathData.length - 1) breadcrumbEl.appendChild(document.createTextNode(' / ')); 
    });
    
    renderDisplayArea();
    
    document.querySelectorAll('.tree-item').forEach(el => el.classList.remove('active')); 
    const activeEl = document.querySelector(`.tree-item-container[data-id="${id}"] > .tree-item`); 
    if(activeEl) activeEl.classList.add('active'); 
}

function toggleEditMode() { 
    if (!document.body.classList.contains('edit-mode-active')) { 
        document.body.classList.add('edit-mode-active'); 
        renderTree(); 
    } else { 
        document.body.classList.remove('edit-mode-active'); 
        sortables.forEach(s => s.destroy()); 
        sortables = []; 
        renderTree(); 
    }
}

async function rebuildDataFromDOM() { 
    if (!document.body.classList.contains('edit-mode-active')) return;
    let flatUpdates = [];
    
    function parse(container, parentId) { 
        Array.from(container.querySelectorAll(':scope > .tree-item-container')).forEach((div, index) => { 
            const id = div.getAttribute('data-id'); 
            if (id) { 
                flatUpdates.push({ id: id, parent_id: parentId, sort_order: index }); 
                const sub = div.querySelector(':scope > .tree-group'); 
                if(sub) parse(sub, id); 
            }
        }); 
    } 
    
    const rg = document.querySelector('#tree > .tree-group'); 
    if(rg) { 
        parse(rg, null); 
        try { 
            await fetch('/api/tree', { 
                method: 'POST', 
                headers: { 'Content-Type': 'application/json' }, 
                body: JSON.stringify(flatUpdates) 
            }); 
            await checkAndReloadData(); 
        } catch(e) { 
            console.error("Fehler:", e); 
        }
    } 
}

window.toggleTask = async function(targetIdx, currentlyChecked) {
    if (window.isShareView) return;
    if (!await acquireLock(activeId)) { 
        showModal("Gesperrt", "Diese Aufgabe kann momentan nicht abgehakt werden, da die Notiz von einem anderen Gerät bearbeitet wird.", [{ label: "Verstanden", class: "btn-cancel", action: () => {} }]); 
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
                if (currentlyChecked) lines[i] = lines[i].replace(/- \[[xX]\] /, '- [ ] ');
                else lines[i] = lines[i].replace(/- \[ \] /, '- [x] ');
                break; 
            } 
            tIndex++;
        }
    }
    
    activeNoteData.text = lines.join('\n'); 
    activeNoteData.client_id = myClientId; 
    
    try {
        const res = await fetch(`/api/notes/${activeId}`, { 
            method: 'PUT', 
            headers: { 'Content-Type': 'application/json' }, 
            body: JSON.stringify(activeNoteData) 
        });
        if (res.status === 403) alert("Gesperrt");
    } catch(e) { 
        console.error(e); 
    }
    await releaseLock();
    updateBadges(); 
    renderDisplayArea();
};

function hasActiveReminder(node) {
    try {
        if (!node) return false;
        if (isReminderActive(node)) return true;
        if (node.children && Array.isArray(node.children)) {
            for (let i = 0; i < node.children.length; i++) { 
                if (hasActiveReminder(node.children[i])) return true; 
            }
        }
    } catch(e) { 
        console.error(e); 
    }
    return false;
}

function isReminderActive(node) { 
    try {
        if (!node || !node.reminder) return false;
        const remDate = new Date(node.reminder);
        if (isNaN(remDate.getTime())) return false;
        return remDate <= new Date();
    } catch(e) { 
        return false; 
    }
}

function renderItems(items, parent) { 
    if (!Array.isArray(items)) return;
    const isEdit = document.body.classList.contains('edit-mode-active'); 
    const searchTerm = document.getElementById('search-input').value.trim();

    items.forEach(item => { 
        if (!item || !item.id) return;
        
        const isFolder = item.children && item.children.length > 0; 
        
        let isCollapsed = false;
        if (!isEdit) {
            if (searchTerm !== '') {
                isCollapsed = collapsedIds.has(item.id);
            } else {
                isCollapsed = collapsedIds.has(item.id);
            }
        }
        
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
            icon.innerHTML = isCollapsed ? '<i class="icon icon-folder" style="color: #f39c12;"></i>' : '<i class="icon icon-folder_open" style="color: #f39c12;"></i>';
        } else {
            icon.innerHTML = '<i class="icon icon-file"></i>';
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
                
                if (searchTerm !== '') {
                    filterTree();
                } else {
                    renderTree(); 
                    updateToggleAllIcon();
                }
            } 
        }; 
        
        const text = document.createElement('span'); 
        text.className = 'tree-text'; 
        text.innerText = item.title || 'Unbenannt'; 
        
        if (hasActiveReminder(item)) { 
            const rSpan = document.createElement('span'); 
            rSpan.className = 'reminder-icon'; 
            rSpan.innerHTML = '<i class="icon icon-reminder_active"></i>'; 
            text.appendChild(rSpan); 
        }

        if (item.is_pinned) {
            const pinSpan = document.createElement('span');
            pinSpan.className = 'pin-indicator';
            pinSpan.innerHTML = '<i class="icon icon-pin"></i>';
            text.appendChild(pinSpan);
        }

        if (item.tags && item.tags.length > 0) {
            const maxDots = 3;
            const shown = item.tags.slice(0, maxDots);
            shown.forEach(t => {
                const dot = document.createElement('span');
                dot.className = 'tag-chip-small';
                dot.style.background = t.color;
                dot.title = t.name;
                text.appendChild(dot);
            });
            if (item.tags.length > maxDots) {
                const more = document.createElement('span');
                more.className = 'tag-overflow';
                more.innerText = '+' + (item.tags.length - maxDots);
                more.title = item.tags.slice(maxDots).map(t => t.name).join(', ');
                text.appendChild(more);
            }
        }
        
        text.onclick = (e) => { 
            e.stopPropagation(); 
            if (!isEdit) selectNode(item.id); 
        }; 
        
        const addBtn = document.createElement('button'); 
        addBtn.className = 'add-sub-btn'; 
        addBtn.innerHTML = '<i class="icon icon-add"></i>'; 
        addBtn.onclick = (e) => { 
            e.stopPropagation(); 
            addItem(item.id); 
        }; 
        
        const delBtn = document.createElement('button'); 
        delBtn.className = 'delete-btn'; 
        delBtn.innerHTML = '<i class="icon icon-clear"></i>'; 
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

function renderTree() { 
    const container = document.getElementById('tree'); 
    if (!container) return;
    
    container.innerHTML = ''; 
    const rootGroup = document.createElement('div'); 
    rootGroup.className = 'tree-group'; 
    container.appendChild(rootGroup); 
    
    let itemsToRender = fullTree.content;
    
    if (activeTagFilters.size > 0) {
        function hasAnyTag(node, tagIds) {
            if (node.tags && node.tags.some(t => tagIds.has(t.id))) return true;
            if (node.children) {
                for (let c of node.children) { if (hasAnyTag(c, tagIds)) return true; }
            }
            return false;
        }
        function filterByTags(items) {
            let result = [];
            items.forEach(item => {
                if (hasAnyTag(item, activeTagFilters)) {
                    let filtered = { ...item, children: filterByTags(item.children || []) };
                    result.push(filtered);
                }
            });
            return result;
        }
        itemsToRender = filterByTags(fullTree.content);
    }
    
    renderItems(itemsToRender, rootGroup); 
    
    if (document.body.classList.contains('edit-mode-active')) {
        initSortables(); 
    }
}

function openReminderModal() {
    if(!activeNoteData) return;
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
    document.getElementById('reminder-date').style.display = hasTime ? 'none' : 'block'; 
    document.getElementById('reminder-datetime').style.display = hasTime ? 'block' : 'none';
}

async function saveReminder() {
    if(!activeNoteData) return;
    const hasTime = document.getElementById('reminder-has-time').checked; 
    let val = hasTime ? document.getElementById('reminder-datetime').value : document.getElementById('reminder-date').value;
    
    if(val) { 
        activeNoteData.reminder = val; 
        activeNoteData.client_id = myClientId; 
        
        document.getElementById('reminder-modal').style.display = 'none'; 
        
        const res = await fetch(`/api/notes/${activeId}`, { 
            method: 'PUT', 
            headers: { 'Content-Type': 'application/json' }, 
            body: JSON.stringify(activeNoteData) 
        }); 
        
        if (res.status === 403) {
            activeNoteData.reminder = null;
            showModal("Gesperrt", "Erinnerung konnte nicht gespeichert werden, da die Notiz gerade von einem anderen Gerät bearbeitet wird.", [{ label: "Verstanden", class: "btn-cancel", action: () => {} }]);
            return;
        }
        
        await checkAndReloadData(); 
        renderDisplayArea(); 
    }
}

async function clearReminder() { 
    if(activeNoteData && activeNoteData.reminder) { 
        const oldReminder = activeNoteData.reminder;
        activeNoteData.reminder = null; 
        activeNoteData.client_id = myClientId; 
        
        const res = await fetch(`/api/notes/${activeId}`, { 
            method: 'PUT', 
            headers: { 'Content-Type': 'application/json' }, 
            body: JSON.stringify(activeNoteData) 
        }); 
        
        if (res.status === 403) {
            activeNoteData.reminder = oldReminder;
            showModal("Gesperrt", "Erinnerung konnte nicht gelöscht werden, da die Notiz gerade von einem anderen Gerät bearbeitet wird.", [{ label: "Verstanden", class: "btn-cancel", action: () => {} }]);
            return;
        }
        
        await checkAndReloadData(); 
        renderDisplayArea(); 
    } 
}

async function shareNote() {
    if (!activeId) return;
    try {
        const res = await fetch(`/api/notes/${activeId}/share`, {method: 'POST'});
        const data = await res.json();
        if (data.url) {
            showModal("Lese-Link erfolgreich generiert", `Hier ist dein öffentlicher Link:\n\n${data.url}\n\nJeder, der diesen Link besitzt, kann den aktuellen Stand dieser Notiz im reinen Lesemodus betrachten. Der Link bleibt so lange aktiv, bis du die Freigabe manuell wieder aufhebst.`, [
                { label: "Link kopieren", class: "btn-save", action: () => { copyText(data.url); } },
                { label: "Freigabe sofort aufheben", class: "btn-discard", action: async () => { await fetch(`/api/notes/${activeId}/unshare`, {method: 'POST'}); } },
                { label: "Schließen", class: "btn-cancel", action: () => {} }
            ]);
        }
    } catch(e) { console.error(e); }
}

async function openShareOverviewModal() {
    document.getElementById('share-overview-modal').style.display = 'flex';
    const list = document.getElementById('share-list');
    list.innerHTML = 'Lade Freigaben...';
    try {
        const res = await fetch('/api/shares');
        const data = await res.json();
        
        if(data.length === 0) { 
            list.innerHTML = '<p style="opacity:0.5;text-align:center;">Es gibt aktuell keine aktiven Freigabe-Links in deinem System.</p>'; 
            return; 
        }
        
        list.innerHTML = '';
        data.forEach(s => {
            const d = document.createElement('div');
            d.style = "display:flex; justify-content:space-between; align-items:center; padding:10px; border-bottom:1px solid var(--border-color);";
            
            const link = document.createElement('a');
            link.href = '/share/' + s.share_id;
            link.target = '_blank';
            link.style.color = 'var(--accent)';
            link.style.textDecoration = 'none';
            link.innerText = s.title || 'Unbenannt';
            
            const btn = document.createElement('button');
            btn.innerText = "Freigabe aufheben"; 
            btn.className = "btn-discard"; 
            btn.style.padding = "5px 10px";
            btn.onclick = async () => {
                await fetch(`/api/notes/${s.id}/unshare`, {method:'POST'});
                openShareOverviewModal(); 
            };
            
            d.appendChild(link); 
            d.appendChild(btn); 
            list.appendChild(d);
        });
    } catch(e) {
        list.innerHTML = 'Fehler beim Laden der Übersicht.';
    }
}

async function openTodoModal() {
    document.getElementById('todo-modal').style.display = 'flex';
    const list = document.getElementById('todo-list');
    list.innerHTML = 'Lade Aufgaben...';
    
    try {
        const res = await fetch('/api/todos');
        currentTodosList = await res.json();
        renderTodoList();
    } catch(e) {
        list.innerHTML = 'Fehler beim Laden der Aufgaben.';
    }
}

function renderTodoList() {
    const list = document.getElementById('todo-list');
    const showAll = document.getElementById('todo-show-all').checked;
    list.innerHTML = '';
    
    const filteredTodos = showAll ? currentTodosList : currentTodosList.filter(t => !t.checked);
    
    if(filteredTodos.length === 0) { 
        list.innerHTML = '<p style="opacity:0.5;text-align:center;">' + (showAll ? 'Es wurden keine Aufgaben in deinen Notizen gefunden.' : 'Glückwunsch! Alle aktuellen Aufgaben sind erledigt.') + '</p>'; 
        return; 
    }
    
    filteredTodos.forEach(t => {
        const d = document.createElement('div');
        d.style = "display:flex; align-items:flex-start; gap:10px; padding:10px; border-bottom:1px solid var(--border-color);";
        
        const cb = document.createElement('input');
        cb.type = 'checkbox'; 
        cb.className = 'task-check'; 
        cb.checked = t.checked;
        cb.onclick = async (e) => {
            e.preventDefault();
            await fetch('/api/todos/toggle', {
                method: 'POST', headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({note_id: t.note_id, task_index: t.task_index})
            });
            updateBadges(); 
            if (activeId === t.note_id && activeNoteData && document.getElementById('edit-mode').style.display !== 'block') {
                activeNoteData = await fetchNoteData(activeId);
                renderDisplayArea();
            }
            openTodoModal(); 
        };
        
        const info = document.createElement('div');
        const txt = document.createElement('div');
        if(t.checked) {
            txt.innerHTML = `<s>${t.text}</s>`;
            txt.style.opacity = '0.5';
        } else {
            txt.innerText = t.text;
        }
        
        const link = document.createElement('a');
        link.href = "#"; 
        link.style = "font-size:0.8em; color:var(--accent); text-decoration:none;";
        link.innerText = "Aus Notiz: " + t.note_title;
        link.onclick = (e) => { 
            e.preventDefault(); 
            document.getElementById('todo-modal').style.display = 'none'; 
            selectNode(t.note_id); 
        };
        
        info.appendChild(txt); 
        info.appendChild(link);
        d.appendChild(cb); 
        d.appendChild(info);
        list.appendChild(d);
    });
}

async function openMediaModal() {
    document.getElementById('media-modal').style.display = 'flex';
    renderMediaList();
}

async function renderMediaList() {
    const list = document.getElementById('media-list');
    list.innerHTML = 'Lade Medien...';
    try {
        const res = await fetch('/api/media');
        const data = await res.json();
        
        if (data.length === 0) {
            list.innerHTML = '<p style="opacity:0.5; grid-column: 1 / -1; text-align:center;">Noch keine Dateien hochgeladen.</p>';
            return;
        }
        
        list.innerHTML = '';
        data.forEach(m => {
            const dt = new Date(m.uploaded_at * 1000).toLocaleString('de-DE');
            
            const card = document.createElement('div');
            card.style = "background: rgba(255,255,255,0.05); border: 1px solid var(--border-color); border-radius: 8px; padding: 10px; display: flex; flex-direction: column; gap: 10px;";
            
            const preview = document.createElement('div');
            preview.style = "height: 120px; display: flex; align-items: center; justify-content: center; background: rgba(0,0,0,0.2); border-radius: 4px; overflow: hidden; cursor: pointer;";
            
            if (m.file_type === 'image' || m.file_type === 'sketch') {
                let v = Date.now();
                preview.innerHTML = `<img src="/uploads/${m.filename}?v=${v}" style="max-width: 100%; max-height: 100%; object-fit: contain;">`;
                preview.onclick = () => openLightbox(`/uploads/${m.filename}?v=${v}`);
            } else if (m.file_type === 'audio') {
                preview.innerHTML = `<i class="icon icon-mic" style="font-size: 3em; opacity: 0.5;"></i>`;
            } else {
                preview.innerHTML = `<i class="icon icon-file" style="font-size: 3em;"></i>`;
            }
            
            const nameDiv = document.createElement('div');
            nameDiv.style = "font-size: 0.85em; word-break: break-all; font-weight: bold; margin-top: 5px;";
            nameDiv.innerText = m.original_name || m.filename;
            
            const dateDiv = document.createElement('div');
            dateDiv.style = "font-size: 0.75em; color: #888;";
            dateDiv.innerText = dt;
            
            const actionDiv = document.createElement('div');
            actionDiv.style = "display: flex; gap: 5px; margin-top: auto; justify-content: space-between;";
            
            const btnOpen = document.createElement('button');
            btnOpen.className = "tool-btn";
            btnOpen.title = "Im Browser ansehen";
            btnOpen.innerHTML = `<i class="icon icon-search"></i>`;
            btnOpen.onclick = () => { window.open(`/uploads/${m.filename}`, '_blank'); };
            
            const btnDownload = document.createElement('button');
            btnDownload.className = "tool-btn";
            btnDownload.title = "Herunterladen";
            btnDownload.innerHTML = `<i class="icon icon-export"></i>`;
            btnDownload.onclick = () => { window.location.href = `/api/download/${m.filename}`; };
            
            const btnInfo = document.createElement('button');
            btnInfo.className = "tool-btn";
            btnInfo.title = "Info / Verwendungen";
            btnInfo.innerHTML = `<i class="icon icon-link"></i>`;
            btnInfo.onclick = () => showMediaInfo(m.filename);
            
            const btnDelete = document.createElement('button');
            btnDelete.className = "tool-btn";
            btnDelete.title = "Löschen";
            btnDelete.style.borderColor = "#e74c3c";
            btnDelete.style.color = "#e74c3c";
            btnDelete.innerHTML = `<i class="icon icon-trash"></i>`;
            btnDelete.onclick = () => deleteMedia(m.filename, m.original_name);
            
            actionDiv.appendChild(btnOpen);
            actionDiv.appendChild(btnDownload);
            actionDiv.appendChild(btnInfo);
            actionDiv.appendChild(btnDelete);
            
            card.appendChild(preview);
            card.appendChild(nameDiv);
            card.appendChild(dateDiv);
            card.appendChild(actionDiv);
            list.appendChild(card);
        });
        
    } catch(e) {
        list.innerHTML = 'Fehler beim Laden der Medien.';
    }
}

async function showMediaInfo(filename) {
    document.getElementById('media-info-modal').style.display = 'flex';
    const list = document.getElementById('media-info-list');
    list.innerHTML = 'Lade Verknüpfungen...';
    
    try {
        const res = await fetch(`/api/media/${filename}/refs`);
        const data = await res.json();
        
        if (data.length === 0) {
            list.innerHTML = '<p style="opacity:0.5; text-align:center;">Wird in keinen aktiven Notizen verwendet.</p>';
            return;
        }
        
        list.innerHTML = '';
        data.forEach(n => {
            const d = document.createElement('div');
            d.style = "padding:10px; border-bottom:1px solid var(--border-color);";
            const link = document.createElement('a');
            link.href = '#';
            link.style.color = 'var(--accent)';
            link.style.textDecoration = 'none';
            link.innerText = n.title || 'Unbenannt';
            link.onclick = (e) => {
                e.preventDefault();
                document.getElementById('media-info-modal').style.display = 'none';
                document.getElementById('media-modal').style.display = 'none';
                selectNode(n.id);
            };
            d.appendChild(link);
            list.appendChild(d);
        });
    } catch(e) {
        list.innerHTML = 'Fehler beim Laden.';
    }
}

function deleteMedia(filename, original_name) {
    showModal("Medium komplett löschen", `Möchtest du die Datei "${original_name}" wirklich löschen?\n\nDie Datei wird vom Server gelöscht und restlos aus allen Notizen und der Historie entfernt. Dies kann nicht rückgängig gemacht werden!`, [
        { label: "Ja, löschen", class: "btn-discard", action: async () => {
            await fetch(`/api/media/${filename}`, { method: 'DELETE' });
            renderMediaList();
            if (activeId && document.getElementById('edit-mode').style.display !== 'block') {
                activeNoteData = await fetchNoteData(activeId);
                renderDisplayArea();
            }
        }},
        { label: "Abbrechen", class: "btn-cancel", action: () => {} }
    ]);
}

// --- CONTACTS FUNCTIONS ---
async function openContactsModal() {
    document.getElementById('contacts-modal').style.display = 'flex';
    await loadContacts();
    renderContactsList();
}

function renderContactsList() {
    const list = document.getElementById('contacts-list');
    list.innerHTML = '';
    
    if (contactsCache.length === 0) {
        list.innerHTML = '<p style="opacity:0.5; grid-column: 1 / -1; text-align:center;">Noch keine Kontakte angelegt.</p>';
        return;
    }
    
    contactsCache.forEach(c => {
        const tile = document.createElement('div');
        tile.className = 'contact-tile';
        
        const avatar = document.createElement('div');
        avatar.className = 'contact-avatar';
        if (c.image_filename) {
            avatar.innerHTML = '<img src="/uploads/contacts/' + c.image_filename + '?v=' + Date.now() + '">';
        } else {
            const initials = (c.name || '?').split(' ').map(w => w.charAt(0).toUpperCase()).join('').substring(0, 2);
            avatar.innerText = initials;
            avatar.style.fontWeight = 'bold';
        }
        
        const name = document.createElement('div');
        name.className = 'contact-tile-name';
        name.innerText = c.name || 'Unbenannt';
        
        const info = document.createElement('div');
        info.className = 'contact-tile-info';
        let infoParts = [];
        if (c.company) infoParts.push(c.company);
        if (c.phone_mobile) infoParts.push(c.phone_mobile);
        if (c.phone_landline) infoParts.push(c.phone_landline);
        if (c.email) infoParts.push(c.email);
        info.innerText = infoParts.join(' · ') || '';
        
        const actions = document.createElement('div');
        actions.className = 'contact-tile-actions';
        
        const btnEdit = document.createElement('button');
        btnEdit.className = 'tool-btn';
        btnEdit.title = 'Bearbeiten';
        btnEdit.innerHTML = '<i class="icon icon-sketch"></i>';
        btnEdit.onclick = () => editContact(c.id);
        
        const btnDelete = document.createElement('button');
        btnDelete.className = 'tool-btn';
        btnDelete.title = 'Löschen';
        btnDelete.style.borderColor = '#e74c3c';
        btnDelete.style.color = '#e74c3c';
        btnDelete.innerHTML = '<i class="icon icon-trash"></i>';
        btnDelete.onclick = () => deleteContact(c.id, c.name);
        
        actions.appendChild(btnEdit);
        actions.appendChild(btnDelete);
        
        tile.appendChild(avatar);
        tile.appendChild(name);
        tile.appendChild(info);
        tile.appendChild(actions);
        list.appendChild(tile);
    });
}

function openCreateContactForm() {
    document.getElementById('contact-form-id').value = '';
    document.getElementById('contact-form-name').value = '';
    document.getElementById('contact-form-phone-mobile').value = '';
    document.getElementById('contact-form-phone-landline').value = '';
    document.getElementById('contact-form-email').value = '';
    document.getElementById('contact-form-company').value = '';
    document.getElementById('contact-form-address').value = '';
    document.getElementById('contact-form-notes').value = '';
    document.getElementById('contact-form-title').innerText = 'Neuer Kontakt';
    document.getElementById('contact-avatar-preview').innerHTML = '<i class="icon icon-contact" style="font-size:1.2em;"></i>';
    document.getElementById('contact-form-modal').style.display = 'flex';
}

function editContact(contactId) {
    const c = getContactById(contactId);
    if (!c) return;
    
    document.getElementById('contact-form-id').value = c.id;
    document.getElementById('contact-form-name').value = c.name || '';
    document.getElementById('contact-form-phone-mobile').value = c.phone_mobile || '';
    document.getElementById('contact-form-phone-landline').value = c.phone_landline || '';
    document.getElementById('contact-form-email').value = c.email || '';
    document.getElementById('contact-form-company').value = c.company || '';
    document.getElementById('contact-form-address').value = c.address || '';
    document.getElementById('contact-form-notes').value = c.notes || '';
    document.getElementById('contact-form-title').innerText = 'Kontakt bearbeiten';
    
    const preview = document.getElementById('contact-avatar-preview');
    if (c.image_filename) {
        preview.innerHTML = '<img src="/uploads/contacts/' + c.image_filename + '?v=' + Date.now() + '" style="width:100%;height:100%;object-fit:cover;">';
    } else {
        preview.innerHTML = '<i class="icon icon-contact" style="font-size:1.2em;"></i>';
    }
    
    document.getElementById('contact-form-modal').style.display = 'flex';
}

async function saveContactForm() {
    const id = document.getElementById('contact-form-id').value;
    const data = {
        name: document.getElementById('contact-form-name').value,
        phone_mobile: document.getElementById('contact-form-phone-mobile').value,
        phone_landline: document.getElementById('contact-form-phone-landline').value,
        email: document.getElementById('contact-form-email').value,
        company: document.getElementById('contact-form-company').value,
        address: document.getElementById('contact-form-address').value,
        notes: document.getElementById('contact-form-notes').value
    };
    
    if (!data.name.trim()) {
        showModal("Fehler", "Bitte gib mindestens einen Namen ein.", [{ label: "OK", class: "btn-cancel", action: () => { document.getElementById('contact-form-modal').style.display = 'flex'; } }]);
        document.getElementById('contact-form-modal').style.display = 'none';
        return;
    }
    
    try {
        if (id) {
            await fetch(`/api/contacts/${id}`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(data)
            });
        } else {
            await fetch('/api/contacts', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(data)
            });
        }
        
        document.getElementById('contact-form-modal').style.display = 'none';
        await loadContacts();
        renderContactsList();
        if (activeId && activeNoteData && document.getElementById('edit-mode').style.display !== 'block') {
            renderDisplayArea();
        }
    } catch(e) {
        console.error(e);
    }
}

function uploadContactAvatar() {
    const contactId = document.getElementById('contact-form-id').value;
    if (!contactId) {
        showModal("Hinweis", "Bitte speichere den Kontakt zuerst, bevor du ein Bild hochlädst.", [{ label: "OK", class: "btn-cancel", action: () => { document.getElementById('contact-form-modal').style.display = 'flex'; } }]);
        document.getElementById('contact-form-modal').style.display = 'none';
        return;
    }
    
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = 'image/*';
    input.onchange = async (e) => {
        const file = e.target.files[0];
        if (!file) return;
        
        const fd = new FormData();
        fd.append('image', file);
        
        try {
            const res = await fetch(`/api/contacts/${contactId}/image`, { method: 'POST', body: fd });
            const data = await res.json();
            if (data.status === 'success') {
                const preview = document.getElementById('contact-avatar-preview');
                preview.innerHTML = '<img src="/uploads/contacts/' + data.filename + '?v=' + Date.now() + '" style="width:100%;height:100%;object-fit:cover;">';
                await loadContacts();
                renderContactsList();
            }
        } catch(err) {
            console.error(err);
        }
    };
    input.click();
}

function deleteContact(contactId, contactName) {
    showModal("Kontakt löschen", `Möchtest du den Kontakt "${contactName}" wirklich löschen?\n\nIn allen Notizen, in denen dieser Kontakt eingefügt ist, wird stattdessen "Kontakt gelöscht" angezeigt.`, [
        { label: "Ja, löschen", class: "btn-discard", action: async () => {
            await fetch(`/api/contacts/${contactId}`, { method: 'DELETE' });
            await loadContacts();
            renderContactsList();
            if (activeId && document.getElementById('edit-mode').style.display !== 'block') {
                activeNoteData = await fetchNoteData(activeId);
                renderDisplayArea();
            }
        }},
        { label: "Abbrechen", class: "btn-cancel", action: () => {} }
    ]);
}

async function openContactPicker() {
    await loadContacts();
    document.getElementById('contact-picker-modal').style.display = 'flex';
    renderContactPickerList();
}

function renderContactPickerList() {
    const list = document.getElementById('contact-picker-list');
    list.innerHTML = '';
    
    if (contactsCache.length === 0) {
        list.innerHTML = '<p style="opacity:0.5; grid-column: 1 / -1; text-align:center;">Noch keine Kontakte vorhanden. Erstelle zuerst einen Kontakt über "Verwalten".</p>';
        return;
    }
    
    contactsCache.forEach(c => {
        const tile = document.createElement('div');
        tile.className = 'contact-picker-tile';
        tile.onclick = () => {
            insertContactTag(c.id);
            document.getElementById('contact-picker-modal').style.display = 'none';
        };
        
        const avatar = document.createElement('div');
        avatar.className = 'contact-avatar';
        if (c.image_filename) {
            avatar.innerHTML = '<img src="/uploads/contacts/' + c.image_filename + '?v=' + Date.now() + '">';
        } else {
            const initials = (c.name || '?').split(' ').map(w => w.charAt(0).toUpperCase()).join('').substring(0, 2);
            avatar.innerText = initials;
            avatar.style.fontWeight = 'bold';
        }
        
        const name = document.createElement('div');
        name.className = 'contact-tile-name';
        name.innerText = c.name || 'Unbenannt';
        name.style.fontSize = '0.85em';
        
        let subInfo = '';
        if (c.company) subInfo = c.company;
        else if (c.phone_mobile) subInfo = c.phone_mobile;
        else if (c.phone_landline) subInfo = c.phone_landline;
        
        const info = document.createElement('div');
        info.className = 'contact-tile-info';
        info.innerText = subInfo;
        
        tile.appendChild(avatar);
        tile.appendChild(name);
        if (subInfo) tile.appendChild(info);
        list.appendChild(tile);
    });
}

function insertContactTag(contactId) {
    const ta = document.getElementById('node-text');
    if (!ta) return;
    const tag = `[contact:${contactId}]`;
    const s = ta.selectionStart;
    ta.value = ta.value.substring(0, s) + tag + ta.value.substring(ta.selectionEnd);
    ta.focus();
    ta.setSelectionRange(s + tag.length, s + tag.length);
}

// --- TRASH ---
async function openTrashModal() {
    document.getElementById('trash-modal').style.display = 'flex';
    const list = document.getElementById('trash-list');
    list.innerHTML = 'Lade Papierkorb...';
    
    try {
        const res = await fetch('/api/trash');
        let data = await res.json();
        
        if(data.length === 0) { 
            list.innerHTML = '<p style="opacity:0.5;text-align:center;">Dein Papierkorb ist komplett leer.</p>'; 
            return; 
        }

        const trashIds = new Set(data.map(d => d.id));
        const roots = [];
        const childrenMap = {};

        data.forEach(n => {
            if (n.parent_id && trashIds.has(n.parent_id)) {
                if (!childrenMap[n.parent_id]) childrenMap[n.parent_id] = [];
                childrenMap[n.parent_id].push(n);
            } else {
                roots.push(n);
            }
        });

        list.innerHTML = '';

        function renderNode(node, level) {
            const d = document.createElement('div');
            d.style = `display:flex; justify-content:space-between; align-items:center; padding:8px 10px; border-bottom:1px solid var(--border-color); margin-left: ${level * 20}px;`;
            if (level > 0) d.style.borderLeft = '2px solid var(--border-color)';

            const info = document.createElement('div');
            info.style.display = 'flex';
            info.style.alignItems = 'center';
            info.style.gap = '8px';

            const icon = document.createElement('span');
            icon.innerHTML = childrenMap[node.id] ? '<i class="icon icon-folder" style="color: #f1c40f;"></i>' : '<i class="icon icon-file"></i>';

            const titleSpan = document.createElement('div');
            titleSpan.innerText = node.title || 'Unbenannt';
            titleSpan.style.fontWeight = level === 0 ? 'bold' : 'normal';

            info.appendChild(icon);
            info.appendChild(titleSpan);

            const btn = document.createElement('button');
            btn.innerText = "Wiederherstellen"; 
            btn.className = "btn-save"; 
            btn.style.padding = "4px 8px";
            btn.style.fontSize = "0.85em";
            btn.onclick = async () => {
                await fetch(`/api/trash/restore/${node.id}`, {method:'POST'});
                updateBadges(); 
                openTrashModal();
                checkAndReloadData();
            };
            
            d.appendChild(info); 
            d.appendChild(btn); 
            list.appendChild(d);

            if (childrenMap[node.id]) {
                childrenMap[node.id].forEach(child => renderNode(child, level + 1));
            }
        }

        roots.forEach(r => renderNode(r, 0));
        
    } catch(e) {
        list.innerHTML = 'Fehler beim Laden des Papierkorbs.';
    }
}

function emptyTrash() {
    showModal("Papierkorb endgültig leeren", "Möchtest du den Papierkorb jetzt leeren?\n\nAlle darin enthaltenen Notizen und Unterordner werden unwiderruflich von deinem Server gelöscht. Dieser Vorgang kann nicht rückgängig gemacht werden!", [
        { label: "Ja, endgültig löschen", class: "btn-discard", action: async () => { 
            await fetch('/api/trash/empty', {method: 'DELETE'});
            updateBadges(); 
            openTrashModal();
            checkAndReloadData();
        }},
        { label: "Abbrechen", class: "btn-cancel", action: () => {} }
    ]);
}

async function openHistoryModal() {
    if (!activeId) return;
    
    if (!fullTree.settings.history_enabled) {
        showModal("Hinweis", "Der Versionsverlauf ist in den allgemeinen Einstellungen derzeit deaktiviert.", [{ label: "Verstanden", class: "btn-cancel", action: () => {} }]);
        return;
    }
    
    if (!await acquireLock(activeId)) {
        showModal("Gesperrt", "Der Verlauf kann momentan nicht geöffnet werden, da diese Notiz gerade auf einem anderen Gerät aktiv bearbeitet wird.", [
            { label: "Verstanden", class: "btn-cancel", action: () => {} }
        ]);
        return;
    }
    
    document.getElementById('history-modal').style.display = 'flex';
    const listEl = document.getElementById('history-list');
    listEl.innerHTML = 'Lade Versionen vom Server...';
    
    try {
        const res = await fetch(`/api/notes/${activeId}/history`);
        const data = await res.json();
        
        if (data.length === 0) {
            listEl.innerHTML = '<p style="text-align:center; opacity:0.5;">Es wurden noch keine älteren Versionen für diese Notiz gespeichert.</p>';
            return;
        }
        
        listEl.innerHTML = '';
        data.forEach(h => {
            const dt = new Date(h.saved_at * 1000).toLocaleString('de-DE');
            const details = document.createElement('details');
            details.className = 'history-item';
            details.style.marginBottom = '10px';
            details.style.background = 'rgba(255,255,255,0.02)';
            details.style.border = '1px solid var(--border-color)';
            details.style.borderRadius = '5px';

            const summary = document.createElement('summary');
            summary.innerText = dt + " - " + (h.title || 'Unbenannt');

            const content = document.createElement('div');
            content.style.padding = '15px';
            content.style.fontSize = '0.9em';
            content.style.whiteSpace = 'pre-wrap';
            content.style.background = 'rgba(0,0,0,0.2)';
            content.style.borderTop = '1px solid var(--border-color)';
            content.innerText = h.text || '[Leere Notiz]';

            const btn = document.createElement('button');
            btn.className = 'btn-save';
            btn.style.marginTop = '15px';
            btn.style.width = '100%';
            btn.innerText = 'Diese alte Version wiederherstellen';
            btn.onclick = () => restoreHistory(h.id);
            
            content.appendChild(btn);
            details.appendChild(summary);
            details.appendChild(content);
            listEl.appendChild(details);
        });
    } catch(e) {
        listEl.innerHTML = 'Ein Fehler ist aufgetreten beim Laden der Historie.';
        console.error(e);
    }
}

function closeHistoryModal() {
    document.getElementById('history-modal').style.display = 'none';
    if (document.getElementById('edit-mode').style.display !== 'block') {
        releaseLock();
    }
}

async function restoreHistory(historyId) {
    try {
        const res = await fetch(`/api/notes/${activeId}/history/${historyId}`, {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({client_id: myClientId})
        });
        
        if (res.status === 403) {
            showModal("Fehler", "Wiederherstellung blockiert: Dein Gerät hat die Sperre verloren.", [{ label: "Verstanden", class: "btn-cancel", action: () => {} }]);
        } else {
            closeHistoryModal();
            await checkAndReloadData();
            activeNoteData = await fetchNoteData(activeId);
            renderDisplayArea();
        }
    } catch(e) { 
        console.error(e); 
    }
}

function toggleHistorySettings() {
    document.getElementById('history-settings-modal').style.display = 'flex';
    document.getElementById('history-enabled').checked = fullTree.settings.history_enabled || false;
    document.getElementById('history-days').value = fullTree.settings.history_days || 30;
}

async function saveHistorySettings() {
    const payload = {
        history_enabled: document.getElementById('history-enabled').checked,
        history_days: document.getElementById('history-days').value
    };
    
    await fetch('/api/settings', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    fullTree.settings.history_enabled = payload.history_enabled;
    fullTree.settings.history_days = payload.history_days;
    document.getElementById('history-settings-modal').style.display = 'none';
    renderDisplayArea(); 
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
    document.getElementById('webhook-payload-container').style.display = document.getElementById('webhook-method').value === 'POST' ? 'block' : 'none'; 
}

async function testWebhook() {
    const payload = { url: document.getElementById('webhook-url').value, method: document.getElementById('webhook-method').value, payload: document.getElementById('webhook-payload').value };
    if (!payload.url) { showModal("Hinweis", "Bitte trage zuerst eine gültige Ziel-URL ein, bevor du den Test startest.", [{ label: "Okay", class: "btn-cancel", action: () => {} }]); return; }
    document.getElementById('webhook-modal').style.display = 'none';
    try {
        const res = await fetch('/api/webhook/test', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
        const data = await res.json();
        if (res.ok) {
            showModal("Test erfolgreich gesendet", `Der Server meldet den Status-Code: ${data.status_code}\n\nAntwort des Zielservers:\n${data.response_text || '(Keine Text-Antwort erhalten)'}`, [{ label: "Zurück zu den Einstellungen", class: "btn-cancel", action: () => { document.getElementById('webhook-modal').style.display = 'flex'; } }]);
        } else {
            showModal("Fehler beim Senden", `Der Test konnte nicht erfolgreich ausgeführt werden. Der Server meldet:\n\n${data.error}`, [{ label: "Zurück zu den Einstellungen", class: "btn-cancel", action: () => { document.getElementById('webhook-modal').style.display = 'flex'; } }]);
        }
    } catch(e) {
        showModal("Netzwerkfehler", `Es gab ein technisches Problem beim Verbinden zum Server:\n\n${e}`, [{ label: "Zurück zu den Einstellungen", class: "btn-cancel", action: () => { document.getElementById('webhook-modal').style.display = 'flex'; } }]);
    }
}

async function saveWebhook() {
    const payload = { webhook_enabled: document.getElementById('webhook-enabled').checked, webhook_method: document.getElementById('webhook-method').value, webhook_url: document.getElementById('webhook-url').value, webhook_payload: document.getElementById('webhook-payload').value };
    await fetch('/api/settings', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) }); 
    fullTree.settings.webhook_enabled = payload.webhook_enabled; 
    document.getElementById('webhook-modal').style.display = 'none'; 
    updateMenuUI();
}

async function toggleHeaderIcon(type, event) {
    if (event) event.stopPropagation();
    const key = type === 'tasks' ? 'icon_tasks_enabled' : 'icon_reminders_enabled';
    const currentVal = fullTree.settings[key] !== false && fullTree.settings[key] !== 'false';
    const newVal = !currentVal;
    fullTree.settings[key] = newVal;
    updateMenuUI();
    await fetch('/api/settings', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ [key]: newVal }) });
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
        b.onclick = () => { document.getElementById('custom-modal').style.display = 'none'; btn.action(); }; 
        container.appendChild(b); 
    }); 
    document.getElementById('custom-modal').style.display = 'flex'; 
    if (showInput) setTimeout(() => { inp.focus(); }, 100); 
}

function clearSearch() { 
    document.getElementById('search-input').value = ''; 
    document.getElementById('clear-search').style.display = 'none'; 
    renderTree(); 
    updateToggleAllIcon();
}

async function filterTree() {
    const term = document.getElementById('search-input').value.toLowerCase().trim(); 
    const clearBtn = document.getElementById('clear-search');
    if (!term) { clearBtn.style.display = 'none'; renderTree(); updateToggleAllIcon(); return; }
    clearBtn.style.display = 'flex'; 
    if (searchTimeout) clearTimeout(searchTimeout);
    searchTimeout = setTimeout(async () => {
        let matchedIds = new Set();
        try {
            const res = await fetch('/api/search?q=' + encodeURIComponent(term));
            if (res.ok) { const ids = await res.json(); ids.forEach(id => matchedIds.add(id)); }
        } catch(e) { console.error("Suchfehler:", e); }
        const container = document.getElementById('tree'); 
        container.innerHTML = '';
        const rootGroup = document.createElement('div'); 
        rootGroup.className = 'tree-group'; 
        container.appendChild(rootGroup);
        function getFilteredItems(items) { 
            let results = []; 
            items.forEach(item => { 
                const matchInTitle = item.title && item.title.toLowerCase().includes(term); 
                const matchInText = matchedIds.has(item.id); 
                let filteredChildren = item.children ? getFilteredItems(item.children) : [];
                if (matchInTitle || matchInText || filteredChildren.length > 0) {
                    if ((matchInTitle || matchInText || filteredChildren.length > 0) && collapsedIds.has(item.id)) { collapsedIds.delete(item.id); }
                    results.push({ ...item, children: filteredChildren }); 
                }
            }); 
            return results; 
        }
        renderItems(getFilteredItems(fullTree.content), rootGroup);
        updateToggleAllIcon();
    }, 300); 
}

function togglePassword() {
    if (fullTree.settings.password_enabled) { 
        showModal("Passwortschutz deaktivieren", "Möchtest du den Passwortschutz für diese Instanz wirklich deaktivieren?", [
            { label: "Ja, Schutz aufheben", class: "btn-discard", action: async () => { await fetch('/api/settings', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ password_enabled: false }) }); fullTree.settings.password_enabled = false; updateMenuUI(); } }, 
            { label: "Abbruch", class: "btn-cancel", action: () => {} }
        ]); 
    } else { 
        showModal("Passwortschutz aktivieren", "Bitte gib ein starkes, sicheres Passwort ein, um deine Notizen vor unbefugtem Zugriff zu schützen.", [
            { label: "Passwort speichern", class: "btn-save", action: async () => { const pwd = document.getElementById('modal-input').value; if(pwd) { await fetch('/api/settings', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ password_enabled: true, password: pwd }) }); fullTree.settings.password_enabled = true; updateMenuUI(); } } }, 
            { label: "Abbruch", class: "btn-cancel", action: () => {} }
        ], true); 
    }
}

function toggleAllFolders() {
    const searchTerm = document.getElementById('search-input').value; 
    let totalFolders = 0;
    function countFolders(items) { if (!Array.isArray(items)) return; items.forEach(i => { if (i.children && i.children.length > 0) { totalFolders++; countFolders(i.children); } }); }
    countFolders(fullTree.content);
    if (collapsedIds.size >= totalFolders / 2 && totalFolders > 0) { collapsedIds.clear(); } else { function collect(items) { items.forEach(i => { if(i.children && i.children.length > 0) { collapsedIds.add(i.id); collect(i.children); } }); } collect(fullTree.content); }
    saveCollapsedToLocal(); 
    if (searchTerm) filterTree(); else renderTree();
    updateToggleAllIcon();
}

function confirmAutoSort() { 
    showModal("Notizen sortieren?", "Möchtest du den gesamten Notizbaum automatisch alphabetisch sortieren lassen?", [
        { label: "Ja, jetzt sortieren", class: "btn-discard", action: async () => { await applyAutoSort(); } }, 
        { label: "Abbrechen", class: "btn-cancel", action: () => {} }
    ]); 
}

async function applyAutoSort() { 
    const sortRecursive = (list) => { list.sort((a, b) => { const aIsFolder = a.children && a.children.length > 0; const bIsFolder = b.children && b.children.length > 0; if (aIsFolder && !bIsFolder) return -1; if (!aIsFolder && bIsFolder) return 1; return a.title.localeCompare(b.title, undefined, { numeric: true, sensitivity: 'base' }); }); list.forEach(item => { if(item.children) sortRecursive(item.children); }); }; 
    sortRecursive(fullTree.content); 
    document.body.classList.add('edit-mode-active'); renderTree(); await rebuildDataFromDOM(); document.body.classList.remove('edit-mode-active'); renderTree(); updateToggleAllIcon();
}

function wrapSelection(b, a, p = "") { const ta = document.getElementById('node-text'); const s = ta.selectionStart; const e = ta.selectionEnd; let txt = ta.value.substring(s, e) || p; ta.value = ta.value.substring(0, s) + b + txt + a + ta.value.substring(e); ta.focus(); ta.setSelectionRange(s + b.length, s + b.length + txt.length); }

function handleListAction(prefix, placeholder) {
    const ta = document.getElementById('node-text'); const start = ta.selectionStart; const end = ta.selectionEnd; const text = ta.value; const selectedText = text.substring(start, end);
    if (selectedText.includes('\n')) { const newText = selectedText.split('\n').map(line => (line.trim() === '' || line.trim().startsWith(prefix.trim())) ? line : prefix + line).join('\n'); ta.value = text.substring(0, start) + newText + text.substring(end); ta.setSelectionRange(start, start + newText.length); ta.focus(); return; }
    const textBefore = text.substring(0, start);
    if (selectedText === placeholder && textBefore.endsWith(prefix)) { const insertStr = '\n' + prefix + placeholder; ta.value = text.substring(0, end) + insertStr + text.substring(end); const newStart = end + '\n'.length + prefix.length; ta.setSelectionRange(newStart, newStart + placeholder.length); ta.focus(); return; }
    let insertPrefix = (textBefore.length > 0 && !textBefore.endsWith('\n')) ? '\n' + prefix : prefix; let insertText = selectedText || placeholder; ta.value = text.substring(0, start) + insertPrefix + insertText + text.substring(end); const selectStart = start + insertPrefix.length; ta.setSelectionRange(selectStart, selectStart + insertText.length); ta.focus();
}

function insertCodeTag() { wrapSelection("'''\n", "\n'''", "CODE"); }

function handleNumberedList() {
    const ta = document.getElementById('node-text');
    const start = ta.selectionStart;
    const end = ta.selectionEnd;
    const text = ta.value;
    const selectedText = text.substring(start, end);
    if (selectedText.includes('\n')) {
        let num = 1;
        const newText = selectedText.split('\n').map(line => { if (line.trim() === '') return line; return (num++) + '. ' + line; }).join('\n');
        ta.value = text.substring(0, start) + newText + text.substring(end);
        ta.setSelectionRange(start, start + newText.length);
    } else {
        const ins = '1. ' + (selectedText || 'Eintrag');
        const prefix = (start > 0 && !text.charAt(start - 1).match(/\n/)) ? '\n' : '';
        ta.value = text.substring(0, start) + prefix + ins + text.substring(end);
        ta.setSelectionRange(start + prefix.length + 3, start + prefix.length + ins.length);
    }
    ta.focus();
}

function applyColor() { const hex = document.getElementById('text-color-input').value; wrapSelection(`[${hex}]`, '[/#]', 'Farbiger Text'); }

function copyToClipboard(btn) { const el = document.createElement('textarea'); el.value = btn.nextElementSibling.innerText; document.body.appendChild(el); el.select(); document.execCommand('copy'); document.body.removeChild(el); btn.innerText = 'Kopiert!'; setTimeout(() => { btn.innerText = 'Copy'; }, 2000); }

function toggleSettings(e) { if (e) e.stopPropagation(); const m = document.getElementById('dropdown-menu'); const isVisible = m.style.display === 'block'; closeAllMenus(); if (!isVisible) m.style.display = 'block'; }
function toggleNoteMenu(e) { if (e) e.stopPropagation(); const m = document.getElementById('note-menu-content'); const isVisible = m.style.display === 'block'; closeAllMenus(); if (!isVisible) m.style.display = 'block'; }

document.addEventListener('click', () => { closeAllMenus(); });

function exportData() { window.location.href = '/api/export'; }

function toggleSidebar() { const h = document.body.classList.toggle('sidebar-hidden'); localStorage.setItem('sidebarState', h ? 'closed' : 'open'); document.querySelector('#mobile-toggle-btn span').innerText = h ? '▶' : '◀'; }

async function uploadImage() { const input = document.createElement('input'); input.type = 'file'; input.accept = 'image/*'; input.onchange = async (e) => { const file = e.target.files[0]; if (!file) return; uploadWithProgress(file, (data) => { if(data.filename) { wrapSelection(`[img:${data.filename}]`, '', ''); } }); }; input.click(); }

async function uploadGenericFile() { const input = document.createElement('input'); input.type = 'file'; input.onchange = async (e) => { const file = e.target.files[0]; if (!file) return; uploadWithProgress(file, (data) => { if(data.filename) { let txt = file.type.startsWith('image/') ? `[img:${data.filename}]` : `[file:${data.filename}|${data.original}]`; const ta = document.getElementById('node-text'); const s = ta.selectionStart; ta.value = ta.value.substring(0, s) + txt + ta.value.substring(ta.selectionEnd); ta.focus(); ta.setSelectionRange(s + txt.length, s + txt.length); } }); }; input.click(); }

function openLightbox(src) { document.getElementById('lightbox-img').src = src; document.getElementById('lightbox').style.display = 'flex'; }
function closeLightbox() { document.getElementById('lightbox').style.display = 'none'; document.getElementById('lightbox-img').src = ''; }

function getAllNotesFlat(nodes, path="") { let res = []; if (!Array.isArray(nodes)) return res; nodes.forEach(n => { let currentPath = path ? path + " / " + n.title : n.title; res.push({ id: n.id, title: n.title, path: currentPath }); if(n.children) { res = res.concat(getAllNotesFlat(n.children, currentPath)); } }); return res; }

function initMentionSystem() {
    const ta = document.getElementById('node-text'); const dropdown = document.getElementById('mention-dropdown'); if(!ta || !dropdown) return;
    ta.addEventListener('input', function() {
        let match = ta.value.substring(0, ta.selectionStart).match(/(?:^|\s)@([^\n]{0,30})$/);
        if (match) {
            let search = match[1].toLowerCase(); let filtered = getAllNotesFlat(fullTree.content).filter(n => n.id !== activeId && (n.title.toLowerCase().includes(search) || n.path.toLowerCase().includes(search)));
            if (filtered.length > 0) { dropdown.innerHTML = ''; filtered.forEach(n => { let div = document.createElement('div'); div.className = 'mention-item'; div.innerHTML = `<strong>${n.title}</strong><span class="mention-path">${n.path}</span>`; div.onclick = () => insertMention(n.id, n.title, match[1].length + 1); dropdown.appendChild(div); }); dropdown.style.display = 'block'; } else { dropdown.style.display = 'none'; }
        } else { dropdown.style.display = 'none'; }
    });
    document.addEventListener('click', (e) => { if(e.target !== ta && !dropdown.contains(e.target)) dropdown.style.display = 'none'; });
}

function insertMention(id, title, replaceLength) { let ta = document.getElementById('node-text'); let cursor = ta.selectionStart; let start = cursor - replaceLength; let linkCode = `[note:${id}|${title}] `; ta.value = ta.value.substring(0, start) + linkCode + ta.value.substring(cursor); ta.focus(); ta.setSelectionRange(start + linkCode.length, start + linkCode.length); document.getElementById('mention-dropdown').style.display = 'none'; }

function triggerMentionButton() { let ta = document.getElementById('node-text'); let s = ta.selectionStart; let prefix = (s === 0 || ta.value.charAt(s - 1) === '\n' || ta.value.charAt(s - 1) === ' ') ? '@' : ' @'; ta.value = ta.value.substring(0, s) + prefix + ta.value.substring(ta.selectionEnd); ta.focus(); ta.setSelectionRange(s + prefix.length, s + prefix.length); ta.dispatchEvent(new Event('input')); }

let sketchCanvas, sketchCtx, isDrawing = false, sketchStrokes = [], currentStroke = null, sketchColor = '#000000', sketchWidth = 8, sketchMode = 'pen', sketchBg = 'white', activeSketchId = null;

async function openSketch(id = null) { const isEdit = document.getElementById('edit-mode').style.display === 'block'; if (!isEdit && !await acquireLock(activeId)) { showModal("Gesperrt", "Skizze kann nicht geöffnet werden.", [{ label: "OK", class: "btn-cancel", action: () => {} }]); return; } document.getElementById('sketch-modal').style.display = 'flex'; if(!sketchCanvas) initSketcher(); activeSketchId = id; sketchStrokes = []; if (id) { try { const res = await fetch(`/api/sketch/${id}`); if(res.ok) { const data = await res.json(); sketchBg = data.bg || 'white'; document.getElementById('sketch-bg-select').value = sketchBg; sketchStrokes = data.strokes || []; } } catch(e) { console.error(e); } } else { sketchBg = document.getElementById('sketch-bg-select').value; } setSketchMode('pen'); redrawSketch(); }
function closeSketch() { document.getElementById('sketch-modal').style.display = 'none'; if (document.getElementById('edit-mode').style.display !== 'block') releaseLock(); }

async function saveSketch() { const payload = { id: activeSketchId, bg: sketchBg, strokes: sketchStrokes, image: sketchCanvas.toDataURL("image/png") }; const res = await fetch('/api/sketch', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) }); const data = await res.json(); if (!activeSketchId && data.id) wrapSelection(`[sketch:${data.id}]`, '', ''); document.getElementById('sketch-modal').style.display = 'none'; const ta = document.getElementById('node-text'); if (ta) ta.value = ta.value.replace(`[sketch:${data.id}]`, `[sketch:${data.id}] `).trim(); document.querySelectorAll('.sketch-img').forEach(img => { if (img.src.includes(data.id)) img.src = `/uploads/sketch_${data.id}.png?v=` + Date.now(); }); if (document.getElementById('edit-mode').style.display !== 'block') releaseLock(); }

function initSketcher() { sketchCanvas = document.getElementById('sketch-canvas'); sketchCtx = sketchCanvas.getContext('2d'); sketchCanvas.width = 1200; sketchCanvas.height = 900; const getPos = (e) => { const r = sketchCanvas.getBoundingClientRect(); const scaleX = sketchCanvas.width / r.width; const scaleY = sketchCanvas.height / r.height; let cx = e.touches ? e.touches[0].clientX : e.clientX; let cy = e.touches ? e.touches[0].clientY : e.clientY; return { x: (cx - r.left) * scaleX, y: (cy - r.top) * scaleY }; }; const startDraw = (e) => { e.preventDefault(); isDrawing = true; currentStroke = { color: sketchMode === 'eraser' ? sketchBg : sketchColor, width: sketchWidth, mode: sketchMode, points: [getPos(e)] }; sketchStrokes.push(currentStroke); }; const draw = (e) => { if (!isDrawing) return; e.preventDefault(); currentStroke.points.push(getPos(e)); redrawSketch(); }; const endDraw = () => { isDrawing = false; }; sketchCanvas.addEventListener('mousedown', startDraw); sketchCanvas.addEventListener('mousemove', draw); window.addEventListener('mouseup', endDraw); sketchCanvas.addEventListener('touchstart', startDraw, {passive: false}); sketchCanvas.addEventListener('touchmove', draw, {passive: false}); window.addEventListener('touchend', endDraw); }

function redrawSketch() { sketchCtx.globalAlpha = 1.0; sketchCtx.fillStyle = sketchBg; sketchCtx.fillRect(0, 0, sketchCanvas.width, sketchCanvas.height); sketchCtx.lineCap = 'round'; sketchCtx.lineJoin = 'round'; for (let s of sketchStrokes) { if (s.points.length < 2) continue; sketchCtx.globalAlpha = s.mode === 'highlighter' ? 0.4 : 1.0; sketchCtx.beginPath(); sketchCtx.strokeStyle = s.color; sketchCtx.lineWidth = s.width; sketchCtx.moveTo(s.points[0].x, s.points[0].y); for (let i = 1; i < s.points.length - 1; i++) { let xc = (s.points[i].x + s.points[i + 1].x) / 2; let yc = (s.points[i].y + s.points[i + 1].y) / 2; sketchCtx.quadraticCurveTo(s.points[i].x, s.points[i].y, xc, yc); } sketchCtx.lineTo(s.points[s.points.length - 1].x, s.points[s.points.length - 1].y); sketchCtx.stroke(); } sketchCtx.globalAlpha = 1.0; }

function undoSketch() { if (sketchStrokes.length > 0) { sketchStrokes.pop(); redrawSketch(); } }
function setSketchMode(mode) { sketchMode = mode; document.getElementById('btn-pen').classList.toggle('active', mode === 'pen'); document.getElementById('btn-highlighter').classList.toggle('active', mode === 'highlighter'); document.getElementById('btn-eraser').classList.toggle('active', mode === 'eraser'); }
function setSketchBg(bg) { sketchBg = bg; sketchStrokes.forEach(s => { if (s.mode === 'eraser') s.color = bg; else if (!s.mode && (s.color === 'white' || s.color === 'black')) { if (s.color !== bg && sketchMode === 'eraser') s.color = bg; } }); redrawSketch(); }

function applyAccentColor(hex) { document.documentElement.style.setProperty('--accent', hex); const r = parseInt(hex.slice(1,3), 16), g = parseInt(hex.slice(3,5), 16), b = parseInt(hex.slice(5,7), 16); document.documentElement.style.setProperty('--accent-rgb', `${r}, ${g}, ${b}`); const p = document.getElementById('accent-color-picker'); if(p) p.value = hex; }
async function updateGlobalAccent(hex) { await fetch('/api/settings', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ accent: hex }) }); fullTree.settings.accent = hex; applyAccentColor(hex); }
async function toggleTheme() { const newTheme = document.body.getAttribute('data-theme') === 'dark' ? 'light' : 'dark'; await fetch('/api/settings', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ theme: newTheme }) }); fullTree.settings.theme = newTheme; document.body.setAttribute('data-theme', newTheme); }

function updateMenuUI() { 
    const pwdBtn = document.getElementById('pwd-toggle-text'); const logoutBtn = document.getElementById('logout-btn'); const whToggleText = document.getElementById('webhook-toggle-text'); 
    if(pwdBtn) pwdBtn.innerHTML = fullTree.settings.password_enabled ? '<i class="icon icon-password" style="margin-right:8px;"></i> Passwortschutz: Aktiv ✓' : '<i class="icon icon-password" style="margin-right:8px;"></i> Passwortschutz: Inaktiv'; 
    if(logoutBtn) logoutBtn.style.display = fullTree.settings.password_enabled ? 'flex' : 'none'; 
    if(whToggleText) whToggleText.innerHTML = fullTree.settings.webhook_enabled ? '<i class="icon icon-webhook" style="margin-right:8px;"></i> Webhook (Aktiviert)' : '<i class="icon icon-webhook" style="margin-right:8px;"></i> Webhook (Push)'; 
    const taskToggleText = document.getElementById('toggle-tasks-text'); const remToggleText = document.getElementById('toggle-reminders-text');
    const tasksEnabled = fullTree.settings.icon_tasks_enabled !== false && fullTree.settings.icon_tasks_enabled !== 'false';
    const remEnabled = fullTree.settings.icon_reminders_enabled !== false && fullTree.settings.icon_reminders_enabled !== 'false';
    if(taskToggleText) taskToggleText.innerHTML = tasksEnabled ? '<i class="icon icon-tasks" style="margin-right:8px;"></i> Aufgaben-Icon: An' : '<i class="icon icon-tasks" style="margin-right:8px;"></i> Aufgaben-Icon: Aus';
    if(remToggleText) remToggleText.innerHTML = remEnabled ? '<i class="icon icon-reminder_active" style="margin-right:8px;"></i> Erinnerungs-Icon: An' : '<i class="icon icon-reminder_active" style="margin-right:8px;"></i> Erinnerungs-Icon: Aus';
    const btnTask = document.getElementById('todo-dashboard-btn'); const btnRem = document.getElementById('notification-bell');
    if(btnTask) btnTask.style.display = tasksEnabled ? '' : 'none';
    if(btnRem) btnRem.style.display = remEnabled ? '' : 'none';
}

async function addItem(parentId) { const newId = Date.now().toString() + Math.random().toString(36).substring(2, 6); const payload = { id: newId, parent_id: parentId, title: 'Neu', text: '' }; await fetch('/api/notes', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) }); if (parentId) { collapsedIds.delete(parentId); saveCollapsedToLocal(); } await checkAndReloadData(); selectNode(newId); enableEdit(); }

function deleteActiveNote() { if (activeId) deleteItem(activeId); }

function deleteItem(id) { showModal("Notiz löschen", "Möchtest du diese Notiz wirklich in den Papierkorb verschieben?\n\nAchtung: Alle Unterkategorien und deren Inhalte werden dabei ebenfalls in den Papierkorb verschoben.", [ { label: "Ja, in den Papierkorb", class: "btn-discard", action: async () => { const res = await fetch(`/api/notes/${id}`, { method: 'DELETE' }); if (res.status === 403) { showModal("Gesperrt", "Diese Notiz wird gerade von einem anderen Gerät bearbeitet und kann nicht gelöscht werden.", [{ label: "Verstanden", class: "btn-cancel", action: () => {} }]); return; } if (activeId === id) { activeId = null; activeNoteData = null; document.getElementById('edit-area').style.display = 'none'; document.getElementById('no-selection').style.display = 'block'; loadDashboard(); } const el = document.querySelector(`.tree-item-container[data-id="${id}"]`); if (el) el.remove(); updateBadges(); await checkAndReloadData(); } }, { label: "Abbruch", class: "btn-cancel", action: () => {} } ]); }

function findNode(items, id) { if (!Array.isArray(items)) return null; for (let i of items) { if (i.id === id) return i; if (i.children) { const f = findNode(i.children, id); if (f) return f; } } return null; }
function getPath(items, id, path = []) { if (!Array.isArray(items)) return null; for (let i of items) { const n = [...path, {title: i.title, id: i.id}]; if (i.id === id) return n; if (i.children) { const r = getPath(i.children, id, n); if (r) return r; } } return null; }

function initDragAndDrop() { const ta = document.getElementById('node-text'); if (!ta) return; ta.addEventListener('dragover', e => { e.preventDefault(); ta.style.border = '1px dashed var(--accent)'; }); ta.addEventListener('dragleave', e => { e.preventDefault(); ta.style.border = '1px solid var(--border-color)'; }); ta.addEventListener('drop', async e => { e.preventDefault(); ta.style.border = '1px solid var(--border-color)'; if(e.dataTransfer.files && e.dataTransfer.files.length > 0) { const f = e.dataTransfer.files[0]; uploadWithProgress(f, (data) => { if(data.filename) { let txt = f.type.startsWith('image/') ? `[img:${data.filename}]` : `[file:${data.filename}|${data.original}]`; const s = ta.selectionStart; ta.value = ta.value.substring(0, s) + txt + ta.value.substring(ta.selectionEnd); ta.focus(); ta.setSelectionRange(s + txt.length, s + txt.length); } }); } }); }

function initTabHandler() {
    const ta = document.getElementById('node-text');
    if (!ta) return;
    ta.addEventListener('keydown', function(e) {
        if (e.key === 'Tab') {
            e.preventDefault();
            const start = ta.selectionStart;
            const end = ta.selectionEnd;
            const text = ta.value;
            if (start === end) {
                if (e.shiftKey) {
                    const lineStart = text.lastIndexOf('\n', start - 1) + 1;
                    if (text.substring(lineStart, lineStart + 4) === '    ') {
                        ta.value = text.substring(0, lineStart) + text.substring(lineStart + 4);
                        ta.setSelectionRange(Math.max(start - 4, lineStart), Math.max(start - 4, lineStart));
                    } else if (text.substring(lineStart, lineStart + 1) === '\t') {
                        ta.value = text.substring(0, lineStart) + text.substring(lineStart + 1);
                        ta.setSelectionRange(Math.max(start - 1, lineStart), Math.max(start - 1, lineStart));
                    }
                } else {
                    ta.value = text.substring(0, start) + '    ' + text.substring(end);
                    ta.setSelectionRange(start + 4, start + 4);
                }
            } else {
                const selected = text.substring(start, end);
                const lineStart = text.lastIndexOf('\n', start - 1) + 1;
                const block = text.substring(lineStart, end);
                let newBlock;
                if (e.shiftKey) {
                    newBlock = block.split('\n').map(l => l.startsWith('    ') ? l.substring(4) : (l.startsWith('\t') ? l.substring(1) : l)).join('\n');
                } else {
                    newBlock = block.split('\n').map(l => '    ' + l).join('\n');
                }
                ta.value = text.substring(0, lineStart) + newBlock + text.substring(end);
                ta.setSelectionRange(lineStart, lineStart + newBlock.length);
            }
        }

        if (e.key === 'Enter') {
            const start = ta.selectionStart;
            const text = ta.value;
            const lineStart = text.lastIndexOf('\n', start - 1) + 1;
            const line = text.substring(lineStart, start);
            const trimmed = line.trimStart();
            const indent = line.substring(0, line.length - trimmed.length);

            let prefix = null;
            let isEmpty = false;

            if (trimmed.match(/^- \[([ xX])\] $/)) {
                isEmpty = true;
            } else if (trimmed.match(/^- \[([ xX])\] .+/)) {
                prefix = indent + '- [ ] ';
            } else if (trimmed.match(/^\d+\. $/)) {
                isEmpty = true;
            } else if (trimmed.match(/^(\d+)\. .+/)) {
                const num = parseInt(trimmed.match(/^(\d+)\./)[1]);
                prefix = indent + (num + 1) + '. ';
            } else if (trimmed === '- ') {
                isEmpty = true;
            } else if (trimmed.startsWith('- ') && trimmed.length > 2) {
                prefix = indent + '- ';
            }

            if (isEmpty) {
                e.preventDefault();
                ta.value = text.substring(0, lineStart) + '\n' + text.substring(start);
                ta.setSelectionRange(lineStart + 1, lineStart + 1);
            } else if (prefix) {
                e.preventDefault();
                ta.value = text.substring(0, start) + '\n' + prefix + text.substring(start);
                const newPos = start + 1 + prefix.length;
                ta.setSelectionRange(newPos, newPos);
            }
        }
    });
}

document.addEventListener('keydown', function(e) {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') { if (document.getElementById('edit-mode') && document.getElementById('edit-mode').style.display === 'block') { e.preventDefault(); saveChanges(); } }
    if (e.key === 'Escape') {
        if (document.getElementById('lightbox') && document.getElementById('lightbox').style.display === 'flex') closeLightbox();
        else if (document.getElementById('sketch-modal') && document.getElementById('sketch-modal').style.display === 'flex') closeSketch();
        else if (document.getElementById('custom-modal') && document.getElementById('custom-modal').style.display === 'flex') document.getElementById('custom-modal').style.display = 'none';
        else if (document.getElementById('contact-form-modal') && document.getElementById('contact-form-modal').style.display === 'flex') document.getElementById('contact-form-modal').style.display = 'none';
        else if (document.getElementById('contact-picker-modal') && document.getElementById('contact-picker-modal').style.display === 'flex') document.getElementById('contact-picker-modal').style.display = 'none';
        else if (document.getElementById('contacts-modal') && document.getElementById('contacts-modal').style.display === 'flex') document.getElementById('contacts-modal').style.display = 'none';
        else if (document.getElementById('note-tags-modal') && document.getElementById('note-tags-modal').style.display === 'flex') document.getElementById('note-tags-modal').style.display = 'none';
        else if (document.getElementById('tags-manager-modal') && document.getElementById('tags-manager-modal').style.display === 'flex') document.getElementById('tags-manager-modal').style.display = 'none';
        else if (document.getElementById('template-picker-modal') && document.getElementById('template-picker-modal').style.display === 'flex') document.getElementById('template-picker-modal').style.display = 'none';
        else if (document.getElementById('templates-modal') && document.getElementById('templates-modal').style.display === 'flex') document.getElementById('templates-modal').style.display = 'none';
        else if (document.getElementById('reminder-modal') && document.getElementById('reminder-modal').style.display === 'flex') document.getElementById('reminder-modal').style.display = 'none';
        else if (document.getElementById('history-modal') && document.getElementById('history-modal').style.display === 'flex') closeHistoryModal();
        else if (document.getElementById('history-settings-modal') && document.getElementById('history-settings-modal').style.display === 'flex') document.getElementById('history-settings-modal').style.display = 'none';
        else if (document.getElementById('webhook-modal') && document.getElementById('webhook-modal').style.display === 'flex') document.getElementById('webhook-modal').style.display = 'none';
        else if (document.getElementById('restore-modal') && document.getElementById('restore-modal').style.display === 'flex') document.getElementById('restore-modal').style.display = 'none';
        else if (document.getElementById('notifications-modal') && document.getElementById('notifications-modal').style.display === 'flex') document.getElementById('notifications-modal').style.display = 'none';
        else if (document.getElementById('todo-modal') && document.getElementById('todo-modal').style.display === 'flex') document.getElementById('todo-modal').style.display = 'none';
        else if (document.getElementById('trash-modal') && document.getElementById('trash-modal').style.display === 'flex') document.getElementById('trash-modal').style.display = 'none';
        else if (document.getElementById('share-overview-modal') && document.getElementById('share-overview-modal').style.display === 'flex') document.getElementById('share-overview-modal').style.display = 'none';
        else if (document.getElementById('media-modal') && document.getElementById('media-modal').style.display === 'flex') document.getElementById('media-modal').style.display = 'none';
        else if (document.getElementById('media-info-modal') && document.getElementById('media-info-modal').style.display === 'flex') document.getElementById('media-info-modal').style.display = 'none';
        else if (document.getElementById('edit-mode') && document.getElementById('edit-mode').style.display === 'block') cancelEdit();
    }
});

async function openRestoreModal() { document.getElementById('restore-modal').style.display = 'flex'; document.getElementById('restore-status').style.display = 'none'; document.getElementById('restore-file-upload').value = ''; const select = document.getElementById('server-backups'); select.innerHTML = '<option value="">-- Lade Backups... --</option>'; try { const res = await fetch('/api/backups'); const backups = await res.json(); if (backups.length === 0) { select.innerHTML = '<option value="">Keine automatischen Backups gefunden</option>'; } else { select.innerHTML = '<option value="">-- Auswählen --</option>'; backups.forEach(b => { const opt = document.createElement('option'); opt.value = b.filename; opt.innerText = `${b.date} (${b.size} MB) - ${b.filename}`; select.appendChild(opt); }); } } catch(e) { select.innerHTML = '<option value="">Fehler beim Laden</option>'; } }

async function executeRestore() { const fileInput = document.getElementById('restore-file-upload'); const select = document.getElementById('server-backups'); const statusDiv = document.getElementById('restore-status'); const btn = document.getElementById('btn-do-restore'); const file = fileInput.files[0]; const serverFile = select.value; if (!file && !serverFile) { statusDiv.innerText = "Bitte wähle ein Backup aus!"; statusDiv.style.color = '#e74c3c'; statusDiv.style.background = 'rgba(231, 76, 60, 0.1)'; statusDiv.style.display = 'block'; return; } const fd = new FormData(); if (file) fd.append('file', file); else fd.append('server_file', serverFile); btn.disabled = true; btn.innerText = "Verifiziere & Lade..."; statusDiv.style.display = 'none'; const xhr = new XMLHttpRequest(); xhr.open('POST', '/api/restore', true); if (file) { document.getElementById('restore-modal').style.display = 'none'; const modal = document.getElementById('upload-modal'); const bar = document.getElementById('upload-progress-bar'); const percentTxt = document.getElementById('upload-percent'); modal.style.display = 'flex'; bar.style.width = '0%'; percentTxt.innerText = '0%'; xhr.upload.onprogress = function(e) { if (e.lengthComputable) { const percent = Math.round((e.loaded / e.total) * 100); bar.style.width = percent + '%'; percentTxt.innerText = percent + '%'; } }; } xhr.onload = function() { if (file) document.getElementById('upload-modal').style.display = 'none'; try { const data = JSON.parse(xhr.responseText); if (xhr.status === 200 && data.status === 'success') { document.getElementById('restore-modal').style.display = 'flex'; statusDiv.style.color = '#27ae60'; statusDiv.style.background = 'rgba(39, 174, 96, 0.1)'; statusDiv.innerText = "Wiederherstellung erfolgreich! Die Seite wird nun neu geladen..."; statusDiv.style.display = 'block'; setTimeout(() => window.location.reload(), 2000); } else { document.getElementById('restore-modal').style.display = 'flex'; statusDiv.style.color = '#e74c3c'; statusDiv.style.background = 'rgba(231, 76, 60, 0.1)'; statusDiv.innerText = "Fehler: " + (data.error || "Unbekannter Serverfehler"); statusDiv.style.display = 'block'; btn.disabled = false; btn.innerText = "Wiederherstellen"; } } catch (e) { document.getElementById('restore-modal').style.display = 'flex'; statusDiv.style.color = '#e74c3c'; statusDiv.style.background = 'rgba(231, 76, 60, 0.1)'; statusDiv.innerText = "Netzwerkfehler beim Wiederherstellen."; statusDiv.style.display = 'block'; btn.disabled = false; btn.innerText = "Wiederherstellen"; } }; xhr.onerror = function() { if (file) document.getElementById('upload-modal').style.display = 'none'; document.getElementById('restore-modal').style.display = 'flex'; statusDiv.style.color = '#e74c3c'; statusDiv.style.background = 'rgba(231, 76, 60, 0.1)'; statusDiv.innerText = "Netzwerkfehler beim Hochladen des Backups."; statusDiv.style.display = 'block'; btn.disabled = false; btn.innerText = "Wiederherstellen"; }; xhr.send(fd); }

let touchStartX = 0; let touchEndX = 0;
document.addEventListener('touchstart', e => { touchStartX = e.changedTouches[0].screenX; }, {passive: true});
document.addEventListener('touchend', e => { if (document.querySelector('.modal-overlay[style*="display: flex"]')) return; touchEndX = e.changedTouches[0].screenX; if (window.innerWidth <= 768) { const swipeDist = touchEndX - touchStartX; const isHidden = document.body.classList.contains('sidebar-hidden'); if (swipeDist > 70 && isHidden && touchStartX < 50) { toggleSidebar(); } else if (swipeDist < -70 && !isHidden) { toggleSidebar(); } } }, {passive: true});

let initiallyClosedSpoilers = [];
window.addEventListener('beforeprint', () => { document.querySelectorAll('details.spoiler').forEach(s => { if (!s.hasAttribute('open')) { initiallyClosedSpoilers.push(s); s.setAttribute('open', ''); } }); });
window.addEventListener('afterprint', () => { initiallyClosedSpoilers.forEach(s => s.removeAttribute('open')); initiallyClosedSpoilers = []; });

let mediaRecorder = null; let audioChunks = []; let isRecording = false;
async function toggleAudioRecording() { const btn = document.getElementById('btn-record-audio'); if (isRecording) { mediaRecorder.stop(); isRecording = false; btn.innerHTML = '<i class="icon icon-mic"></i><span>Audio</span>'; btn.style.color = ''; btn.style.borderColor = ''; return; } try { const stream = await navigator.mediaDevices.getUserMedia({ audio: true }); mediaRecorder = new MediaRecorder(stream); audioChunks = []; mediaRecorder.ondataavailable = event => { if (event.data.size > 0) { audioChunks.push(event.data); } }; mediaRecorder.onstop = () => { const audioBlob = new Blob(audioChunks, { type: 'audio/webm' }); const file = new File([audioBlob], "audiomemo.webm", { type: 'audio/webm' }); uploadWithProgress(file, (data) => { if(data.filename) { wrapSelection(`\n[audio:${data.filename}]\n`, '', ''); } }); stream.getTracks().forEach(track => track.stop()); }; mediaRecorder.start(); isRecording = true; btn.innerHTML = '<i class="icon icon-mic"></i><span style="animation: pulse 1s infinite;">Aufnahme...</span>'; btn.style.color = '#e74c3c'; btn.style.borderColor = '#e74c3c'; } catch (err) { showModal("Fehler", "Zugriff auf das Mikrofon verweigert oder nicht gefunden.", [{ label: "Okay", class: "btn-cancel", action: () => {} }]); } }

// --- PIN ---
async function togglePinNote() {
    if (!activeId) return;
    try {
        const res = await fetch(`/api/notes/${activeId}/pin`, { method: 'POST' });
        const data = await res.json();
        await checkAndReloadData();
        updatePinMenuText();
    } catch(e) { console.error(e); }
}

function updatePinMenuText() {
    const el = document.getElementById('pin-menu-text');
    if (!el || !activeId) return;
    const node = findNode(fullTree.content, activeId);
    if (node && node.is_pinned) {
        el.innerHTML = '<i class="icon icon-pin-off" style="margin-right:8px;"></i> Anpinnung aufheben';
    } else {
        el.innerHTML = '<i class="icon icon-pin" style="margin-right:8px;"></i> Anpinnen';
    }
}

// --- DUPLICATE ---
async function duplicateNote() {
    if (!activeId) return;
    try {
        const res = await fetch(`/api/notes/${activeId}/duplicate`, { method: 'POST' });
        const data = await res.json();
        if (data.id) {
            await checkAndReloadData();
            selectNode(data.id);
        }
    } catch(e) { console.error(e); }
}

// --- TAGS ---
var allTagsCache = [];
var activeTagFilters = new Set();
var tagFilterExpanded = false;

async function loadAllTags() {
    try {
        const res = await fetch('/api/tags');
        if (res.ok) allTagsCache = await res.json();
    } catch(e) { console.error(e); }
}

function renderTagFilterBar() {
    const bar = document.getElementById('tag-filter-bar');
    if (!bar) return;

    if (allTagsCache.length === 0) {
        bar.style.display = 'none';
        if (activeTagFilters.size > 0) { activeTagFilters.clear(); renderTree(); }
        return;
    }
    bar.style.display = 'flex';
    bar.innerHTML = '';

    if (tagFilterExpanded) {
        bar.style.flexWrap = 'wrap';
        allTagsCache.forEach(t => {
            bar.appendChild(makeTagChip(t));
        });
        const lessBtn = document.createElement('span');
        lessBtn.className = 'tag-filter-expand';
        lessBtn.innerText = '▴';
        lessBtn.title = 'Weniger anzeigen';
        lessBtn.onclick = () => { tagFilterExpanded = false; renderTagFilterBar(); };
        bar.appendChild(lessBtn);
        if (activeTagFilters.size > 0) bar.appendChild(makeTagClearBtn());
        return;
    }

    // Render all chips to measure
    bar.style.flexWrap = 'nowrap';
    const chips = allTagsCache.map(t => makeTagChip(t));
    chips.forEach(c => bar.appendChild(c));
    if (activeTagFilters.size > 0) bar.appendChild(makeTagClearBtn());

    // Wait a frame so the browser lays them out, then measure
    requestAnimationFrame(() => {
        if (!bar.offsetWidth) return;
        const barWidth = bar.clientWidth;
        const gap = 4;
        const reserveForMore = 40;
        const reserveForClear = activeTagFilters.size > 0 ? 30 : 0;
        const maxWidth = barWidth - reserveForMore - reserveForClear;

        let usedWidth = 0;
        let fitCount = 0;

        for (let i = 0; i < chips.length; i++) {
            const w = chips[i].offsetWidth + gap;
            if (usedWidth + w <= maxWidth || i === 0) {
                usedWidth += w;
                fitCount++;
            } else {
                break;
            }
        }

        if (fitCount >= allTagsCache.length) return;

        bar.innerHTML = '';
        for (let i = 0; i < fitCount; i++) {
            bar.appendChild(makeTagChip(allTagsCache[i]));
        }
        const moreBtn = document.createElement('span');
        moreBtn.className = 'tag-filter-expand';
        moreBtn.innerText = '+' + (allTagsCache.length - fitCount);
        moreBtn.onclick = () => { tagFilterExpanded = true; renderTagFilterBar(); };
        bar.appendChild(moreBtn);
        if (activeTagFilters.size > 0) bar.appendChild(makeTagClearBtn());
    });
}

function makeTagChip(t) {
    const chip = document.createElement('span');
    chip.className = 'tag-filter-chip' + (activeTagFilters.has(t.id) ? ' active' : '');
    chip.style.background = t.color;
    chip.innerText = t.name;
    chip.onclick = () => {
        if (activeTagFilters.has(t.id)) { activeTagFilters.delete(t.id); } 
        else { activeTagFilters.add(t.id); }
        renderTagFilterBar();
        renderTree();
    };
    return chip;
}

function makeTagClearBtn() {
    const clearChip = document.createElement('span');
    clearChip.style.cssText = 'font-size:0.75em; cursor:pointer; opacity:0.6; padding:3px 6px; align-self:center;';
    clearChip.innerHTML = '<i class="icon icon-clear"></i>';
    clearChip.onclick = () => { activeTagFilters.clear(); renderTagFilterBar(); renderTree(); };
    return clearChip;
}

async function openTagsManagerModal() {
    await loadAllTags();
    document.getElementById('tags-manager-modal').style.display = 'flex';
    renderTagsManagerList();
}

function renderTagsManagerList() {
    const list = document.getElementById('tags-manager-list');
    list.innerHTML = '';
    if (allTagsCache.length === 0) {
        list.innerHTML = '<p style="opacity:0.5; text-align:center;">Noch keine Tags erstellt.</p>';
        return;
    }
    allTagsCache.forEach(t => {
        const div = document.createElement('div');
        div.className = 'tag-manager-item';

        const chipSpan = document.createElement('span');
        chipSpan.className = 'tag-chip';
        chipSpan.style.background = t.color;
        chipSpan.innerText = t.name;
        div.appendChild(chipSpan);

        const spacer = document.createElement('span');
        spacer.style.flexGrow = '1';
        div.appendChild(spacer);

        const btnEdit = document.createElement('button');
        btnEdit.className = 'tool-btn';
        btnEdit.innerHTML = '<i class="icon icon-sketch"></i>';
        btnEdit.title = 'Bearbeiten';
        btnEdit.onclick = () => {
            div.innerHTML = '';
            div.style.flexWrap = 'wrap';

            const editColor = document.createElement('input');
            editColor.type = 'color';
            editColor.value = t.color;
            editColor.style.cssText = 'width:36px; height:32px; padding:1px; margin:0; border-radius:4px; border:1px solid var(--border-color); cursor:pointer;';

            const editName = document.createElement('input');
            editName.type = 'text';
            editName.value = t.name;
            editName.style.cssText = 'flex:1; min-width:80px; margin:0; padding:6px 10px; font-size:0.9em;';

            const btnSave = document.createElement('button');
            btnSave.className = 'btn-save';
            btnSave.style.padding = '6px 12px';
            btnSave.style.fontSize = '0.85em';
            btnSave.innerText = 'OK';
            btnSave.onclick = async () => {
                const newName = editName.value.trim();
                if (!newName) return;
                await fetch(`/api/tags/${t.id}`, {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ name: newName, color: editColor.value })
                });
                await loadAllTags();
                renderTagsManagerList();
                renderTagFilterBar();
                await checkAndReloadData();
            };

            const btnCancel = document.createElement('button');
            btnCancel.className = 'btn-cancel';
            btnCancel.style.padding = '6px 12px';
            btnCancel.style.fontSize = '0.85em';
            btnCancel.innerText = 'X';
            btnCancel.onclick = () => renderTagsManagerList();

            div.appendChild(editColor);
            div.appendChild(editName);
            div.appendChild(btnSave);
            div.appendChild(btnCancel);
            editName.focus();
            editName.select();
        };
        div.appendChild(btnEdit);

        const btnDel = document.createElement('button');
        btnDel.className = 'tool-btn';
        btnDel.style.color = '#e74c3c';
        btnDel.style.borderColor = '#e74c3c';
        btnDel.innerHTML = '<i class="icon icon-trash"></i>';
        btnDel.title = 'Löschen';
        btnDel.onclick = async () => {
            await fetch(`/api/tags/${t.id}`, { method: 'DELETE' });
            await loadAllTags();
            renderTagsManagerList();
            renderTagFilterBar();
            await checkAndReloadData();
        };
        div.appendChild(btnDel);
        list.appendChild(div);
    });
}

async function createNewTag() {
    const name = document.getElementById('new-tag-name').value.trim();
    const color = document.getElementById('new-tag-color').value;
    if (!name) return;
    await fetch('/api/tags', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name, color }) });
    document.getElementById('new-tag-name').value = '';
    await loadAllTags();
    renderTagsManagerList();
    renderTagFilterBar();
}

var pendingNoteTags = [];

async function openNoteTagsModal() {
    if (!activeId) return;
    await loadAllTags();
    try {
        const res = await fetch(`/api/notes/${activeId}/tags`);
        const currentTags = await res.json();
        pendingNoteTags = currentTags.map(t => t.id);
    } catch(e) { pendingNoteTags = []; }
    document.getElementById('note-tags-modal').style.display = 'flex';
    renderNoteTagsList();
}

function renderNoteTagsList() {
    const list = document.getElementById('note-tags-list');
    list.innerHTML = '';
    if (allTagsCache.length === 0) {
        list.innerHTML = '<p style="opacity:0.5; text-align:center;">Erstelle zuerst Tags unter Einstellungen → Tags verwalten.</p>';
        return;
    }
    allTagsCache.forEach(t => {
        const div = document.createElement('div');
        div.className = 'note-tag-item';
        const isSelected = pendingNoteTags.includes(t.id);
        div.innerHTML = `<input type="checkbox" ${isSelected ? 'checked' : ''} style="accent-color:${t.color}; width:18px; height:18px;"> <span class="tag-chip" style="background:${t.color}">${t.name}</span>`;
        div.onclick = () => {
            if (pendingNoteTags.includes(t.id)) {
                pendingNoteTags = pendingNoteTags.filter(x => x !== t.id);
            } else {
                pendingNoteTags.push(t.id);
            }
            renderNoteTagsList();
        };
        list.appendChild(div);
    });
}

async function saveNoteTags() {
    if (!activeId) return;
    await fetch(`/api/notes/${activeId}/tags`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ tag_ids: pendingNoteTags }) });
    document.getElementById('note-tags-modal').style.display = 'none';
    await checkAndReloadData();
    renderDisplayArea();
}

// --- TEMPLATES ---
async function openTemplatesModal() {
    document.getElementById('templates-modal').style.display = 'flex';
    renderTemplatesList();
}

async function renderTemplatesList() {
    const list = document.getElementById('templates-list');
    list.innerHTML = 'Lade Vorlagen...';
    try {
        const res = await fetch('/api/templates');
        const data = await res.json();
        if (data.length === 0) {
            list.innerHTML = '<p style="opacity:0.5; grid-column:1/-1; text-align:center;">Noch keine Vorlagen gespeichert. Erstelle Vorlagen über das Notiz-Menü (⋮) → "Als Vorlage speichern".</p>';
            return;
        }
        list.innerHTML = '';
        data.forEach(t => {
            const card = document.createElement('div');
            card.className = 'template-card';
            card.innerHTML = `<div class="template-card-title">${t.title || 'Unbenannt'}</div><div class="template-card-preview">${(t.text || '').substring(0, 150)}</div>`;
            const btnDel = document.createElement('button');
            btnDel.className = 'tool-btn';
            btnDel.style.cssText = 'color:#e74c3c; border-color:#e74c3c; margin-top:8px; width:100%;';
            btnDel.innerHTML = '<i class="icon icon-trash"></i><span>Löschen</span>';
            btnDel.onclick = async (e) => {
                e.stopPropagation();
                await fetch(`/api/templates/${t.id}`, { method: 'DELETE' });
                renderTemplatesList();
            };
            card.appendChild(btnDel);
            list.appendChild(card);
        });
    } catch(e) { list.innerHTML = 'Fehler beim Laden.'; }
}

async function saveAsTemplate() {
    if (!activeNoteData) return;
    try {
        await fetch('/api/templates', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ title: activeNoteData.title || 'Vorlage', text: activeNoteData.text || '' }) });
        showModal("Vorlage gespeichert", "Die aktuelle Notiz wurde als Vorlage gespeichert. Du kannst sie beim Erstellen neuer Notizen verwenden.", [{ label: "OK", class: "btn-cancel", action: () => {} }]);
    } catch(e) { console.error(e); }
}

var templatePickerParentId = null;

async function addItemFromTemplate(parentId) {
    templatePickerParentId = parentId;
    document.getElementById('template-picker-modal').style.display = 'flex';
    const list = document.getElementById('template-picker-list');
    list.innerHTML = 'Lade...';
    try {
        const res = await fetch('/api/templates');
        const data = await res.json();
        if (data.length === 0) {
            list.innerHTML = '<p style="opacity:0.5; grid-column:1/-1; text-align:center;">Noch keine Vorlagen gespeichert.</p>';
            return;
        }
        list.innerHTML = '';
        data.forEach(t => {
            const card = document.createElement('div');
            card.className = 'contact-picker-tile';
            card.innerHTML = `<div style="font-weight:bold; font-size:0.9em;">${t.title || 'Unbenannt'}</div><div style="font-size:0.7em; color:#888; max-height:40px; overflow:hidden;">${(t.text || '').substring(0, 80)}</div>`;
            card.onclick = () => createNoteFromTemplate(t);
            list.appendChild(card);
        });
    } catch(e) { list.innerHTML = 'Fehler.'; }
}

async function createNoteFromTemplate(template) {
    document.getElementById('template-picker-modal').style.display = 'none';
    const newId = Date.now().toString() + Math.random().toString(36).substring(2, 6);
    const payload = { id: newId, parent_id: templatePickerParentId, title: template.title || 'Neu', text: template.text || '' };
    await fetch('/api/notes', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    if (templatePickerParentId) { collapsedIds.delete(templatePickerParentId); saveCollapsedToLocal(); }
    await checkAndReloadData();
    selectNode(newId);
    enableEdit();
}

function goToDashboard(fromPopState) {
    if (document.getElementById('edit-mode').style.display === 'block') {
        if (activeNoteData && (document.getElementById('node-title').value !== activeNoteData.title || document.getElementById('node-text').value !== activeNoteData.text)) {
            showModal("Ungespeicherte Änderungen", "Du hast diese Notiz bearbeitet, aber noch nicht gespeichert. Möchtest du deine Änderungen jetzt speichern?", [
                { label: "Ja, speichern", class: "btn-save", action: async () => { await saveChanges(); goToDashboard(fromPopState); } },
                { label: "Nein, verwerfen", class: "btn-discard", action: () => { cancelEdit(); goToDashboard(fromPopState); } },
                { label: "Abbruch", class: "btn-cancel", action: () => {} }
            ]);
            return;
        }
        cancelEdit();
    }
    activeId = null;
    activeNoteData = null;
    localStorage.removeItem('lastActiveId');
    document.getElementById('edit-area').style.display = 'none';
    document.getElementById('no-selection').style.display = 'block';
    document.querySelectorAll('.tree-item').forEach(el => el.classList.remove('active'));
    if (!fromPopState) {
        history.pushState({ noteId: null }, '', '#');
    }
    loadDashboard();
}

// --- DASHBOARD ---
async function loadDashboard() {
    const container = document.getElementById('dashboard');
    if (!container) return;
    try {
        const res = await fetch('/api/dashboard');
        if (!res.ok) return;
        const d = await res.json();
        let html = '<h2 style="margin-top:0; opacity:0.8;">Dashboard</h2>';
        html += '<div class="dashboard-grid">';
        
        html += '<div class="dash-card"><div class="dash-stat"><div class="dash-stat-number">' + d.total_notes + '</div><div class="dash-stat-label">Notizen gesamt</div></div></div>';
        html += '<div class="dash-card"><div class="dash-stat"><div class="dash-stat-number">' + d.open_tasks + '</div><div class="dash-stat-label">Offene Aufgaben</div></div></div>';
        
        // Angepinnt
        html += '<div class="dash-card"><h4><i class="icon icon-pin"></i> Angepinnt</h4>';
        if (d.pinned && d.pinned.length > 0) {
            d.pinned.forEach(n => { html += `<div class="dash-card-item" onclick="selectNode('${n.id}')">${n.title || 'Unbenannt'}</div>`; });
        } else {
            html += '<p class="dash-empty">Keine angepinnten Notizen</p>';
        }
        html += '</div>';

        // Überfällig
        html += '<div class="dash-card"' + (d.overdue_reminders && d.overdue_reminders.length > 0 ? ' style="border-color:#e74c3c;"' : '') + '>';
        html += '<h4' + (d.overdue_reminders && d.overdue_reminders.length > 0 ? ' style="color:#e74c3c;"' : '') + '><i class="icon icon-reminder_active"></i> Überfällig' + (d.overdue_reminders && d.overdue_reminders.length > 0 ? ' (' + d.overdue_reminders.length + ')' : '') + '</h4>';
        if (d.overdue_reminders && d.overdue_reminders.length > 0) {
            d.overdue_reminders.forEach(n => {
                const rel = formatRelativeDate(n.reminder);
                html += `<div class="dash-card-item" onclick="selectNode('${n.id}')" style="display:flex; justify-content:space-between; align-items:center;">` +
                    `<span style="overflow:hidden; text-overflow:ellipsis;">${n.title || 'Unbenannt'}</span>` +
                    `<span style="font-size:0.7em; color:#e74c3c; flex-shrink:0; margin-left:8px;">${rel}</span></div>`;
            });
        } else {
            html += '<p class="dash-empty">Keine überfälligen Termine</p>';
        }
        html += '</div>';
        
        // Nächste Termine
        html += '<div class="dash-card"><h4><i class="icon icon-reminders"></i> Nächste Termine</h4>';
        if (d.upcoming_reminders && d.upcoming_reminders.length > 0) {
            d.upcoming_reminders.forEach(n => {
                const rel = formatRelativeDate(n.reminder);
                html += `<div class="dash-card-item" onclick="selectNode('${n.id}')" style="display:flex; justify-content:space-between; align-items:center;">` +
                    `<span style="overflow:hidden; text-overflow:ellipsis;">${n.title || 'Unbenannt'}</span>` +
                    `<span style="font-size:0.7em; color:var(--accent); flex-shrink:0; margin-left:8px;">${rel}</span></div>`;
            });
        } else {
            html += '<p class="dash-empty">Keine anstehenden Termine</p>';
        }
        html += '</div>';

        // Medien
        html += '<div class="dash-card"><h4><i class="icon icon-media"></i> Zuletzt hinzugefügt</h4>';
        if (d.recent_media && d.recent_media.length > 0) {
            html += '<div style="display:grid; grid-template-columns:repeat(auto-fill, minmax(80px,1fr)); gap:8px;">';
            d.recent_media.forEach(m => {
                const dt = new Date(m.uploaded_at * 1000).toLocaleDateString('de-DE');
                if (m.file_type === 'image' || m.file_type === 'sketch') {
                    html += `<div style="text-align:center; cursor:pointer;" onclick="openLightbox('/uploads/${m.filename}')" title="${m.original_name}\n${dt}">` +
                        `<div style="width:100%; aspect-ratio:1; border-radius:6px; overflow:hidden; border:1px solid var(--border-color); background:rgba(0,0,0,0.2);">` +
                        `<img src="/uploads/${m.filename}" style="width:100%; height:100%; object-fit:cover;"></div>` +
                        `<div style="font-size:0.6em; color:#888; margin-top:3px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;">${dt}</div></div>`;
                } else {
                    const icon = m.file_type === 'audio' ? 'icon-mic' : 'icon-file';
                    html += `<div style="text-align:center;" title="${m.original_name}\n${dt}">` +
                        `<div style="width:100%; aspect-ratio:1; border-radius:6px; border:1px solid var(--border-color); background:rgba(0,0,0,0.2); display:flex; align-items:center; justify-content:center;">` +
                        `<i class="icon ${icon}" style="font-size:1.5em; opacity:0.5;"></i></div>` +
                        `<div style="font-size:0.6em; color:#888; margin-top:3px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;">${m.original_name || m.filename}</div></div>`;
                }
            });
            html += '</div>';
        } else {
            html += '<p class="dash-empty">Keine Medien vorhanden</p>';
        }
        html += '</div>';
        
        // Zuletzt bearbeitet
        html += '<div class="dash-card" style="grid-column: 1 / -1;"><h4><i class="icon icon-history"></i> Zuletzt bearbeitet</h4>';
        if (d.recent && d.recent.length > 0) {
            html += '<div style="display:grid; grid-template-columns:repeat(auto-fill, minmax(180px,1fr)); gap:8px;">';
            d.recent.forEach(n => { html += `<div class="dash-card-item" onclick="selectNode('${n.id}')" style="padding:8px; background:rgba(255,255,255,0.03); border-radius:6px; border:1px solid var(--border-color);">${n.title || 'Unbenannt'}</div>`; });
            html += '</div>';
        } else {
            html += '<p class="dash-empty">Noch keine Notizen vorhanden</p>';
        }
        html += '</div>';
        
        html += '</div>';
        container.innerHTML = html;
    } catch(e) { console.error(e); }
}

function formatRelativeDate(dateStr) {
    if (!dateStr) return '';
    try {
        const d = dateStr.includes('T') ? new Date(dateStr) : new Date(dateStr + 'T00:00:00');
        const now = new Date();
        const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate());
        const targetStart = new Date(d.getFullYear(), d.getMonth(), d.getDate());
        const diffDays = Math.round((targetStart - todayStart) / 86400000);
        
        if (diffDays < -1) return 'vor ' + Math.abs(diffDays) + ' Tagen';
        if (diffDays === -1) return 'gestern';
        if (diffDays === 0) {
            if (dateStr.includes('T')) {
                return 'heute ' + d.toLocaleTimeString('de-DE', { hour: '2-digit', minute: '2-digit' });
            }
            return 'heute';
        }
        if (diffDays === 1) return 'morgen';
        if (diffDays <= 7) return 'in ' + diffDays + ' Tagen';
        return targetStart.toLocaleDateString('de-DE', { day: '2-digit', month: '2-digit' });
    } catch(e) { return dateStr.replace('T', ' '); }
}

window.addEventListener('popstate', function(e) {
    if (window.isShareView) return;
    const state = e.state;
    if (state && state.noteId) {
        if (state.noteId !== activeId) {
            if (document.getElementById('edit-mode').style.display === 'block') {
                cancelEdit();
            }
            doSelectNode(state.noteId, true);
        }
    } else {
        if (document.getElementById('edit-mode').style.display === 'block') {
            cancelEdit();
        }
        goToDashboard(true);
    }
});

window.onload = () => { 
    if (window.isShareView) { if (window.hljs) hljs.highlightAll(); return; }
    loadData(); initDragAndDrop(); initTabHandler(); initMentionSystem(); loadDashboard(); loadAllTags().then(() => renderTagFilterBar()); setInterval(checkAndReloadData, 30000); 
};
