#!/bin/sh
set -e

# Force enable v2 API
export ETCD_ENABLE_V2=true

# Start etcd with original command
exec /usr/local/bin/etcd "$@"
