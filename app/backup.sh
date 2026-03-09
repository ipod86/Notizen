#!/bin/bash
cd "$(dirname "$0")" || exit
if [ -f data.db ]; then
    /usr/bin/sqlite3 data.db ".backup 'data.db.backup'"
    /bin/tar -czf backups/backup_$(date +%u).tar.gz data.db.backup uploads/
    rm data.db.backup
fi
