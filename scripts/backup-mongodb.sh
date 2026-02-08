#!/usr/bin/env bash
# MongoDB backup and restore script for Audit RAG Engine
# Usage:
#   Backup:  ./backup-mongodb.sh backup [output_dir]
#   Restore: ./backup-mongodb.sh restore <backup_dir>
#   List:    ./backup-mongodb.sh list [backup_dir]

set -euo pipefail

CONTAINER="audit-mongodb"
DB_NAME="${MONGO_DB:-audit_rag}"
DB_USER="${MONGO_USER:-audit_user}"
DB_PASS="${MONGO_PASS:-audit_pass}"
BACKUP_DIR="${2:-./backups/mongodb}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

backup() {
    mkdir -p "$BACKUP_DIR"
    local DUMP_DIR="$BACKUP_DIR/${DB_NAME}_${TIMESTAMP}"
    local ARCHIVE="$BACKUP_DIR/${DB_NAME}_${TIMESTAMP}.tar.gz"

    echo "==> Backing up MongoDB database: $DB_NAME"
    docker exec "$CONTAINER" mongodump \
        --username="$DB_USER" \
        --password="$DB_PASS" \
        --authenticationDatabase=admin \
        --db="$DB_NAME" \
        --out="/tmp/mongodump_${TIMESTAMP}" \
        --quiet

    # Copy dump from container
    docker cp "$CONTAINER:/tmp/mongodump_${TIMESTAMP}/$DB_NAME" "$DUMP_DIR"
    docker exec "$CONTAINER" rm -rf "/tmp/mongodump_${TIMESTAMP}"

    # Compress
    tar -czf "$ARCHIVE" -C "$BACKUP_DIR" "${DB_NAME}_${TIMESTAMP}"
    rm -rf "$DUMP_DIR"

    local SIZE=$(du -sh "$ARCHIVE" | cut -f1)
    echo "==> Backup complete: $ARCHIVE ($SIZE)"

    # Keep only last 30 backups
    local COUNT=$(ls -1 "$BACKUP_DIR"/${DB_NAME}_*.tar.gz 2>/dev/null | wc -l)
    if [ "$COUNT" -gt 30 ]; then
        echo "==> Pruning old backups (keeping last 30)..."
        ls -1t "$BACKUP_DIR"/${DB_NAME}_*.tar.gz | tail -n +31 | xargs rm -f
    fi
}

restore() {
    local ARCHIVE="$2"
    if [ ! -f "$ARCHIVE" ]; then
        echo "ERROR: Backup file not found: $ARCHIVE"
        exit 1
    fi

    echo "==> WARNING: This will overwrite the current database '$DB_NAME'!"
    read -p "    Continue? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "==> Restore cancelled."
        exit 0
    fi

    echo "==> Restoring MongoDB database from: $ARCHIVE"

    # Extract archive
    local TEMP_DIR=$(mktemp -d)
    tar -xzf "$ARCHIVE" -C "$TEMP_DIR"

    # Find extracted directory
    local DUMP_DIR=$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)

    # Copy to container and restore
    docker cp "$DUMP_DIR" "$CONTAINER:/tmp/mongorestore_data"
    docker exec "$CONTAINER" mongorestore \
        --username="$DB_USER" \
        --password="$DB_PASS" \
        --authenticationDatabase=admin \
        --db="$DB_NAME" \
        --drop \
        "/tmp/mongorestore_data" \
        --quiet

    docker exec "$CONTAINER" rm -rf "/tmp/mongorestore_data"
    rm -rf "$TEMP_DIR"

    echo "==> Restore complete."
}

list_backups() {
    local DIR="${2:-$BACKUP_DIR}"
    echo "==> MongoDB backups in $DIR:"
    if [ -d "$DIR" ]; then
        ls -lh "$DIR"/${DB_NAME}_*.tar.gz 2>/dev/null || echo "    No backups found."
    else
        echo "    Directory not found."
    fi
}

case "${1:-help}" in
    backup)  backup ;;
    restore) restore "$@" ;;
    list)    list_backups "$@" ;;
    *)
        echo "Usage: $0 {backup|restore|list} [args]"
        echo "  backup  [output_dir]    Create a compressed mongodump"
        echo "  restore <backup_file>   Restore from a backup archive"
        echo "  list    [backup_dir]    List available backups"
        ;;
esac
