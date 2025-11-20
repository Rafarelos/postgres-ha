FROM railwayapp/pgpool:4

USER root

# Force rebuild

# Don't copy custom config - let Bitnami generate from env vars
COPY pool_hba.conf /opt/bitnami/pgpool/conf/pool_hba.conf

# Create wrapper entrypoint to fix missing env var before Bitnami entrypoint runs
COPY <<'EOF' /entrypoint-wrapper.sh
#!/bin/bash
set -e

# Workaround: Railway sometimes doesn't resolve PGPOOL_HEALTH_CHECK_PASSWORD
# Copy from PGPOOL_POSTGRES_PASSWORD if empty
if [ -z "${PGPOOL_HEALTH_CHECK_PASSWORD}" ] && [ -n "${PGPOOL_POSTGRES_PASSWORD}" ]; then
  echo "PGPOOL_HEALTH_CHECK_PASSWORD is empty, copying from PGPOOL_POSTGRES_PASSWORD"
  export PGPOOL_HEALTH_CHECK_PASSWORD="${PGPOOL_POSTGRES_PASSWORD}"
fi

# Call original Bitnami entrypoint
exec /opt/bitnami/scripts/pgpool/entrypoint.sh "$@"
EOF

RUN chmod +x /entrypoint-wrapper.sh

# Create init script to add admin user to pool_passwd
COPY <<'EOF' /docker-entrypoint-initdb.d/01-add-admin-user.sh
#!/bin/bash
set -e

# Wait for pool_passwd to be created by Bitnami
while [ ! -f /opt/bitnami/pgpool/conf/pool_passwd ]; do
  echo "Waiting for pool_passwd to be created..."
  sleep 1
done

# Add admin user if PGPOOL_ADMIN_USERNAME is set
if [ -n "${PGPOOL_ADMIN_USERNAME}" ] && [ -n "${PGPOOL_ADMIN_PASSWORD}" ]; then
  echo "Adding ${PGPOOL_ADMIN_USERNAME} to pool_passwd..."

  # Generate MD5 hash for pgpool (format: md5<md5(password+username)>)
  HASH=$(echo -n "${PGPOOL_ADMIN_PASSWORD}${PGPOOL_ADMIN_USERNAME}" | md5sum | cut -d' ' -f1)
  echo "${PGPOOL_ADMIN_USERNAME}:md5${HASH}" >> /opt/bitnami/pgpool/conf/pool_passwd

  echo "Admin user added successfully"
fi
EOF

RUN chmod +x /docker-entrypoint-initdb.d/01-add-admin-user.sh

USER 1001

ENTRYPOINT ["/entrypoint-wrapper.sh"]
CMD ["/opt/bitnami/scripts/pgpool/run.sh"]

EXPOSE 5432 9999

HEALTHCHECK --interval=10s --timeout=5s --start-period=30s \
  CMD pgpool -h localhost -p 5432 -c "SELECT 1" || exit 1
