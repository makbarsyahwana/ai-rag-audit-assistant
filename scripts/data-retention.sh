#!/usr/bin/env bash
# Data retention policy enforcement script
# Usage: ./data-retention.sh [--dry-run]
#
# Retention policies:
#   - Query logs & retrieval events: 365 days
#   - Agent memory checkpoints: 90 days
#   - Ingestion job records (completed): 180 days
#   - MongoDB chunks for deleted documents: immediate
#   - Neo4j orphaned nodes: immediate
#   - Backup files: 30 days (handled by backup scripts)
#
# Schedule via cron: 0 2 * * 0 /path/to/data-retention.sh >> /var/log/retention.log 2>&1

set -euo pipefail

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=true
    echo "==> DRY RUN MODE — no data will be deleted"
fi

POSTGRES_CONTAINER="audit-postgres"
MONGODB_CONTAINER="audit-mongodb"
NEO4J_CONTAINER="audit-neo4j"

DB_USER="${POSTGRES_USER:-audit_user}"
DB_NAME="${POSTGRES_DB:-audit_api}"
MONGO_USER="${MONGO_USER:-audit_user}"
MONGO_PASS="${MONGO_PASS:-audit_pass}"
MONGO_DB="${MONGO_DB:-audit_rag}"

echo "============================================"
echo "  Data Retention Policy Enforcement"
echo "  $(date -Iseconds)"
echo "============================================"

# -----------------------------------------------------------------------
# 1. PostgreSQL: Query logs older than 365 days
# -----------------------------------------------------------------------
echo ""
echo "--- PostgreSQL: Query Logs (365-day retention) ---"
PG_QUERY_COUNT=$(docker exec "$POSTGRES_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT COUNT(*) FROM \"QueryLog\" WHERE \"createdAt\" < NOW() - INTERVAL '365 days';" 2>/dev/null || echo "0")
echo "    Records to purge: $PG_QUERY_COUNT"

if [ "$DRY_RUN" = false ] && [ "$PG_QUERY_COUNT" -gt 0 ] 2>/dev/null; then
    docker exec "$POSTGRES_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c \
        "DELETE FROM \"QueryLog\" WHERE \"createdAt\" < NOW() - INTERVAL '365 days';" 2>/dev/null
    echo "    Purged $PG_QUERY_COUNT query log records."
fi

# -----------------------------------------------------------------------
# 2. PostgreSQL: Retrieval events older than 365 days
# -----------------------------------------------------------------------
echo ""
echo "--- PostgreSQL: Retrieval Events (365-day retention) ---"
PG_EVENT_COUNT=$(docker exec "$POSTGRES_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT COUNT(*) FROM \"RetrievalEvent\" WHERE \"createdAt\" < NOW() - INTERVAL '365 days';" 2>/dev/null || echo "0")
echo "    Records to purge: $PG_EVENT_COUNT"

if [ "$DRY_RUN" = false ] && [ "$PG_EVENT_COUNT" -gt 0 ] 2>/dev/null; then
    docker exec "$POSTGRES_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c \
        "DELETE FROM \"RetrievalEvent\" WHERE \"createdAt\" < NOW() - INTERVAL '365 days';" 2>/dev/null
    echo "    Purged $PG_EVENT_COUNT retrieval event records."
fi

# -----------------------------------------------------------------------
# 3. PostgreSQL: LangGraph checkpoints older than 90 days
# -----------------------------------------------------------------------
echo ""
echo "--- PostgreSQL: Agent Checkpoints (90-day retention) ---"
PG_CHECKPOINT_COUNT=$(docker exec "$POSTGRES_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT COUNT(*) FROM checkpoints WHERE created_at < NOW() - INTERVAL '90 days';" 2>/dev/null || echo "table_missing")

if [ "$PG_CHECKPOINT_COUNT" = "table_missing" ]; then
    echo "    Checkpoints table not found — skipping."
else
    echo "    Records to purge: $PG_CHECKPOINT_COUNT"
    if [ "$DRY_RUN" = false ] && [ "$PG_CHECKPOINT_COUNT" -gt 0 ] 2>/dev/null; then
        docker exec "$POSTGRES_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c \
            "DELETE FROM checkpoints WHERE created_at < NOW() - INTERVAL '90 days';" 2>/dev/null
        echo "    Purged $PG_CHECKPOINT_COUNT checkpoint records."
    fi
