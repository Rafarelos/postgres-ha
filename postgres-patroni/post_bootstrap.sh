#!/bin/bash
set -e

DATA_DIR="/var/lib/postgresql/data"
CERTS_DIR="$DATA_DIR/certs"

echo "Post-bootstrap: configuring users..."

# Use environment variables
SUPERUSER="${PATRONI_SUPERUSER_USERNAME:-${POSTGRES_USER:-postgres}}"
SUPERUSER_PASS="${PATRONI_SUPERUSER_PASSWORD:-${POSTGRES_PASSWORD}}"
REPL_USER="${PATRONI_REPLICATION_USERNAME:-replicator}"
REPL_PASS="${PATRONI_REPLICATION_PASSWORD}"

if [ -z "$SUPERUSER_PASS" ] || [ -z "$REPL_PASS" ]; then
    echo "ERROR: Missing required passwords (POSTGRES_PASSWORD or PATRONI_REPLICATION_PASSWORD)"
    exit 1
fi

# Create users FIRST - critical for replication
psql -v ON_ERROR_STOP=1 -U postgres -d postgres <<-EOSQL
    -- Configure superuser
    DO \$\$
    BEGIN
        IF '${SUPERUSER}' != 'postgres' THEN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${SUPERUSER}') THEN
                CREATE ROLE ${SUPERUSER} WITH SUPERUSER CREATEDB CREATEROLE LOGIN PASSWORD '${SUPERUSER_PASS}';
            ELSE
                ALTER USER ${SUPERUSER} WITH PASSWORD '${SUPERUSER_PASS}';
            END IF;
        ELSE
            ALTER USER postgres WITH PASSWORD '${SUPERUSER_PASS}';
        END IF;
    END
    \$\$;

    -- Create replicator user
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${REPL_USER}') THEN
            CREATE ROLE ${REPL_USER} WITH REPLICATION PASSWORD '${REPL_PASS}' LOGIN;
        END IF;
    END
    \$\$;
EOSQL

echo "Post-bootstrap: users configured"

# Create POSTGRES_DB if specified
if [ -n "$POSTGRES_DB" ] && [ "$POSTGRES_DB" != "postgres" ]; then
    echo "Creating database: $POSTGRES_DB"
    psql -v ON_ERROR_STOP=1 -U postgres -d postgres <<-EOSQL
        SELECT 'CREATE DATABASE "${POSTGRES_DB}" OWNER "${SUPERUSER}"'
        WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${POSTGRES_DB}')\gexec
EOSQL
fi

# Generate SSL certs
echo "Post-bootstrap: generating SSL certificates..."
DAYS="${SSL_CERT_DAYS:-820}"
mkdir -p "$CERTS_DIR"

openssl genrsa -out "$CERTS_DIR/ca.key" 2048
openssl req -new -x509 -days "$DAYS" -key "$CERTS_DIR/ca.key" -out "$CERTS_DIR/ca.crt" -subj "/CN=PostgreSQL CA"
openssl genrsa -out "$CERTS_DIR/server.key" 2048
openssl req -new -key "$CERTS_DIR/server.key" -out "$CERTS_DIR/server.csr" -subj "/CN=postgres"

cat > "$CERTS_DIR/v3.ext" <<EXTEOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = DNS:localhost,DNS:*.railway.internal,IP:127.0.0.1
EXTEOF

openssl x509 -req -in "$CERTS_DIR/server.csr" -CA "$CERTS_DIR/ca.crt" -CAkey "$CERTS_DIR/ca.key" \
    -CAcreateserial -out "$CERTS_DIR/server.crt" -days "$DAYS" -extfile "$CERTS_DIR/v3.ext"

chmod 600 "$CERTS_DIR/server.key"
chmod 644 "$CERTS_DIR/server.crt" "$CERTS_DIR/ca.crt"

# Enable SSL via ALTER SYSTEM and reload
echo "Post-bootstrap: enabling SSL..."
psql -v ON_ERROR_STOP=1 -U postgres -d postgres <<-EOSQL
    ALTER SYSTEM SET ssl = 'on';
    ALTER SYSTEM SET ssl_cert_file = '${CERTS_DIR}/server.crt';
    ALTER SYSTEM SET ssl_key_file = '${CERTS_DIR}/server.key';
    ALTER SYSTEM SET ssl_ca_file = '${CERTS_DIR}/ca.crt';
    SELECT pg_reload_conf();
EOSQL

echo "Post-bootstrap completed"
