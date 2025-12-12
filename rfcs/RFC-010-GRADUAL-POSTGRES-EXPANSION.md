# RFC-010: Gradual PostgreSQL Expansion via Data UI

**Status**: Draft
**Created**: 2025-12-08
**Updated**: 2025-12-12
**Author**: Platform Team

## Overview

This RFC proposes a user-facing feature that allows customers to gradually expand their PostgreSQL infrastructure through the Railway Data UI. Users start with a single PostgreSQL instance and can progressively add components—connection pooling (PgBouncer), read replicas with load balancing (HAProxy), and full high availability (HA) mode with Patroni—as their needs grow.

## Motivation

Currently, deploying a highly-available PostgreSQL cluster requires:
1. Deep understanding of Patroni, etcd, and HAProxy architecture
2. Manual deployment of 7+ services (3 etcd, 3 PostgreSQL, 1+ HAProxy)
3. Careful coordination of environment variables and networking
4. Significant upfront cost even for simple use cases

Most users don't need full HA from day one. They start with a single database and want to scale incrementally as their application grows. This RFC enables that journey through a simple UI-driven workflow.

## Implementation Status

This RFC reflects the **actual implemented architecture**:
- ✅ **HAProxy** for load balancing and read/write routing (health-check based)
- ✅ **Patroni** for PostgreSQL cluster management and automatic failover
- ✅ **etcd** for distributed consensus and leader election
- ✅ **PgBouncer** for connection pooling (optional, standalone)
- ❌ **Pgpool-II** was evaluated but abandoned due to operational complexity

## Goals

1. **Progressive Complexity**: Users pay only for what they need
2. **Zero-Downtime Upgrades**: Each expansion step maintains availability
3. **Reversibility**: Users can scale down (with appropriate warnings)
4. **Transparency**: Clear visibility into current topology and costs
5. **Automation**: One-click expansion with sensible defaults

## Non-Goals

- Multi-region PostgreSQL (separate RFC)
- Automatic scaling based on load (future enhancement)
- Migration from external PostgreSQL providers
- Support for PostgreSQL versions older than 15

---

## Expansion Stages

### Stage 0: Single PostgreSQL Instance (Baseline)

**Components**: 1 PostgreSQL service

```
┌─────────────────────────┐
│   Application           │
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│   PostgreSQL (Primary)  │
│   └─ Volume: 10GB       │
└─────────────────────────┘
```

**Characteristics**:
- Standard Railway PostgreSQL deployment
- No HA, no connection pooling
- Direct connection to database
- Suitable for development and low-traffic production

**Data UI Tab**: Shows database metrics, query logs, basic monitoring

---

### Stage 1: Add Connection Pooling (PgBouncer)

**Components**: 1 PostgreSQL + 1 PgBouncer

```
┌─────────────────────────┐
│   Application           │
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│   PgBouncer             │
│   └─ 100 connections    │
│   └─ Transaction mode   │
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│   PostgreSQL (Primary)  │
│   └─ Volume: 10GB       │
└─────────────────────────┘
```

**User Action**: Click "Add Connection Pooling" in Data UI

**What Happens**:
1. System deploys PgBouncer service
2. PgBouncer configured to connect to existing PostgreSQL
3. New connection string provided (pgbouncer endpoint)
4. Original PostgreSQL endpoint remains available (optional direct access)

**Benefits**:
- Lightweight connection pooling (~2MB memory footprint)
- Transaction pooling mode for maximum efficiency
- Reduces PostgreSQL connection overhead
- Handles connection spikes gracefully

**Configuration Options** (shown in UI):
| Setting | Default | Description |
|---------|---------|-------------|
| Pool Mode | transaction | session, transaction, or statement |
| Default Pool Size | 20 | Server connections per user/database |
| Max Client Connections | 100 | Maximum client connections |
| Reserve Pool Size | 5 | Extra connections for burst handling |

**Estimated Additional Cost**: ~$3/month (0.25 vCPU, 256MB RAM)

> **Note**: Connection pooling is independent of load balancing. PgBouncer handles connection multiplexing, while HAProxy (added in later stages) handles routing to primary/replicas.

---

### Stage 2: Add Read Replica(s) with HAProxy

**Components**: 1 PostgreSQL Primary + N PostgreSQL Replicas + 1 HAProxy + (optional) PgBouncer

