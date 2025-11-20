#!/bin/bash
set -e

echo "Setting up data directory permissions..."
mkdir -p /var/lib/postgresql/data/pgdata
chown -R postgres:postgres /var/lib/postgresql/data/pgdata
chmod 700 /var/lib/postgresql/data/pgdata
echo "Data directory ready: /var/lib/postgresql/data/pgdata"
ls -ld /var/lib/postgresql/data/pgdata

# Switch to postgres user and run the entrypoint
exec su-exec postgres /docker-entrypoint.sh "$@"
