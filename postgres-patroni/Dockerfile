FROM postgres:17

ARG PATRONI_VERSION=4.0.4
ARG SSL_CERT_DAYS=820

# Install dependencies: OpenSSL, sudo (for Railway volume perms), Python for Patroni
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssl \
    sudo \
    python3 \
    python3-pip \
    python3-psycopg2 \
    python3-yaml \
    python3-urllib3 \
    python3-certifi \
    python3-requests \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install Patroni
RUN pip3 install --no-cache-dir --break-system-packages \
    patroni[etcd]==${PATRONI_VERSION}

# Allow postgres user to run specific commands as root (for Railway volume permissions)
RUN echo "postgres ALL=(root) NOPASSWD: /usr/bin/mkdir, /bin/mkdir, /bin/chown, /usr/bin/chown, /usr/bin/openssl, /bin/chmod, /usr/bin/chmod" > /etc/sudoers.d/postgres

# Create directories
RUN mkdir -p /home/postgres /etc/patroni /var/run/postgresql \
    && chown -R postgres:postgres /home/postgres /var/run/postgresql

# Copy scripts
COPY init-ssl.sh /docker-entrypoint-initdb.d/init-ssl.sh
COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY post_bootstrap.sh /post_bootstrap.sh
COPY wrapper.sh /usr/local/bin/wrapper.sh
RUN chmod +x /docker-entrypoint.sh /post_bootstrap.sh /usr/local/bin/wrapper.sh \
    /docker-entrypoint-initdb.d/init-ssl.sh

# Expose PostgreSQL and Patroni REST API ports
EXPOSE 5432 8008

ENV SSL_CERT_DAYS=${SSL_CERT_DAYS}

# Health check adapts to mode (Patroni API or pg_isready)
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=3 \
    CMD if [ "${PATRONI_ENABLED:-false}" = "true" ]; then \
            curl -f http://localhost:8008/health || exit 1; \
        else \
            pg_isready -U ${POSTGRES_USER:-postgres} || exit 1; \
        fi

ENTRYPOINT ["wrapper.sh"]
CMD ["postgres"]