```
┌─────────────────────────┐
│   Application           │
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│   HAProxy               │
│   ├─ :5432 → Primary    │  (via /primary health check)
│   └─ :5433 → Replicas   │  (via /replica health check)
└───────────┬─────────────┘
            │
    ┌───────┴───────┐
    ▼               ▼
┌─────────┐   ┌─────────────┐
│ Primary │   │ Replica (1) │
│ (r/w)   │──▶│ (read-only) │
│ :8008   │   │ :8008       │  ← Patroni REST API
└─────────┘   └─────────────┘
     streaming replication
```

**User Action**: Click "Add Read Replica" in Data UI

**What Happens**:
1. System provisions new PostgreSQL service with Patroni
2. Configures streaming replication from primary
3. Deploys HAProxy with health-check based routing
4. HAProxy uses Patroni REST API to determine primary vs replica

**Technical Implementation**:
```yaml
# New replica configuration (Patroni handles this automatically)
postgresql:
  parameters:
    hot_standby: on
    wal_level: replica
    max_wal_senders: 10
    max_replication_slots: 10
```

**HAProxy Configuration**:
```conf
# Read-write traffic to primary only
frontend postgres_rw
    bind *:5432
    default_backend postgres_primary

backend postgres_primary
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server postgres-1 postgres-1.railway.internal:5432 check port 8008
    server postgres-2 postgres-2.railway.internal:5432 check port 8008

# Read-only traffic load balanced across replicas
frontend postgres_ro
    bind *:5433
    default_backend postgres_replicas

backend postgres_replicas
    option httpchk GET /replica
    http-check expect status 200
    balance roundrobin
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server postgres-1 postgres-1.railway.internal:5432 check port 8008
    server postgres-2 postgres-2.railway.internal:5432 check port 8008
```

**Configuration Options**:
| Setting | Default | Options |
|---------|---------|---------|
| Number of Replicas | 1 | 1-5 |
| Replica Region | Same as primary | Multi-region (future) |
| Replication Mode | Async | Async, Sync |
| Read Load Balancing | Round-robin | Round-robin, Least-connections |

**Benefits**:
- Health-check based routing (no query parsing overhead)
- Automatic primary detection via Patroni REST API
- Offload read queries to replicas via port 5433
- Disaster recovery standby
- Near-zero replication lag (async mode)

**Estimated Additional Cost**: ~$20/month
- 1× PostgreSQL Replica: ~$15/month (1 vCPU, 1GB RAM, 10GB volume)
- 1× HAProxy: ~$5/month (0.5 vCPU, 512MB RAM)

---

### Stage 3: Enable High Availability Mode

**Components**: 3 etcd + 3 PostgreSQL (Patroni) + 3 HAProxy replicas + (optional) PgBouncer

```
┌─────────────────────────────────────────────────────┐
│                    Application                       │
└───────────────────────┬─────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────┐
│              HAProxy (3 replicas)                    │
│   ┌─────────┐  ┌─────────┐  ┌─────────┐             │
│   │haproxy-1│  │haproxy-2│  │haproxy-3│             │
│   │ :5432   │  │ :5432   │  │ :5432   │  (r/w)      │
│   │ :5433   │  │ :5433   │  │ :5433   │  (r/o)      │
│   │ :8404   │  │ :8404   │  │ :8404   │  (stats)    │
│   └────┬────┘  └────┬────┘  └────┬────┘             │
│        └────────────┼───────────┘                   │
└─────────────────────┼───────────────────────────────┘
                      │ Health checks via Patroni REST API
     ┌────────────────┼────────────────┐
     ▼                ▼                ▼
┌─────────┐     ┌─────────┐     ┌─────────┐
│postgres-1│    │postgres-2│    │postgres-3│
│ (Leader) │◀──▶│(Standby) │◀──▶│(Standby) │
│ Patroni  │    │ Patroni  │    │ Patroni  │
│ :5432    │    │ :5432    │    │ :5432    │
│ :8008    │    │ :8008    │    │ :8008    │ ← REST API
└────┬─────┘    └────┬─────┘    └────┬─────┘
     │               │               │
     └───────────────┼───────────────┘
                     │ Leader Election via etcd
     ┌───────────────┼───────────────┐
     ▼               ▼               ▼
┌─────────┐   ┌─────────┐   ┌─────────┐
│ etcd-1  │◀─▶│ etcd-2  │◀─▶│ etcd-3  │
│ :2379   │   │ :2379   │   │ :2379   │  (client)
│ :2380   │   │ :2380   │   │ :2380   │  (peer)
└─────────┘   └─────────┘   └─────────┘
          Distributed Consensus (Raft)
```

