#!/bin/bash

# Root-Rechte prüfen
if [ "$EUID" -ne 0 ]; then
    echo "FEHLER: Bitte führe dieses Skript als Root (z.B. sudo) aus!"
    exit 1
fi

BASE_DIR="/opt"

# Suche nach bestehenden Instanzen
mapfile -t INSTANCES < <(find $BASE_DIR -maxdepth 1 -type d -name "notiz-*" 2>/dev/null)

echo "================================================================="
echo " 📝 Notiz-Tool Setup & Instanz-Manager"
echo "================================================================="
echo ""

if [ ${#INSTANCES[@]} -gt 0 ]; then
    echo "Gefundene Instanzen auf diesem Server:"
    for i in "${!INSTANCES[@]}"; do
        DISP_NAME=$(basename "${INSTANCES[$i]}" | sed 's/notiz-//')
        echo " - $DISP_NAME (Port wird automatisch verwaltet)"
    done
    echo ""
    echo "Was möchtest du tun?"
    echo "[1] Eine NEUE Instanz anlegen"
    echo "[2] Alle bestehenden Instanzen AKTUALISIEREN (Code-Update einspielen)"
    echo "[3] Eine bestehende Instanz LÖSCHEN (Restlos deinstallieren)"
    read -p "Deine Auswahl (1, 2 oder 3) [Standard: 1]: " ACTION
    ACTION=${ACTION:-1}
else
    echo "Willkommen! Es wurden keine bestehenden Instanzen gefunden."
    echo "Wir starten nun mit der Neuinstallation der ersten Instanz."
    ACTION="1"
fi

# ==========================================
# FUNKTION: Code in das Zielverzeichnis schreiben
# ==========================================
write_app_code() {
    local TARGET_DIR=$1
    echo "Schreibe strukturierte Code-Dateien nach $TARGET_DIR ..."

    mkdir -p "$TARGET_DIR/static"
    mkdir -p "$TARGET_DIR/templates"
    mkdir -p "$TARGET_DIR/uploads"
    mkdir -p "$TARGET_DIR/uploads/contacts"
    mkdir -p "$TARGET_DIR/backups"

    echo "Lade statische Bibliotheken und Icons von GitHub herunter..."
    apt-get install -y unzip wget > /dev/null 2>&1
    wget -qO /tmp/notizen-static.zip https://github.com/ipod86/Notizen/archive/refs/heads/main.zip
    unzip -qo /tmp/notizen-static.zip -d /tmp/notizen-extract
    
    cp -r /tmp/notizen-extract/Notizen-main/app/. "$TARGET_DIR/" 2>/dev/null || true
    cp -r /tmp/notizen-extract/Notizen-main/static/icons "$TARGET_DIR/static/" 2>/dev/null || true
    cp -r /tmp/notizen-extract/Notizen-main/static/lib "$TARGET_DIR/static/" 2>/dev/null || true
    
    rm -rf /tmp/notizen-static.zip /tmp/notizen-extract

if [ "$ACTION" == "1" ]; then
    # --- NEUE INSTANZ ANLEGEN ---
    echo ""
    echo "================================================================="
    echo " 🏢 Schritt 1: Name der Instanz"
    echo "================================================================="
    echo "Wie soll deine neue Notiz-Instanz heißen?"
    echo "Dieser Name wird für den Ordner (z.B. /opt/notiz-firma) und den"
    echo "Systemd-Service (notizen-firma.service) verwendet."
    echo "Bitte verwende nur Kleinbuchstaben und keine Leerzeichen."
    read -p "Name der Instanz [Standard: main]: " INSTANCE_NAME
    
    if [ -z "$INSTANCE_NAME" ]; then 
        INSTANCE_NAME="main"
    fi
    
    INSTALL_DIR="$BASE_DIR/notiz-$INSTANCE_NAME"
    SERVICE_NAME="notizen-$INSTANCE_NAME.service"
    CRON_FILE="/etc/cron.d/notizen-$INSTANCE_NAME"
    
    # Prüfen, ob die Instanz bereits existiert
    if [ -d "$INSTALL_DIR" ]; then
        echo ""
        echo "❌ FEHLER: Eine Instanz mit dem Namen '$INSTANCE_NAME' existiert bereits!"
        echo "Bitte wähle im Hauptmenü Option [2] für ein Update oder [3] zum Löschen."
        exit 1
    fi
    
    echo ""
    echo "================================================================="
    echo " 🔌 Schritt 2: Port-Konfiguration"
    echo "================================================================="
    echo "Über welchen Port soll diese Instanz erreichbar sein?"
    echo "Wenn du z.B. 8081 wählst, erreichst du sie lokal unter http://IP:8081"
    
    # Intelligenter Port-Check
    while true; do
        read -p "Gewünschter Port [Standard: 8080]: " USER_PORT
        if [ -z "$USER_PORT" ]; then USER_PORT=8080; fi
        
        if grep -q "FLASK_PORT=$USER_PORT" /etc/systemd/system/notizen*.service 2>/dev/null; then
            echo "❌ FEHLER: Der Port $USER_PORT ist bereits für eine andere Notiz-Instanz reserviert! Bitte wähle einen anderen."
        elif ss -tuln | grep -q ":$USER_PORT "; then
            echo "❌ FEHLER: Der Port $USER_PORT wird gerade von einem anderen Programm auf dem Server verwendet! Bitte wähle einen anderen."
        else
            break
        fi
    done

    echo ""
    echo "================================================================="
    echo " 💾 Schritt 3: Automatisches Backup"
    echo "================================================================="
    echo "Möchtest du, dass das System jede Nacht automatisch ein komprimiertes"
    echo "Backup (.tar.gz) deiner Datenbank und Bilder anlegt?"
    read -p "Backup aktivieren? [Y/n] [Standard: Y]: " BACKUP_CONFIRM
    BACKUP_CONFIRM=${BACKUP_CONFIRM:-Y}

    echo ""
    echo "--- Starte Setup für $INSTALL_DIR auf Port $USER_PORT ---"

    apt update && apt install -y python3 python3-pip python3-venv cron sqlite3

    mkdir -p "$INSTALL_DIR"
    python3 -m venv "$INSTALL_DIR/venv"
    "$INSTALL_DIR/venv/bin/python3" -m pip install flask werkzeug requests

    write_app_code "$INSTALL_DIR"

    if ! id -u notizen > /dev/null 2>&1; then 
        useradd -r -s /bin/false notizen
    fi

    chown -R notizen:notizen "$INSTALL_DIR"
    find "$INSTALL_DIR" -type d -exec chmod 750 {} \;
    find "$INSTALL_DIR" -type f -exec chmod 640 {} \;
    chmod +x "$INSTALL_DIR/app.py"

    cat << SVCEOF > /etc/systemd/system/$SERVICE_NAME
[Unit]
Description=Notizen ($INSTANCE_NAME)
After=network.target

[Service]
User=notizen
Group=notizen
WorkingDirectory=$INSTALL_DIR
Environment="FLASK_PORT=$USER_PORT"
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/app.py
Restart=always

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"

    # Eigene Cron-Datei für diese Instanz
    echo "0 3 * * * notizen /usr/bin/python3 $INSTALL_DIR/cleanup.py" > "$CRON_FILE"
    if [[ "$BACKUP_CONFIRM" =~ ^[Yy]$ ]]; then 
        echo "0 4 * * * notizen $INSTALL_DIR/backup.sh" >> "$CRON_FILE"
    fi
    chmod 644 "$CRON_FILE"

    echo "--- ✅ Instanz '$INSTANCE_NAME' erfolgreich auf Port $USER_PORT installiert! ---"

elif [ "$ACTION" == "2" ]; then
    # --- BESTEHENDE INSTANZEN AKTUALISIEREN ---
    echo ""
    echo "Starte Update aller gefundenen Instanzen..."
    
    for DIR in "${INSTANCES[@]}"; do
        INSTANCE_NAME=$(basename "$DIR" | sed 's/notiz-//')
        
        # Abwärtskompatibilität für das allererste Skript
        if [ "$INSTANCE_NAME" == "tool" ]; then
            SERVICE_NAME="notizen.service"
        else
            SERVICE_NAME="notizen-$INSTANCE_NAME.service"
        fi

        echo "-----------------------------------"
        echo "Aktualisiere: $DIR (Service: $SERVICE_NAME)"
        
        systemctl stop "$SERVICE_NAME" 2>/dev/null
        
        write_app_code "$DIR"
        
        chown -R notizen:notizen "$DIR"
        chmod +x "$DIR/app.py"
        chmod +x "$DIR/backup.sh"
        
        systemctl start "$SERVICE_NAME"
        echo "Fertig: $INSTANCE_NAME aktualisiert und neugestartet."
    done
    
    echo "-----------------------------------"
    echo "--- ✅ Alle Instanzen sind auf dem neuesten Stand! ---"

elif [ "$ACTION" == "3" ]; then
    # --- BESTEHENDE INSTANZ LÖSCHEN ---
    echo ""
    echo "================================================================="
    echo " 🗑️ Instanz löschen"
    echo "================================================================="
    echo "Welche Instanz möchtest du restlos vom Server entfernen?"
    echo ""
    
    for i in "${!INSTANCES[@]}"; do
        DISP_NAME=$(basename "${INSTANCES[$i]}" | sed 's/notiz-//')
        echo " [$((i+1))] $DISP_NAME (${INSTANCES[$i]})"
    done
    echo " [0] Abbrechen und zurück"
    echo ""
    
    read -p "Bitte gib die Nummer der Instanz ein, die du löschen willst: " DEL_SELECTION

    if [[ "$DEL_SELECTION" == "0" ]]; then
        echo "Abbruch. Es wird nichts gelöscht."
        exit 0
    fi

    if [[ "$DEL_SELECTION" =~ ^[0-9]+$ ]] && [ "$DEL_SELECTION" -gt 0 ] && [ "$DEL_SELECTION" -le "${#INSTANCES[@]}" ]; then
        SELECTED_INDEX=$((DEL_SELECTION-1))
        DEL_DIR="${INSTANCES[$SELECTED_INDEX]}"
        DEL_NAME=$(basename "$DEL_DIR" | sed 's/notiz-//')
        
        echo ""
        echo "⚠️ ACHTUNG: Du bist dabei, die Instanz '$DEL_NAME' komplett zu löschen!"
        echo "Das beinhaltet alle Notizen (data.db), Bilder, Skizzen, Backups und Einstellungen."
        read -p "Bist du absolut sicher? (tippe 'ja' zum Löschen): " CONFIRM_DEL

        if [ "$CONFIRM_DEL" == "ja" ]; then
            if [ "$DEL_NAME" == "tool" ]; then
                SERVICE_NAME="notizen.service"
                CRON_NAME="notizen-tool"
            else
                SERVICE_NAME="notizen-$DEL_NAME.service"
                CRON_NAME="notizen-$DEL_NAME"
            fi

            echo "Stoppe und entferne Service $SERVICE_NAME..."
            systemctl stop "$SERVICE_NAME" 2>/dev/null
            systemctl disable "$SERVICE_NAME" 2>/dev/null
            rm -f "/etc/systemd/system/$SERVICE_NAME"

            echo "Entferne Cronjobs..."
            rm -f "/etc/cron.d/$CRON_NAME"

            echo "Lösche Verzeichnis $DEL_DIR..."
            rm -rf "$DEL_DIR"

            systemctl daemon-reload
            echo "✅ Instanz '$DEL_NAME' wurde restlos und sauber vom Server entfernt."
        else
            echo "Abbruch. Es wurde nichts gelöscht."
        fi
    else
        echo "Ungültige Eingabe. Skript wird beendet."
        exit 1
    fi

else
    echo "Ungültige Eingabe. Skript wird beendet."
    exit 1
fi
