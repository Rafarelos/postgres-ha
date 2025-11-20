#!/bin/sh
set -e

# Create data directory subdirectory to avoid lost+found issue
mkdir -p /etcd-data/data
chmod 700 /etcd-data/data

echo "etcd data directory ready: /etcd-data/data"
ls -ld /etcd-data/data

# Start etcd
exec /usr/local/bin/etcd "$@"