**User Action**: Click "Enable High Availability" in Data UI

**What Happens** (Orchestrated Migration):

#### Phase 1: Deploy etcd Cluster (5-10 min)
1. Provision 3 etcd services (v3.6.6)
2. Leader-elected bootstrap (alphabetically-first node initializes)
3. Wait for quorum establishment
4. Health check: `etcdctl endpoint health`

#### Phase 2: Convert Primary to Patroni (10-15 min)
1. Create maintenance window notification
2. Take snapshot of existing PostgreSQL
3. Deploy new Patroni-enabled PostgreSQL (postgres-1)
4. Restore data from snapshot
5. Validate data integrity
6. Update HAProxy to point to new primary
7. Deprecate old PostgreSQL service

#### Phase 3: Bootstrap Standby Nodes (10-15 min per node)
1. Deploy postgres-2, postgres-3 as Patroni standbys
2. Patroni automatically configures streaming replication
3. Wait for initial sync completion (pg_basebackup)
4. Register with etcd cluster

#### Phase 4: Scale HAProxy (5 min)
1. Scale HAProxy to 3 replicas for load balancer redundancy
2. Configure DNS/service discovery to all HAProxy instances
3. Verify health checks against all Patroni nodes

#### Phase 5: Finalization (2 min)
1. Run full health check (`/cluster` endpoint)
2. Test failover (optional, user-initiated via `POST /switchover`)
3. Update connection strings
4. Send completion notification

**Total Migration Time**: ~45-60 minutes (mostly automated)

**Configuration Options**:
| Setting | Default | Options |
|---------|---------|---------|
| Failover Time | <30s | 10s, 30s, 60s (TTL tuning) |
| Replication Mode | Async | Async, Sync (1 node), Sync (all) |
| Auto-Failback | Disabled | Enabled, Disabled |
| Maximum Lag on Failover | 1MB | 0 (sync only), 1MB, 10MB, unlimited |

**Benefits**:
- Automatic failover (~10-30 seconds typical)
- Zero-downtime leader election via etcd consensus
- Split-brain prevention (DCS quorum required)
- Self-healing cluster (Patroni auto-reinitializes failed nodes)
- Production-grade reliability
- HAProxy stats dashboard on port 8404

**Estimated Additional Cost**: ~$60/month total
- 3× etcd nodes: ~$15 (3 × 0.5 vCPU, 512MB)
- 3× PostgreSQL + Patroni: ~$45 (3 × 1 vCPU, 1GB, 10GB volume)
- 3× HAProxy replicas: ~$15 (3 × 0.5 vCPU, 512MB)
- Less existing single-node cost

> **Architecture Note**: This matches the production-deployed architecture in `postgres-ha` repository using Patroni 4.1.0, etcd 3.6.6, and HAProxy 3.2.

---

## Data UI Design

### Database Service Page - New "Scale" Tab

