#!/usr/bin/env bash
# PostgreSQL backup and restore script for Audit Assistant
# Usage:
#   Backup:  ./backup-postgres.sh backup [output_dir]
#   Restore: ./backup-postgres.sh restore <backup_file>
#   List:    ./backup-postgres.sh list [backup_dir]

set -euo pipefail

CONTAINER="audit-postgres"
DB_NAME="${POSTGRES_DB:-audit_api}"
DB_USER="${POSTGRES_USER:-audit_user}"
BACKUP_DIR="${2:-./backups/postgres}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

backup() {
    mkdir -p "$BACKUP_DIR"
    local BACKUP_FILE="$BACKUP_DIR/${DB_NAME}_${TIMESTAMP}.sql.gz"

    echo "==> Backing up PostgreSQL database: $DB_NAME"
    docker exec "$CONTAINER" pg_dump \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        --format=plain \
        --no-owner \
        --no-privileges \
        --verbose \
        2>/dev/null | gzip > "$BACKUP_FILE"

    local SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
    echo "==> Backup complete: $BACKUP_FILE ($SIZE)"

    # Keep only last 30 backups
    local COUNT=$(ls -1 "$BACKUP_DIR"/${DB_NAME}_*.sql.gz 2>/dev/null | wc -l)
    if [ "$COUNT" -gt 30 ]; then
        echo "==> Pruning old backups (keeping last 30)..."
        ls -1t "$BACKUP_DIR"/${DB_NAME}_*.sql.gz | tail -n +31 | xargs rm -f
    fi
}

restore() {
    local BACKUP_FILE="$2"
    if [ ! -f "$BACKUP_FILE" ]; then
        echo "ERROR: Backup file not found: $BACKUP_FILE"
        exit 1
    fi

    echo "==> WARNING: This will overwrite the current database '$DB_NAME'!"
    read -p "    Continue? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "==> Restore cancelled."
        exit 0
    fi

    echo "==> Restoring PostgreSQL database from: $BACKUP_FILE"

    # Drop and recreate database
    docker exec "$CONTAINER" psql -U "$DB_USER" -d postgres \
        -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB_NAME' AND pid <> pg_backend_pid();" \
        2>/dev/null || true
    docker exec "$CONTAINER" psql -U "$DB_USER" -d postgres \
        -c "DROP DATABASE IF EXISTS \"$DB_NAME\";" 2>/dev/null
    docker exec "$CONTAINER" psql -U "$DB_USER" -d postgres \
        -c "CREATE DATABASE \"$DB_NAME\";" 2>/dev/null

    # Restore
    gunzip -c "$BACKUP_FILE" | docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" 2>/dev/null

    echo "==> Restore complete."
}

list_backups() {
    local DIR="${2:-$BACKUP_DIR}"
    echo "==> PostgreSQL backups in $DIR:"
    if [ -d "$DIR" ]; then
        ls -lh "$DIR"/${DB_NAME}_*.sql.gz 2>/dev/null || echo "    No backups found."
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
        echo "  backup  [output_dir]    Create a gzipped SQL dump"
        echo "  restore <backup_file>   Restore from a backup file"
        echo "  list    [backup_dir]    List available backups"
        ;;
esac
