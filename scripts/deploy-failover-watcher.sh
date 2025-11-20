#!/bin/bash
set -e

cd failover-watcher

echo "Creating failover-watcher service..."
railway service create failover-watcher 2>/dev/null || echo "Service failover-watcher already exists"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⚠️  IMPORTANT: Set Railway API credentials"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Get these from Railway dashboard:"
echo "1. Project Settings → Tokens → Create token"
echo "2. Copy Project ID from URL"
echo "3. Copy Environment ID from URL"
echo ""

read -p "Enter RAILWAY_API_TOKEN: " RAILWAY_API_TOKEN
read -p "Enter RAILWAY_PROJECT_ID: " RAILWAY_PROJECT_ID
read -p "Enter RAILWAY_ENVIRONMENT_ID: " RAILWAY_ENVIRONMENT_ID

echo ""
echo "Setting failover-watcher variables..."
railway variables --service failover-watcher --set RAILWAY_API_TOKEN="$RAILWAY_API_TOKEN"
railway variables --service failover-watcher --set RAILWAY_PROJECT_ID="$RAILWAY_PROJECT_ID"
railway variables --service failover-watcher --set RAILWAY_ENVIRONMENT_ID="$RAILWAY_ENVIRONMENT_ID"
railway variables --service failover-watcher --set CHECK_INTERVAL_MS=5000

echo "Deploying failover-watcher..."
railway up --service failover-watcher --detach

cd ..
echo "✅ failover-watcher deployed"