```
┌──────────────────────────────────────────────────────────────────┐
│  PostgreSQL: my-app-db                                           │
├──────────────────────────────────────────────────────────────────┤
│  [Overview] [Metrics] [Query Logs] [Backups] [Scale] [Settings]  │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Current Topology                                                │
│  ─────────────────                                               │
│                                                                  │
│  ┌─────────────┐                                                 │
│  │  Primary    │  ● postgres-primary                             │
│  │  10GB SSD   │    us-east-1                                    │
│  └─────────────┘                                                 │
│                                                                  │
│  ─────────────────────────────────────────────────────────────── │
│                                                                  │
│  Expansion Options                                               │
│  ─────────────────                                               │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ ◉ Connection Pooling                       [Add PgBouncer]│   │
│  │   Recommended for: 50+ concurrent connections             │   │
│  │   Adds: 1 PgBouncer service (~$3/mo)                     │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ ◉ Read Replica + Load Balancing           [Add Replica]   │   │
│  │   Recommended for: Read-heavy workloads                   │   │
│  │   Adds: 1 PostgreSQL replica + HAProxy (~$20/mo)         │   │
│  │   Features: Read/write splitting via health checks        │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ ◎ High Availability                       [Enable HA]     │   │
│  │   Recommended for: Production workloads                   │   │
│  │   Adds: 3 etcd, 3 PostgreSQL, 3 HAProxy (~$60/mo total)  │   │
│  │   Features: Auto-failover, split-brain prevention         │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### Stage 3 (HA Mode) - Expanded View

```
┌──────────────────────────────────────────────────────────────────┐
│  PostgreSQL: my-app-db (High Availability)                       │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Cluster Status: ● Healthy                    [Manage Cluster]   │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  CONSENSUS LAYER (etcd)                                     ││
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐                       ││
│  │  │ etcd-1  │ │ etcd-2  │ │ etcd-3  │                       ││
│  │  │ ● Leader│ │ ○ Follow│ │ ○ Follow│                       ││
│  │  └─────────┘ └─────────┘ └─────────┘                       ││
│  └─────────────────────────────────────────────────────────────┘│
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  DATABASE LAYER (PostgreSQL + Patroni)                      ││
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐           ││
│  │  │ postgres-1  │ │ postgres-2  │ │ postgres-3  │           ││
│  │  │ ★ Primary   │ │ ○ Standby   │ │ ○ Standby   │           ││
│  │  │ Lag: 0      │ │ Lag: 24KB   │ │ Lag: 24KB   │           ││
│  │  └─────────────┘ └─────────────┘ └─────────────┘           ││
│  │                                                             ││
│  │  [Switchover to postgres-2 ▾]  [Reinitialize Node ▾]       ││
│  └─────────────────────────────────────────────────────────────┘│
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  ROUTING LAYER (HAProxy)                                    ││
│  │  Replicas: 3    Port 5432 (r/w) │ Port 5433 (r/o)          ││
│  │  Backend Status: 3/3 healthy    [View Stats Dashboard]      ││
│  └─────────────────────────────────────────────────────────────┘│
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  CONNECTION POOLING (PgBouncer) - Optional                  ││
│  │  Status: Not enabled            [Add PgBouncer]             ││
│  └─────────────────────────────────────────────────────────────┘│
│                                                                  │
│  Recent Events                                                   │
│  ─────────────                                                   │
│  • 2 hours ago: Automatic failover postgres-2 → postgres-1      │
│  • 3 hours ago: postgres-1 marked unhealthy (TTL expired)       │
│  • 1 day ago: postgres-3 added to cluster                       │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## API Design

### REST Endpoints

```
# Stage 1: Add Connection Pooling (PgBouncer)
POST /v1/projects/{projectId}/services/{serviceId}/postgres/pooling
{
  "enabled": true,
  "pool_mode": "transaction",        # session, transaction, statement
  "default_pool_size": 20,
  "max_client_connections": 100
}

# Stage 2: Add Read Replica with HAProxy
POST /v1/projects/{projectId}/services/{serviceId}/postgres/replicas
{
  "count": 1,
  "replication_mode": "async",
  "load_balancing": "round_robin",
  "enable_haproxy": true
}

# Stage 3: Enable HA
POST /v1/projects/{projectId}/services/{serviceId}/postgres/ha
{
  "enabled": true,
  "patroni_ttl_seconds": 30,
  "sync_mode": "async",
  "maximum_lag_on_failover": 1048576,  # 1MB
  "auto_failback": false
}

# Get current topology
GET /v1/projects/{projectId}/services/{serviceId}/postgres/topology
Response:
{
  "stage": 3,
  "pooling": {
    "enabled": true,
    "type": "pgbouncer",
    "endpoint": "pgbouncer.railway.internal:5432"
  },
  "routing": {
    "enabled": true,
    "type": "haproxy",
    "replicas": 3,
    "rw_endpoint": "haproxy.railway.internal:5432",
    "ro_endpoint": "haproxy.railway.internal:5433",
    "stats_endpoint": "haproxy.railway.internal:8404"
  },
  "replicas": {
    "count": 2,
    "lag_bytes": [0, 24576, 24576]
  },
  "ha": {
    "enabled": true,
    "etcd_nodes": 3,
    "patroni_nodes": 3,
    "current_leader": "postgres-1",
    "patroni_version": "4.1.0",
    "etcd_version": "3.6.6"
  }
}

# Manual switchover (via Patroni REST API)
POST /v1/projects/{projectId}/services/{serviceId}/postgres/switchover
{
  "target_node": "postgres-2"
}

# Get cluster health (proxies to Patroni /cluster endpoint)
GET /v1/projects/{projectId}/services/{serviceId}/postgres/health
Response:
{
  "cluster_name": "pg-ha-cluster",
  "members": [
    { "name": "postgres-1", "role": "leader", "state": "running", "lag": 0 },
    { "name": "postgres-2", "role": "replica", "state": "streaming", "lag": 24576 },
    { "name": "postgres-3", "role": "replica", "state": "streaming", "lag": 24576 }
  ]
}
```

