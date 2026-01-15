#!/bin/sh
set -e

CONFIG_FILE="/usr/local/etc/haproxy/haproxy.cfg"

# Required
if [ -z "${POSTGRES_NODES}" ]; then
    echo "ERROR: POSTGRES_NODES is required"
    echo "Format: hostname:pgport:patroniport,hostname:pgport:patroniport,..."
    echo "Example: postgres-1.railway.internal:5432:8008,postgres-2.railway.internal:5432:8008"
    exit 1
fi

# Optional with defaults - OTIMIZADO PARA RESPOSTA RÁPIDA
HAPROXY_MAX_CONN="${HAPROXY_MAX_CONN:-1000}"
HAPROXY_TIMEOUT_CONNECT="${HAPROXY_TIMEOUT_CONNECT:-3s}"      # Reduzido: fail-fast na conexão
HAPROXY_TIMEOUT_CLIENT="${HAPROXY_TIMEOUT_CLIENT:-60s}"       # Reduzido: evita conexões zumbis
HAPROXY_TIMEOUT_SERVER="${HAPROXY_TIMEOUT_SERVER:-60s}"       # Reduzido: queries devem retornar em 60s
HAPROXY_TIMEOUT_QUEUE="${HAPROXY_TIMEOUT_QUEUE:-5s}"          # NOVO: máximo 5s na fila de espera
HAPROXY_CHECK_INTERVAL="${HAPROXY_CHECK_INTERVAL:-1s}"        # Reduzido: detecta problemas mais rápido

# Count nodes
count_nodes() {
    echo "$POSTGRES_NODES" | tr ',' '\n' | wc -l | tr -d ' '
}

NODE_COUNT=$(count_nodes)
SINGLE_NODE_MODE="false"
if [ "$NODE_COUNT" -eq 1 ]; then
    SINGLE_NODE_MODE="true"
    echo "Single node mode: HAProxy will route directly to PostgreSQL without Patroni health checks"
fi

# Generate server entries from POSTGRES_NODES
# Format: hostname:pgport:patroniport,hostname:pgport:patroniport,...
# In single node mode, skip Patroni health check and route directly to PostgreSQL
generate_servers() {
    echo "$POSTGRES_NODES" | tr ',' '\n' | while read -r node; do
        # Count colons to detect format
        colon_count=$(echo "$node" | tr -cd ':' | wc -c)

        if [ "$colon_count" -eq 2 ]; then
            # Format: hostname:pgport:patroniport
            host=$(echo "$node" | cut -d: -f1)
            pgport=$(echo "$node" | cut -d: -f2)
            patroniport=$(echo "$node" | cut -d: -f3)
        else
            echo "ERROR: Invalid node format: $node" >&2
            echo "Expected: hostname:pgport:patroniport" >&2
            exit 1
        fi

        # Extract short name from hostname (e.g., postgres-1 from postgres-1.railway.internal)
        name=$(echo "$host" | cut -d. -f1)

        if [ "$SINGLE_NODE_MODE" = "true" ]; then
            # Single node: skip Patroni health check, use TCP check on PostgreSQL port
            echo "    server ${name} ${host}:${pgport} check resolvers railway resolve-prefer ipv6"
        else
            # Multi-node: use Patroni health check
            echo "    server ${name} ${host}:${pgport} check port ${patroniport} resolvers railway resolve-prefer ipv6"
        fi
    done
}

PRIMARY_SERVERS=$(generate_servers)
REPLICA_SERVERS=$(generate_servers)

# Generate HAProxy config
cat > "$CONFIG_FILE" << EOF
global
    maxconn ${HAPROXY_MAX_CONN}
    log stdout format raw local0

defaults
    log global
    mode tcp
    option tcpka                     # Mantém a conexão viva
    option clitcpka                  # Keep-alive no lado do cliente (Backend)
    option srvtcpka                  # Keep-alive no lado do servidor (Postgres)
    option redispatch                # NOVO: reconecta em outro servidor se falhar
    retries 1                        # Reduzido: falha rápida, não fica tentando
    timeout connect ${HAPROXY_TIMEOUT_CONNECT}
    timeout client ${HAPROXY_TIMEOUT_CLIENT}
    timeout server ${HAPROXY_TIMEOUT_SERVER}
    timeout queue ${HAPROXY_TIMEOUT_QUEUE}
    timeout check 2s                 # Checagem de saúde mais ágil

resolvers railway
    parse-resolv-conf
    resolve_retries 2                # Reduzido: falha rápida no DNS
    timeout resolve 500ms            # Reduzido: DNS deve responder rápido
    timeout retry   500ms            # Reduzido: retry rápido
    hold other      5s               # Reduzido: atualiza cache mais rápido
    hold refused    5s
    hold nx         5s
    hold timeout    5s
    hold valid      5s
    hold obsolete   5s

# Stats page for monitoring
listen stats
    bind :::8404 v4v6
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s

# Primary PostgreSQL (read-write)
frontend postgresql_primary
    bind :::5432 v4v6
    default_backend postgresql_primary_backend

backend postgresql_primary_backend
EOF

if [ "$SINGLE_NODE_MODE" = "true" ]; then
    # Single node: simple TCP check, no Patroni health check
    cat >> "$CONFIG_FILE" << EOF
    default-server inter ${HAPROXY_CHECK_INTERVAL} fall 2 rise 1 fastinter 500ms downinter 500ms on-marked-down shutdown-sessions
${PRIMARY_SERVERS}
EOF
else
    # Multi-node: use Patroni HTTP health checks
    cat >> "$CONFIG_FILE" << EOF
    balance leastconn                # Distribui para quem está mais livre
    option httpchk
    http-check send meth GET uri /primary
    http-check expect status 200
    default-server inter ${HAPROXY_CHECK_INTERVAL} fall 2 rise 1 fastinter 500ms downinter 500ms on-marked-down shutdown-sessions
${PRIMARY_SERVERS}
EOF
fi

cat >> "$CONFIG_FILE" << EOF

# Replica PostgreSQL (read-only)
frontend postgresql_replicas
    bind :::5433 v4v6
    default_backend postgresql_replicas_backend

backend postgresql_replicas_backend
    balance leastconn                # Distribui para quem está mais livre
EOF

if [ "$SINGLE_NODE_MODE" = "true" ]; then
    # Single node: simple TCP check, no Patroni health check
    cat >> "$CONFIG_FILE" << EOF
    default-server inter ${HAPROXY_CHECK_INTERVAL} fall 2 rise 1 fastinter 500ms downinter 500ms on-marked-down shutdown-sessions
${REPLICA_SERVERS}
EOF
else
    # Multi-node: use Patroni HTTP health checks
    cat >> "$CONFIG_FILE" << EOF
    option httpchk
    http-check send meth GET uri /replica
    http-check expect status 200
    default-server inter ${HAPROXY_CHECK_INTERVAL} fall 2 rise 1 fastinter 500ms downinter 500ms on-marked-down shutdown-sessions
${REPLICA_SERVERS}
EOF
fi

echo "HAProxy config generated with nodes: ${POSTGRES_NODES}"
cat "$CONFIG_FILE"
echo ""
echo "Starting HAProxy..."

exec haproxy -f "$CONFIG_FILE"
