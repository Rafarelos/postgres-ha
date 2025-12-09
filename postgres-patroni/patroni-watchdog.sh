#!/bin/bash
# patroni-watchdog.sh - Application-level watchdog for Patroni
#
# This script monitors Patroni's health and handles split-brain prevention:
# - If PRIMARY and can't reach Patroni for TTL seconds: demote to read-only
# - If REPLICA and can't reach Patroni: keep running (already safe)
#
# Part of RFC-007: Split-Brain Prevention
# Enhanced with RFC-008: Watchdog Hardening

set -e

PATRONI_API_BASE="${PATRONI_API_BASE:-http://localhost:8008}"
PATRONI_API="${PATRONI_API_BASE}/health"
PATRONI_STATUS_API="${PATRONI_API_BASE}/patroni"
CHECK_INTERVAL="${WATCHDOG_CHECK_INTERVAL:-5}"
PGDATA="${PGDATA:-/var/lib/postgresql/data}"

# TTL should match Patroni's ttl setting - this is how long a leader key is valid
# Only demote primary after TTL expires to respect leadership lease
LEADERSHIP_TTL="${PATRONI_TTL:-45}"

# Curl timeout settings
CURL_TIMEOUT="${WATCHDOG_CURL_TIMEOUT:-5}"
CURL_CONNECT_TIMEOUT="${WATCHDOG_CURL_CONNECT_TIMEOUT:-5}"

failure_start_time=""
last_known_role="unknown"
consecutive_successes=0
demoted=false

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WATCHDOG: $1"
}

get_current_role() {
    local response
    response=$(curl -sf --max-time "$CURL_TIMEOUT" --connect-timeout "$CURL_CONNECT_TIMEOUT" "$PATRONI_STATUS_API" 2>/dev/null) || return 1
    echo "$response" | grep -o '"role":"[^"]*"' | cut -d'"' -f4
}

demote_to_readonly() {
    log "Demoting PostgreSQL to read-only mode..."

    # Set default_transaction_read_only to prevent new write transactions
    if [ -S /var/run/postgresql/.s.PGSQL.5432 ]; then
        psql -h /var/run/postgresql -U postgres -c "ALTER SYSTEM SET default_transaction_read_only = on;" 2>/dev/null || true
        psql -h /var/run/postgresql -U postgres -c "SELECT pg_reload_conf();" 2>/dev/null || true
        log "PostgreSQL set to read-only mode"
    else
        log "WARNING: Could not connect to PostgreSQL to set read-only mode"
    fi
}

restore_readwrite() {
    if [ "$demoted" = "true" ]; then
        log "Restoring PostgreSQL to read-write mode..."
        if [ -S /var/run/postgresql/.s.PGSQL.5432 ]; then
            psql -h /var/run/postgresql -U postgres -c "ALTER SYSTEM RESET default_transaction_read_only;" 2>/dev/null || true
            psql -h /var/run/postgresql -U postgres -c "SELECT pg_reload_conf();" 2>/dev/null || true
            log "PostgreSQL restored to read-write mode"
        fi
        demoted=false
    fi
}

log "Starting Patroni watchdog"
log "  API endpoint: $PATRONI_API"
log "  Check interval: ${CHECK_INTERVAL}s"
log "  Leadership TTL: ${LEADERSHIP_TTL}s"
log "  Curl timeout: ${CURL_TIMEOUT}s (connect: ${CURL_CONNECT_TIMEOUT}s)"

# Wait for Patroni to start initially
sleep 10

while true; do
    current_role=$(get_current_role)

    if [ -n "$current_role" ]; then
        # Patroni is healthy
        if [ -n "$failure_start_time" ]; then
            log "Patroni recovered (role: $current_role)"
            restore_readwrite
        fi

        failure_start_time=""
        last_known_role="$current_role"
        ((consecutive_successes++)) || true

        # Log periodically
        if [ $consecutive_successes -eq 1 ] || [ $((consecutive_successes % 60)) -eq 0 ]; then
            log "Patroni healthy (role: $current_role, checks: $consecutive_successes)"
        fi
    else
        # Patroni is unreachable
        consecutive_successes=0

        if [ -z "$failure_start_time" ]; then
            failure_start_time=$(date +%s)
            log "Patroni health check failed (last known role: $last_known_role)"
        fi

        elapsed=$(($(date +%s) - failure_start_time))
        log "Patroni unreachable for ${elapsed}s (TTL: ${LEADERSHIP_TTL}s, last role: $last_known_role)"

        if [ "$last_known_role" = "master" ] || [ "$last_known_role" = "primary" ]; then
            # Primary node: wait for TTL to expire before demoting
            if [ $elapsed -ge $LEADERSHIP_TTL ] && [ "$demoted" = "false" ]; then
                log "CRITICAL: Primary lost Patroni contact for ${elapsed}s (>= TTL ${LEADERSHIP_TTL}s)"
                log "Demoting to prevent split-brain..."
                demote_to_readonly
                demoted=true
            fi
        else
            # Replica node: safe to keep running, just log
            if [ $((elapsed % 30)) -lt $CHECK_INTERVAL ]; then
                log "Replica mode - continuing operation despite Patroni being unreachable"
            fi
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