### GraphQL Mutations

```graphql
mutation EnablePostgresPooling($serviceId: ID!, $config: PgBouncerConfig!) {
  postgresEnablePooling(serviceId: $serviceId, config: $config) {
    success
    poolingEndpoint
    estimatedMonthlyCost
  }
}

mutation AddPostgresReplica($serviceId: ID!, $count: Int!, $enableHAProxy: Boolean!) {
  postgresAddReplica(serviceId: $serviceId, count: $count, enableHAProxy: $enableHAProxy) {
    success
    replicas {
      id
      status
      lagBytes
    }
    haproxyEndpoints {
      readWrite
      readOnly
      stats
    }
  }
}

mutation EnablePostgresHA($serviceId: ID!, $config: HAConfig!) {
  postgresEnableHA(serviceId: $serviceId, config: $config) {
    success
    migrationJobId
    estimatedDurationMinutes
    patroniClusterName
  }
}

mutation PostgresSwitchover($serviceId: ID!, $targetNode: String!) {
  postgresSwitchover(serviceId: $serviceId, targetNode: $targetNode) {
    success
    previousLeader
    newLeader
  }
}
```

---

## Database Migrations & State Management

### Service Metadata Schema

```sql
-- New table to track PostgreSQL expansion state
CREATE TABLE postgres_cluster_state (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  service_id UUID NOT NULL REFERENCES services(id),
  stage INT NOT NULL DEFAULT 0,  -- 0=single, 1=pooling, 2=replicas+haproxy, 3=ha

  -- Stage 1: Connection Pooling (PgBouncer)
  pooling_enabled BOOLEAN DEFAULT FALSE,
  pgbouncer_service_id UUID REFERENCES services(id),
  pool_mode VARCHAR(20) DEFAULT 'transaction',  -- session, transaction, statement
  default_pool_size INT DEFAULT 20,
  max_client_connections INT DEFAULT 100,

  -- Stage 2: Replicas + HAProxy
  replica_count INT DEFAULT 0,
  replication_mode VARCHAR(10) DEFAULT 'async',
  haproxy_service_id UUID REFERENCES services(id),
  haproxy_replicas INT DEFAULT 1,

  -- Stage 3: Full HA (Patroni + etcd)
  ha_enabled BOOLEAN DEFAULT FALSE,
  etcd_service_ids UUID[] DEFAULT '{}',
  patroni_service_ids UUID[] DEFAULT '{}',
  patroni_cluster_name VARCHAR(100),
  current_leader_id UUID,
  patroni_ttl_seconds INT DEFAULT 30,
  maximum_lag_on_failover BIGINT DEFAULT 1048576,

  -- Timestamps
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),

  CONSTRAINT valid_stage CHECK (stage >= 0 AND stage <= 3)
);

-- Track expansion history and cluster events
CREATE TABLE postgres_expansion_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cluster_id UUID NOT NULL REFERENCES postgres_cluster_state(id),
  event_type VARCHAR(50) NOT NULL,
  -- event_type values:
  --   'stage_upgrade', 'stage_downgrade'
  --   'failover', 'switchover'
  --   'replica_added', 'replica_removed'
  --   'leader_changed', 'node_unhealthy', 'node_recovered'
  from_stage INT,
  to_stage INT,
  metadata JSONB,  -- Additional context (e.g., previous_leader, new_leader, lag_bytes)
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index for efficient event queries
CREATE INDEX idx_expansion_events_cluster_created
  ON postgres_expansion_events(cluster_id, created_at DESC);
```

---

## Scaling Down (Reverting Stages)

