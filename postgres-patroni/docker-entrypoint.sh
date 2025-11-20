#!/bin/bash
set -e

# Clear any stale initialization key from etcd if cluster doesn't exist
# This prevents the "waiting for leader to bootstrap" deadlock
ETCD_ENDPOINTS="${PATRONI_ETCD_HOSTS:-etcd-1.railway.internal:2379,etcd-2.railway.internal:2379,etcd-3.railway.internal:2379}"
SCOPE="${PATRONI_SCOPE:-railway-pg-ha}"

# Try to delete the initialize key (will fail silently if doesn't exist)
for endpoint in $(echo $ETCD_ENDPOINTS | tr ',' ' '); do
  echo "Attempting to clear stale initialize key from $endpoint..."
  curl -X DELETE "http://$endpoint/v2/keys/service/$SCOPE/initialize" 2>/dev/null || true
  break  # Only need one endpoint
done

# Create patroni config using cat heredoc to avoid template issues
cat > /tmp/patroni.yml <<EOF
scope: ${PATRONI_SCOPE:-railway-pg-ha}
name: ${PATRONI_NAME:-postgres-1}

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${PATRONI_NAME:-postgres-1}.railway.internal:8008

etcd:
  hosts: ${PATRONI_ETCD_HOSTS:-etcd-1.railway.internal:2379,etcd-2.railway.internal:2379,etcd-3.railway.internal:2379}

bootstrap:
  method: initdb
  dcs:
    ttl: ${PATRONI_TTL:-30}
    loop_wait: ${PATRONI_LOOP_WAIT:-10}
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: on
        wal_keep_size: 128MB
        max_wal_senders: 10
        max_replication_slots: 10
        checkpoint_timeout: 30
        max_connections: 200
        shared_buffers: 256MB
        effective_cache_size: 1GB
        maintenance_work_mem: 64MB
        wal_buffers: 16MB

  initdb:
    - encoding: UTF8
    - data-checksums
    - locale: en_US.UTF-8

  pg_hba:
    - local all all trust
    - host replication ${PATRONI_REPLICATION_USERNAME:-replicator} 0.0.0.0/0 md5
    - host all all 0.0.0.0/0 md5

  post_bootstrap: /post_bootstrap.sh

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${PATRONI_NAME:-postgres-1}.railway.internal:5432
  data_dir: /var/lib/postgresql/data/pgdata
  remove_data_directory_on_rewind_failure: true
  remove_data_directory_on_diverged_timelines: true
  authentication:
    replication:
      username: ${PATRONI_REPLICATION_USERNAME:-replicator}
      password: ${PATRONI_REPLICATION_PASSWORD:-replicator_password}
    superuser:
      username: ${PATRONI_SUPERUSER_USERNAME:-postgres}
      password: ${PATRONI_SUPERUSER_PASSWORD:-postgres}
  parameters:
    unix_socket_directories: /var/run/postgresql

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF

# Write credentials to file for post_bootstrap script
cat > /tmp/patroni_creds.sh <<CREDEOF
export PATRONI_SUPERUSER_USERNAME="${PATRONI_SUPERUSER_USERNAME:-postgres}"
export PATRONI_SUPERUSER_PASSWORD="${PATRONI_SUPERUSER_PASSWORD:-postgres}"
export PATRONI_REPLICATION_USERNAME="${PATRONI_REPLICATION_USERNAME:-replicator}"
export PATRONI_REPLICATION_PASSWORD="${PATRONI_REPLICATION_PASSWORD:-replicator_password}"
CREDEOF
chmod 600 /tmp/patroni_creds.sh

echo "Starting Patroni with:"
echo "  Scope: ${PATRONI_SCOPE:-railway-pg-ha}"
echo "  Name: ${PATRONI_NAME:-postgres-1}"
echo "  Data dir: /var/lib/postgresql/data/pgdata"

echo ""
echo "Generated config:"
cat /tmp/patroni.yml

# Create pgdata subdirectory inside the volume mount
# Railway mounts volumes as root, so we use a subdirectory that postgres user can own
MOUNT_POINT="/var/lib/postgresql/data"
DATA_DIR="/var/lib/postgresql/data/pgdata"

echo "Checking mount point: $MOUNT_POINT"
ls -ld "$MOUNT_POINT" 2>&1 || echo "Mount point does not exist"

# Create pgdata directory if it doesn't exist
if [ ! -d "$DATA_DIR" ]; then
  echo "Creating data directory: $DATA_DIR"
  mkdir -p "$DATA_DIR" 2>&1 || echo "Warning: Could not create $DATA_DIR (may need to run as root in Dockerfile)"
fi

# Check if we can write to the directory
if [ -w "$DATA_DIR" ]; then
  echo "Data directory is writable: $DATA_DIR"
else
  echo "WARNING: Data directory is not writable by postgres user: $DATA_DIR"
  ls -ld "$DATA_DIR" 2>&1 || echo "Directory does not exist"
fi

# Check for stale cluster data that needs reinit
# For replicas (non-postgres-1), always clean existing data to ensure fresh clone
# This avoids system identifier and timeline mismatch issues
PATRONI_NAME_VAR="${PATRONI_NAME:-postgres-1}"
if [ -f "$DATA_DIR/PG_VERSION" ] && [ "$PATRONI_NAME_VAR" != "postgres-1" ]; then
  echo "Existing PostgreSQL data found on replica node, cleaning to ensure fresh clone..."
  rm -rf "$DATA_DIR"/*
  echo "Data directory cleaned, will clone from leader"
fi

export PATRONI_CONFIG_FILE=/tmp/patroni.yml

exec "$@"
