#!/usr/bin/env bash
# Neo4j backup and restore script for Audit RAG Engine
# Usage:
#   Backup:  ./backup-neo4j.sh backup [output_dir]
#   Restore: ./backup-neo4j.sh restore <backup_file>
#   List:    ./backup-neo4j.sh list [backup_dir]
#
# Note: Neo4j Community Edition does not support online backup.
# This script uses neo4j-admin database dump (requires stopping the DB).
# For production, use Neo4j Enterprise with neo4j-admin backup.

set -euo pipefail

CONTAINER="audit-neo4j"
DB_NAME="neo4j"
BACKUP_DIR="${2:-./backups/neo4j}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

backup() {
    mkdir -p "$BACKUP_DIR"
    local ARCHIVE="$BACKUP_DIR/${DB_NAME}_${TIMESTAMP}.dump.gz"

    echo "==> Backing up Neo4j database: $DB_NAME"
    echo "    NOTE: Neo4j will be briefly stopped for consistent backup."

    # Stop neo4j process inside container
    docker exec "$CONTAINER" neo4j stop 2>/dev/null || true
    sleep 3

    # Dump database
    docker exec "$CONTAINER" neo4j-admin database dump "$DB_NAME" \
        --to-path=/tmp/neo4j_backup 2>/dev/null || {
        echo "==> neo4j-admin dump failed, trying Cypher export fallback..."
        docker exec "$CONTAINER" neo4j start 2>/dev/null
        sleep 5
        _cypher_export_fallback
        return
    }

    # Restart neo4j
    docker exec "$CONTAINER" neo4j start 2>/dev/null
    echo "    Neo4j restarted."

    # Copy dump from container
    docker cp "$CONTAINER:/tmp/neo4j_backup/${DB_NAME}.dump" "$BACKUP_DIR/${DB_NAME}_${TIMESTAMP}.dump"
    docker exec "$CONTAINER" rm -rf /tmp/neo4j_backup
    gzip "$BACKUP_DIR/${DB_NAME}_${TIMESTAMP}.dump"

    local SIZE=$(du -sh "$ARCHIVE" | cut -f1)
    echo "==> Backup complete: $ARCHIVE ($SIZE)"

    # Keep only last 30 backups
    local COUNT=$(ls -1 "$BACKUP_DIR"/${DB_NAME}_*.dump.gz 2>/dev/null | wc -l)
    if [ "$COUNT" -gt 30 ]; then
        echo "==> Pruning old backups (keeping last 30)..."
        ls -1t "$BACKUP_DIR"/${DB_NAME}_*.dump.gz | tail -n +31 | xargs rm -f
    fi
}

_cypher_export_fallback() {
    # Fallback: export all nodes and relationships via Cypher
    local ARCHIVE="$BACKUP_DIR/${DB_NAME}_${TIMESTAMP}_cypher.json.gz"
    echo "==> Using Cypher export fallback..."

    docker exec "$CONTAINER" cypher-shell \
        -u neo4j -p audit_pass \
        "CALL apoc.export.json.all(null, {stream: true}) YIELD data RETURN data" \
        2>/dev/null | gzip > "$ARCHIVE" || {
        echo "==> Cypher export also failed. Please use Neo4j Browser to export manually."
        return 1
    }

    local SIZE=$(du -sh "$ARCHIVE" | cut -f1)
    echo "==> Cypher export complete: $ARCHIVE ($SIZE)"
}

restore() {
    local BACKUP_FILE="$2"
    if [ ! -f "$BACKUP_FILE" ]; then
        echo "ERROR: Backup file not found: $BACKUP_FILE"
        exit 1
    fi

    echo "==> WARNING: This will overwrite the current Neo4j database!"
    read -p "    Continue? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "==> Restore cancelled."
        exit 0
    fi

    echo "==> Restoring Neo4j database from: $BACKUP_FILE"

    # Decompress if gzipped
    local DUMP_FILE="$BACKUP_FILE"
    if [[ "$BACKUP_FILE" == *.gz ]]; then
        DUMP_FILE="/tmp/neo4j_restore_${TIMESTAMP}.dump"
        gunzip -c "$BACKUP_FILE" > "$DUMP_FILE"
    fi

    # Stop neo4j
    docker exec "$CONTAINER" neo4j stop 2>/dev/null || true
    sleep 3

    # Copy dump to container and load
    docker cp "$DUMP_FILE" "$CONTAINER:/tmp/restore.dump"
    docker exec "$CONTAINER" neo4j-admin database load "$DB_NAME" \
        --from-path=/tmp --overwrite-destination 2>/dev/null

    # Cleanup
    docker exec "$CONTAINER" rm -f /tmp/restore.dump
    [ "$DUMP_FILE" != "$BACKUP_FILE" ] && rm -f "$DUMP_FILE"

    # Restart neo4j
    docker exec "$CONTAINER" neo4j start 2>/dev/null
    echo "==> Restore complete. Neo4j restarted."
}

list_backups() {
    local DIR="${2:-$BACKUP_DIR}"
    echo "==> Neo4j backups in $DIR:"
    if [ -d "$DIR" ]; then
        ls -lh "$DIR"/${DB_NAME}_*.dump.gz "$DIR"/${DB_NAME}_*_cypher.json.gz 2>/dev/null || echo "    No backups found."
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
        echo "  backup  [output_dir]    Dump Neo4j database (requires brief stop)"
        echo "  restore <backup_file>   Restore from a dump file"
        echo "  list    [backup_dir]    List available backups"
        ;;
esac