### Stage 3 → Stage 2: Disable HA

**Warning**: "Disabling HA will remove automatic failover. Your database will have reduced fault tolerance."

**Process**:
1. Ensure primary node is healthy via Patroni REST API
2. Perform graceful switchover to target primary if needed
3. Remove standby nodes from Patroni cluster
4. Convert primary back to standalone PostgreSQL (remove Patroni)
5. Decommission etcd cluster (3 services)
6. Scale HAProxy to single replica
7. Update connection endpoints

**Data Preservation**: All data retained on primary node

### Stage 2 → Stage 1: Remove Replicas and HAProxy

**Warning**: "Removing replicas will reduce read capacity and eliminate disaster recovery standby."

**Process**:
1. Gracefully remove replicas from HAProxy backend configuration
2. Stop replication on replica nodes
3. Delete replica services and volumes
4. Decommission HAProxy service
5. Point PgBouncer directly to primary (if pooling enabled)

### Stage 1 → Stage 0: Remove Connection Pooling

**Warning**: "Removing connection pooling may cause connection issues if your application opens many database connections."

**Process**:
1. Provide updated direct connection string
2. Grace period (configurable, default 1 hour) for connection migration
3. Decommission PgBouncer service

### Stage 2 → Stage 0: Remove Replicas and Pooling

**Note**: Users can also remove both replicas and pooling in one operation.

**Process**:
1. Execute Stage 2 → Stage 1 process
2. Execute Stage 1 → Stage 0 process
3. Provide direct PostgreSQL connection string

---

## Error Handling & Rollback

### Expansion Failure Scenarios

| Failure Point | Automatic Recovery | Manual Recovery |
|--------------|-------------------|-----------------|
| etcd cluster won't form quorum | Retry 3x with stale data cleanup, then rollback | Check networking, verify peer discovery |
| Primary won't convert to Patroni | Restore from snapshot | Contact support |
| Replica won't sync (pg_basebackup fails) | Retry replication setup | Check disk space, WAL retention, network |
| HAProxy can't reach Patroni API | Update resolver config, retry health checks | Verify Patroni REST API on port 8008 |
| PgBouncer connection failures | Verify auth config, restart | Check userlist.txt, pgbouncer.ini |

### Rollback Procedure

Each expansion step creates a checkpoint:
1. **Snapshot** of current PostgreSQL data
2. **Reversible changes** tracked (services created, config changes)
3. **Timeout** (30 min default) triggers automatic rollback if unhealthy
4. **Health validation** via Patroni `/cluster` endpoint before marking complete

```yaml
expansion_checkpoint:
  stage: 2
  timestamp: 2025-12-08T10:00:00Z
  snapshot_id: snap_abc123
  services_created:
    - service_id: svc_replica1
      type: postgres_replica
    - service_id: svc_haproxy
      type: haproxy
  config_changes:
    - haproxy_backends_added: ["postgres-1", "postgres-2"]
  health_check_endpoint: "http://postgres-1.railway.internal:8008/cluster"
  rollback_available_until: 2025-12-08T10:30:00Z
```

### Health Check Endpoints

| Component | Endpoint | Expected Response |
|-----------|----------|-------------------|
| Patroni Leader | `GET /primary` | HTTP 200 |
| Patroni Replica | `GET /replica` | HTTP 200 |
| Patroni Cluster | `GET /cluster` | JSON with members |
| etcd | `GET /health` | `{"health":"true"}` |
| HAProxy Stats | `GET /stats` (port 8404) | HTML stats page |
| PgBouncer | `SHOW POOLS;` via psql | Pool statistics |

---

## Billing & Cost Transparency

### Cost Breakdown UI Component

