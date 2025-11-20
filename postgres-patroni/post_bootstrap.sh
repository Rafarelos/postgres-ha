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
fi

echo "Configuring users: superuser=$PATRONI_SUPERUSER_USERNAME, replication=$PATRONI_REPLICATION_USERNAME"

# Connect via Unix socket (pg_hba.conf has "local all all trust")
# Database is already running at this point
psql -v ON_ERROR_STOP=1 -U postgres -d postgres <<-EOSQL
    -- Set superuser password
    ALTER USER ${PATRONI_SUPERUSER_USERNAME} WITH PASSWORD '${PATRONI_SUPERUSER_PASSWORD}';

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
