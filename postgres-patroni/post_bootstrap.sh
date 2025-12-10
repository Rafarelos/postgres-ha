#!/bin/bash
# post_bootstrap.sh - Patroni post-bootstrap script
#
# Runs ONCE after PostgreSQL initialization on the primary node.
# Patroni 4.0+ requires users to be created here (bootstrap.users is deprecated)

set -e

echo "Post-bootstrap: starting..."

# Get credentials from environment
SUPERUSER="${PATRONI_SUPERUSER_USERNAME:-postgres}"
SUPERUSER_PASS="${PATRONI_SUPERUSER_PASSWORD}"
REPL_USER="${PATRONI_REPLICATION_USERNAME:-replicator}"
REPL_PASS="${PATRONI_REPLICATION_PASSWORD}"

echo "Post-bootstrap: creating users..."

# Create superuser and replicator
psql -v ON_ERROR_STOP=1 -U postgres -d postgres <<-EOSQL
    -- Create or update superuser
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${SUPERUSER}') THEN
            CREATE ROLE "${SUPERUSER}" WITH SUPERUSER CREATEDB CREATEROLE LOGIN PASSWORD '${SUPERUSER_PASS}';
        ELSE
            ALTER ROLE "${SUPERUSER}" WITH PASSWORD '${SUPERUSER_PASS}';
        END IF;
    END
    \$\$;

    -- Create replicator user
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${REPL_USER}') THEN
            CREATE ROLE "${REPL_USER}" WITH REPLICATION LOGIN PASSWORD '${REPL_PASS}';
        ELSE
            ALTER ROLE "${REPL_USER}" WITH PASSWORD '${REPL_PASS}';
        END IF;
    END
    \$\$;
EOSQL

echo "Post-bootstrap: users created"

# Generate SSL certificates
echo "Post-bootstrap: generating SSL certificates..."
bash /docker-entrypoint-initdb.d/init-ssl.sh

# Mark bootstrap as complete - patroni-runner.sh checks for this marker
# to distinguish complete bootstrap from stale/failed data
touch "${RAILWAY_VOLUME_MOUNT_PATH:-/var/lib/postgresql/data}/.patroni_bootstrap_complete"

echo "Post-bootstrap completed"