```
┌─────────────────────────────────────────────────────────────────┐
│  Estimated Monthly Cost                                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Current (Stage 0):                               $15/month     │
│  └─ PostgreSQL Primary (1 vCPU, 1GB, 10GB SSD)                  │
│                                                                  │
│  After Adding PgBouncer (Stage 1):                +$3/month     │
│  └─ PgBouncer (0.25 vCPU, 256MB RAM)                            │
│                                                                  │
│  After Adding Replica + HAProxy (Stage 2):        +$20/month    │
│  └─ 1× PostgreSQL Replica (1 vCPU, 1GB, 10GB SSD)               │
│  └─ 1× HAProxy (0.5 vCPU, 512MB RAM)                            │
│                                                                  │
│  After Enabling Full HA (Stage 3):                +$42/month    │
│  └─ 3× etcd (0.5 vCPU, 512MB each)           = $15              │
│  └─ 2× additional PostgreSQL replicas        = $30              │
│  └─ 2× additional HAProxy replicas           = $10              │
│  └─ Less Stage 2 services already deployed   = -$13             │
│                                                                  │
│  ─────────────────────────────────────────────────────────────── │
│  Total (Full HA + Pooling):                       $80/month     │
│  └─ 3× PostgreSQL + Patroni                  = $45              │
│  └─ 3× etcd                                  = $15              │
│  └─ 3× HAProxy                               = $15              │
│  └─ 1× PgBouncer (optional)                  = $3               │
│  └─ Storage (30GB × 3 nodes)                 = ~$2              │
│                                                                  │
│  [View Detailed Breakdown]                                       │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Implementation Phases

### Phase 1: Foundation
- [x] Database schema for cluster state tracking
- [x] Patroni + etcd Docker images (`postgres-ha` repository)
- [x] HAProxy configuration with Patroni health checks
- [ ] API endpoints for topology queries
- [ ] PgBouncer deployment automation (Stage 1)
- [ ] Basic Data UI "Scale" tab

### Phase 2: Read Replicas + HAProxy
- [x] Streaming replication via Patroni
- [x] HAProxy read/write splitting (port 5432/5433)
- [ ] Read replica deployment automation (Stage 2)
- [ ] Replication lag monitoring integration
- [ ] HAProxy stats dashboard exposure

### Phase 3: High Availability
- [x] etcd cluster deployment with leader-elected bootstrap
- [x] Patroni cluster management
- [x] Automatic failover (<30s)
- [ ] Migration procedure from standalone to HA
- [ ] Failover testing automation
- [ ] Full HA deployment via UI (Stage 3)

### Phase 4: Polish & Observability
- [ ] Enhanced cluster visualization in Data UI
- [ ] Failover event notifications (webhooks, email)
- [ ] Cost transparency improvements
- [ ] Documentation and user guides
- [ ] PgBouncer integration with HAProxy

---

## Security Considerations

1. **Credential Rotation**: Automatic rotation of replication passwords
2. **Network Isolation**: All cluster traffic on private network
3. **Encryption**: TLS for replication streams, encryption at rest
4. **Access Control**: Only project members can modify cluster topology
5. **Audit Logging**: All topology changes logged with actor

---

## Monitoring & Alerting

### New Metrics (exposed via Prometheus/Grafana)

```
# Replication metrics (from Patroni)
postgresql_replication_lag_bytes{node="postgres-2"}
postgresql_replication_lag_seconds{node="postgres-2"}
postgresql_streaming_replication_connected{node="postgres-2"}

# Patroni metrics (via /metrics endpoint on port 8008)
patroni_cluster_leader{cluster="pg-ha-cluster", node="postgres-1"}
patroni_cluster_unlocked{cluster="pg-ha-cluster"}
patroni_failover_count{cluster="pg-ha-cluster"}
patroni_postgres_running{node="postgres-1"}
patroni_patroni_version{version="4.1.0"}

# HAProxy metrics (via stats socket or /metrics)
haproxy_backend_status{backend="postgres_primary", server="postgres-1"}
haproxy_backend_active_servers{backend="postgres_primary"}
haproxy_frontend_current_sessions{frontend="postgres_rw"}
haproxy_frontend_bytes_in_total{frontend="postgres_rw"}
haproxy_backend_response_time_average_seconds{backend="postgres_primary"}
haproxy_server_check_failures_total{server="postgres-1"}

# PgBouncer metrics (via SHOW STATS)
pgbouncer_pools_client_active{database="mydb"}
pgbouncer_pools_server_active{database="mydb"}
pgbouncer_pools_client_waiting{database="mydb"}
pgbouncer_stats_total_query_time{database="mydb"}
pgbouncer_stats_avg_query_time{database="mydb"}

