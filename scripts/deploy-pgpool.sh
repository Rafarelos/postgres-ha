#!/bin/bash
set -e

cd pgpool

echo "Creating pgpool service..."
railway service create pgpool 2>/dev/null || echo "Service pgpool already exists"

echo "Setting pgpool variables..."
railway variables --service pgpool --set 'POSTGRES_PASSWORD=${{shared.POSTGRES_PASSWORD}}'
railway variables --service pgpool --set 'REPLICATION_PASSWORD=${{shared.PATRONI_REPLICATION_PASSWORD}}'
railway variables --service pgpool --set PGPOOL_NUM_INIT_CHILDREN=32
railway variables --service pgpool --set PGPOOL_MAX_POOL=4

echo "Deploying pgpool..."
railway up --service pgpool --detach

cd ..
echo "✅ pgpool deployed"
echo ""
echo "⚠️  Note: Set numReplicas to 3 in Railway dashboard for HA"
echo "   Settings → Deploy → Replicas → 3"