fi

# -----------------------------------------------------------------------
# 4. MongoDB: Orphaned chunks (document_id not in documents collection)
# -----------------------------------------------------------------------
echo ""
echo "--- MongoDB: Orphaned Chunks ---"
ORPHAN_COUNT=$(docker exec "$MONGODB_CONTAINER" mongosh \
    --username "$MONGO_USER" --password "$MONGO_PASS" --authenticationDatabase admin \
    --quiet --eval "
    use('$MONGO_DB');
    const docIds = db.documents.distinct('document_id');
    db.chunks.countDocuments({ document_id: { \$nin: docIds } });
    " 2>/dev/null || echo "0")
echo "    Orphaned chunks: $ORPHAN_COUNT"

if [ "$DRY_RUN" = false ] && [ "$ORPHAN_COUNT" -gt 0 ] 2>/dev/null; then
    docker exec "$MONGODB_CONTAINER" mongosh \
        --username "$MONGO_USER" --password "$MONGO_PASS" --authenticationDatabase admin \
        --quiet --eval "
        use('$MONGO_DB');
        const docIds = db.documents.distinct('document_id');
        const result = db.chunks.deleteMany({ document_id: { \$nin: docIds } });
        print('Deleted ' + result.deletedCount + ' orphaned chunks.');
        " 2>/dev/null
fi

# -----------------------------------------------------------------------
# 5. MongoDB: Ingestion jobs older than 180 days
# -----------------------------------------------------------------------
echo ""
echo "--- MongoDB: Old Ingestion Jobs (180-day retention) ---"
CUTOFF_DATE=$(date -v-180d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -d "180 days ago" --iso-8601=seconds 2>/dev/null || echo "")
if [ -n "$CUTOFF_DATE" ]; then
    OLD_JOB_COUNT=$(docker exec "$MONGODB_CONTAINER" mongosh \
        --username "$MONGO_USER" --password "$MONGO_PASS" --authenticationDatabase admin \
        --quiet --eval "
        use('$MONGO_DB');
        db.ingestion_jobs.countDocuments({
            status: 'completed',
            created_at: { \$lt: new Date('$CUTOFF_DATE') }
        });
        " 2>/dev/null || echo "0")
    echo "    Old completed jobs: $OLD_JOB_COUNT"

    if [ "$DRY_RUN" = false ] && [ "$OLD_JOB_COUNT" -gt 0 ] 2>/dev/null; then
        docker exec "$MONGODB_CONTAINER" mongosh \
            --username "$MONGO_USER" --password "$MONGO_PASS" --authenticationDatabase admin \
            --quiet --eval "
            use('$MONGO_DB');
            const result = db.ingestion_jobs.deleteMany({
                status: 'completed',
                created_at: { \$lt: new Date('$CUTOFF_DATE') }
            });
            print('Deleted ' + result.deletedCount + ' old ingestion jobs.');
            " 2>/dev/null
    fi
else
    echo "    Could not compute cutoff date — skipping."
fi

# -----------------------------------------------------------------------
# 6. Neo4j: Orphaned Chunk nodes (no BELONGS_TO relationship)
# -----------------------------------------------------------------------
echo ""
echo "--- Neo4j: Orphaned Chunk Nodes ---"
NEO4J_ORPHAN_COUNT=$(docker exec "$NEO4J_CONTAINER" cypher-shell \
    -u neo4j -p audit_pass \
    "MATCH (c:Chunk) WHERE NOT (c)-[:BELONGS_TO]->() RETURN count(c) AS cnt;" \
    2>/dev/null | tail -1 || echo "0")
echo "    Orphaned chunks: $NEO4J_ORPHAN_COUNT"

if [ "$DRY_RUN" = false ] && [ "$NEO4J_ORPHAN_COUNT" -gt 0 ] 2>/dev/null; then
    docker exec "$NEO4J_CONTAINER" cypher-shell \
        -u neo4j -p audit_pass \
        "MATCH (c:Chunk) WHERE NOT (c)-[:BELONGS_TO]->() DETACH DELETE c;" \
        2>/dev/null
    echo "    Deleted orphaned chunk nodes."
fi

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
echo "============================================"
echo "  Retention enforcement complete."
if [ "$DRY_RUN" = true ]; then
    echo "  (DRY RUN — no changes made)"
fi
echo "  $(date -Iseconds)"
echo "============================================"