# etcd metrics (via /metrics endpoint on port 2379)
etcd_server_has_leader
etcd_server_leader_changes_seen_total
etcd_server_proposals_committed_total
etcd_disk_wal_fsync_duration_seconds
```

### Default Alerts

| Alert | Condition | Severity |
|-------|-----------|----------|
| ReplicationLagHigh | lag > 100MB for 5 min | Warning |
| ReplicationBroken | lag = -1 (disconnected) | Critical |
| FailoverOccurred | leader changed | Info |
| ClusterUnhealthy | <2 healthy Patroni nodes | Critical |
| etcdQuorumLost | <2 etcd nodes healthy | Critical |
| HAProxyBackendDown | backend servers = 0 | Critical |
| HAProxyHighLatency | response time > 100ms | Warning |
| PgBouncerPoolExhausted | client_waiting > 10 | Warning |

---

## Open Questions

1. **Volume Sizing**: Should replicas have configurable volume sizes, or match primary?
2. **Cross-Region Replicas**: Timeline for multi-region support?
3. **Synchronous Replication**: Should we support sync mode for zero data loss?
4. **Connection String Management**: How to handle endpoint changes transparently?
5. **Backup Integration**: How does this interact with the backup RFC?

---

## Appendix A: Connection String Changes

| Stage | Connection String |
|-------|------------------|
| 0 (Single) | `postgresql://user:pass@postgres.railway.internal:5432/db` |
| 1 (Pooling) | `postgresql://user:pass@pgbouncer.railway.internal:5432/db` |
| 2 (Replicas) | Read-Write: `postgresql://user:pass@haproxy.railway.internal:5432/db`<br>Read-Only: `postgresql://user:pass@haproxy.railway.internal:5433/db` |
| 3 (Full HA) | Same as Stage 2 (HAProxy routes to Patroni cluster) |

### With PgBouncer + HAProxy (Stage 2/3 + pooling)

For maximum efficiency, chain PgBouncer behind HAProxy:

```
Application → HAProxy (routing) → PgBouncer (pooling) → PostgreSQL
```

| Endpoint | Connection String |
|----------|------------------|
| Pooled Read-Write | `postgresql://user:pass@pgbouncer.railway.internal:5432/db` (PgBouncer connects to HAProxy:5432) |
| Pooled Read-Only | `postgresql://user:pass@pgbouncer.railway.internal:5433/db` (PgBouncer connects to HAProxy:5433) |
| Direct (bypass pool) | `postgresql://user:pass@haproxy.railway.internal:5432/db` |

## Appendix B: Patroni Configuration Template

```yaml
scope: {{cluster_name}}
name: {{node_name}}

etcd3:
  hosts: {{etcd_hosts}}

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 128MB

postgresql:
  listen: 0.0.0.0:5432
  connect_address: {{node_address}}:5432
  data_dir: /var/lib/postgresql/data/pgdata
  authentication:
    superuser:
      username: {{postgres_user}}
      password: {{postgres_password}}
    replication:
      username: replicator
      password: {{replication_password}}
```

---

## References

### Internal RFCs
- [RFC-001: Patroni Integration](./RFC-001-PATRONI.md)
- [RFC-007: HAProxy + Streaming Replication](./RFC-007-HAPROXY-STREAMING-REPLICATION.md)

### External Documentation
- [Patroni Documentation](https://patroni.readthedocs.io/)
- [Patroni REST API](https://patroni.readthedocs.io/en/latest/rest_api.html)
- [HAProxy Documentation](https://www.haproxy.org/documentation/)
- [PgBouncer Documentation](https://www.pgbouncer.org/)
- [etcd Documentation](https://etcd.io/docs/)

### Implementation Repository
- [postgres-ha](https://github.com/railwayapp/postgres-ha) - Docker images for Patroni, etcd, and HAProxy

### Why Not Pgpool-II?

RFC-006 (Pgpool-II) was evaluated but **not implemented** for this architecture. Key reasons:

1. **Complexity**: Pgpool requires its own watchdog mechanism, PCP authentication, and careful coordination
2. **Redundancy**: HAProxy + Patroni already provides health-check based routing without query parsing
3. **Operational burden**: Pgpool's connection pooling adds overhead; PgBouncer is lighter-weight
4. **Failure modes**: Pgpool's failover logic can conflict with Patroni's leader election

HAProxy was chosen because:
- Simple health-check model (`GET /primary`, `GET /replica`)
- No query parsing overhead
- Stateless - easy to scale horizontally
- Battle-tested with Patroni in production
