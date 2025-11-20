FROM postgres:17-alpine

ARG PATRONI_VERSION=4.0.4

RUN apk add --no-cache \
    python3 \
    py3-pip \
    py3-psycopg2 \
    py3-yaml \
    curl \
    bash \
    gettext \
    su-exec \
    && apk add --no-cache --virtual .build-deps \
    gcc \
    python3-dev \
    musl-dev \
    linux-headers \
    && pip3 install --no-cache-dir --break-system-packages \
    patroni[etcd]==${PATRONI_VERSION} \
    && apk del .build-deps

RUN mkdir -p /home/postgres && \
    chown -R postgres:postgres /home/postgres /var/lib/postgresql

COPY patroni.yml /etc/patroni/patroni.yml
COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY init-volume.sh /init-volume.sh
COPY post_bootstrap.sh /post_bootstrap.sh
RUN chmod +x /docker-entrypoint.sh /init-volume.sh /post_bootstrap.sh

EXPOSE 5432 8008

HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -f http://localhost:8008/health || exit 1

ENTRYPOINT ["/init-volume.sh"]
CMD ["patroni", "/tmp/patroni.yml"]
