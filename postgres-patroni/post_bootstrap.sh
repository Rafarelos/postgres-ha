#!/bin/bash
set -e

echo "Post-bootstrap script starting..."

# Source credentials file created by entrypoint
if [ -f /tmp/patroni_creds.sh ]; then
    source /tmp/patroni_creds.sh
    echo "Loaded credentials from /tmp/patroni_creds.sh"
else
    echo "WARNING: Credentials file not found, using defaults"
    export PATRONI_SUPERUSER_USERNAME="postgres"
    export PATRONI_SUPERUSER_PASSWORD="postgres"
    export PATRONI_REPLICATION_USERNAME="replicator"
    export PATRONI_REPLICATION_PASSWORD="replicator_password"
    export POSTGRES_DB=""
fi

echo "Configuring users: superuser=$PATRONI_SUPERUSER_USERNAME, replication=$PATRONI_REPLICATION_USERNAME"

# Connect via Unix socket (pg_hba.conf has "local all all trust")
psql -v ON_ERROR_STOP=1 -U postgres -d postgres <<-EOSQL
    -- Create superuser if different from postgres (e.g., POSTGRES_USER=railway)
    DO \$\$
    BEGIN
        IF '${PATRONI_SUPERUSER_USERNAME}' != 'postgres' THEN
            IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${PATRONI_SUPERUSER_USERNAME}') THEN
                CREATE ROLE ${PATRONI_SUPERUSER_USERNAME} WITH SUPERUSER CREATEDB CREATEROLE LOGIN PASSWORD '${PATRONI_SUPERUSER_PASSWORD}';
            ELSE
                ALTER USER ${PATRONI_SUPERUSER_USERNAME} WITH PASSWORD '${PATRONI_SUPERUSER_PASSWORD}';
            END IF;
        ELSE
            ALTER USER postgres WITH PASSWORD '${PATRONI_SUPERUSER_PASSWORD}';
        END IF;
    END
    \$\$;

    -- Create replicator user for streaming replication
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${PATRONI_REPLICATION_USERNAME}') THEN
            CREATE ROLE ${PATRONI_REPLICATION_USERNAME} WITH REPLICATION PASSWORD '${PATRONI_REPLICATION_PASSWORD}' LOGIN;
        END IF;
    END
    \$\$;
EOSQL

echo "Database users configured successfully"

# Create POSTGRES_DB if specified and different from postgres
if [ -n "$POSTGRES_DB" ] && [ "$POSTGRES_DB" != "postgres" ]; then
    echo "Creating database: $POSTGRES_DB owned by $PATRONI_SUPERUSER_USERNAME"
    psql -v ON_ERROR_STOP=1 -U postgres -d postgres <<-EOSQL
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_database WHERE datname = '${POSTGRES_DB}') THEN
                CREATE DATABASE "${POSTGRES_DB}" OWNER "${PATRONI_SUPERUSER_USERNAME}";
            END IF;
        END
        \$\$;
EOSQL
    echo "Database $POSTGRES_DB created"
fi

# Run initialization scripts from /docker-entrypoint-initdb.d/
# This matches standard postgres image behavior
INITDB_DIR="/docker-entrypoint-initdb.d"
if [ -d "$INITDB_DIR" ]; then
    echo "Running initialization scripts from $INITDB_DIR..."

    for f in "$INITDB_DIR"/*; do
        case "$f" in
            *.sh)
                if [ -x "$f" ]; then
                    echo "Running: $f"
                    "$f"
                else
                    echo "Sourcing: $f"
                    . "$f"
                fi
                ;;
            *.sql)
                echo "Running SQL: $f"
                psql -v ON_ERROR_STOP=1 -U postgres -d "${POSTGRES_DB:-postgres}" -f "$f"
                ;;
            *.sql.gz)
                echo "Running compressed SQL: $f"
                gunzip -c "$f" | psql -v ON_ERROR_STOP=1 -U postgres -d "${POSTGRES_DB:-postgres}"
                ;;
            *)
                echo "Ignoring: $f (not .sh, .sql, or .sql.gz)"
                ;;
        esac
    done

    echo "Initialization scripts completed"
fi

echo "Post-bootstrap completed successfully"
