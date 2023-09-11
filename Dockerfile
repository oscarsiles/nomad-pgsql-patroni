### With help from fork by sycured: https://github.com/sycured/nomad-pgsql-patroni

ARG GO_VERSION=1.21
ARG PG_MAJOR=15
ARG PATRONI_VERSION=v3.1.0
ARG TIMESCALEDB_MAJOR=2
ARG POSTGIS_MAJOR=3
ARG PGVECTOR_VERSION=v0.5.0
ARG VAULTENV_VERSION=0.16.0
ARG PG_SQUEEZE_VERSION=1.5.2
ARG PG_TIMETABLE_VERSION=5.5.0

############################
# Build tools binaries in separate image
############################
#FROM golang:${GO_VERSION} AS tools
#
#RUN mkdir -p ${GOPATH}/src/github.com/timescale/ \
#    && cd ${GOPATH}/src/github.com/timescale/ \
#    && git clone https://github.com/timescale/timescaledb-tune.git \
#    && git clone https://github.com/timescale/timescaledb-parallel-copy.git \
#    # Build timescaledb-tune
#    && cd timescaledb-tune/cmd/timescaledb-tune \
#    && git fetch && git checkout --quiet $(git describe --abbrev=0) \
#    && go get -d -v \
#    && go build -o /go/bin/timescaledb-tune \
#    # Build timescaledb-parallel-copy
#    && cd ${GOPATH}/src/github.com/timescale/timescaledb-parallel-copy/cmd/timescaledb-parallel-copy \
#    && git fetch && git checkout --quiet $(git describe --abbrev=0) \
#    && go get -d -v \
#    && go build -o /go/bin/timescaledb-parallel-copy

############################
# Build Postgres extensions
############################
FROM postgres:15 AS ext_build
ARG PG_MAJOR
ARG PGVECTOR_VERSION
ARG PG_SQUEEZE_VERSION

RUN set -x \
    && apt-get update -y \
    && apt-get install -y git curl apt-transport-https ca-certificates build-essential libpq-dev postgresql-server-dev-${PG_MAJOR} \
    && mkdir /build \
    && cd /build \
    \
    # Build pgvector
    && git clone --branch $PGVECTOR_VERSION https://github.com/ankane/pgvector.git \
    && cd pgvector \
    && make \
    && make install \
    && cd .. \
    \
    # Build pg_squeeze
    && git clone --branch $PG_SQUEEZE_VERSION https://github.com/cybertec-postgresql/pg_squeeze.git \
    && cd pg_squeeze \
    && make \
    && make install

############################
# Add Timescale, PostGIS and Patroni
############################
FROM postgres:15
ARG PG_MAJOR
ARG PATRONI_VERSION
ARG POSTGIS_MAJOR
ARG TIMESCALEDB_MAJOR
ARG VAULTENV_VERSION
ARG PG_TIMETABLE_VERSION
ARG TARGETARCH

# Add extensions
#COPY --from=tools /go/bin/* /usr/local/bin/
COPY --from=ext_build /usr/share/postgresql/15/ /usr/share/postgresql/15/
COPY --from=ext_build /usr/lib/postgresql/15/ /usr/lib/postgresql/15/
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN set -x \
    && apt-get update -y \
    && apt-get install -y gcc curl procps python3-dev libpython3-dev libyaml-dev apt-transport-https ca-certificates \
    #    && echo "deb https://packagecloud.io/timescale/timescaledb/debian/ bullseye main" > /etc/apt/sources.list.d/timescaledb.list \
    #    && curl -L https://packagecloud.io/timescale/timescaledb/gpgkey | apt-key add - \
    && apt-get update -y \
    && apt-cache showpkg postgresql-$PG_MAJOR-postgis-$POSTGIS_MAJOR \
    && apt-get install -y --no-install-recommends \
    postgresql-$PG_MAJOR-postgis-$POSTGIS_MAJOR \
    postgresql-$PG_MAJOR-postgis-$POSTGIS_MAJOR-scripts \
    #        timescaledb-$TIMESCALEDB_MAJOR-postgresql-$PG_MAJOR \
    postgis \
    postgresql-$PG_MAJOR-pgrouting \
    postgresql-$PG_MAJOR-cron \
    pgbackrest \
    nano \
    \
    && cpuarch=$(uname -m) \
    \
    # Install Patroni
    && apt-get install -y --no-install-recommends \
    python3 python3-pip python3-setuptools \
    && pip3 install --upgrade pip --break-system-packages \
    && pip3 install wheel zipp==1.0.0 --break-system-packages \
    && pip3 install python-consul "psycopg[binary]" --break-system-packages \
    && pip3 install https://github.com/zalando/patroni/archive/${PATRONI_VERSION}.zip --break-system-packages \
    \
    # Install WAL-G
    && [[ $cpuarch == x86_64 ]] && walg_arch=amd64 || walg_arch=aarch64 \
    && curl -LO https://github.com/wal-g/wal-g/releases/download/v2.0.1/wal-g-pg-ubuntu-20.04-${walg_arch} \
    && install -oroot -groot -m755 wal-g-pg-ubuntu-20.04-${walg_arch} /usr/local/bin/wal-g \
    && rm wal-g-pg-ubuntu-20.04-${walg_arch} \
    \
    # Install vaultenv
    && curl -LO https://github.com/channable/vaultenv/releases/download/v${VAULTENV_VERSION}/vaultenv-${VAULTENV_VERSION}-linux-musl \
    && install -oroot -groot -m755 vaultenv-${VAULTENV_VERSION}-linux-musl /usr/bin/vaultenv \
    && rm vaultenv-${VAULTENV_VERSION}-linux-musl \
    \
    # Install pg_timetable
    && [[ $cpuarch == x86_64 ]] && pgtimetable_arch=x86_64 || pgtimetable_arch=arm64 \
    && curl -LO https://github.com/cybertec-postgresql/pg_timetable/releases/download/v${PG_TIMETABLE_VERSION}/pg_timetable_${PG_TIMETABLE_VERSION}_Linux_${pgtimetable_arch}.deb \
    && dpkg -i pg_timetable_${PG_TIMETABLE_VERSION}_Linux_${pgtimetable_arch}.deb \
    && rm pg_timetable_${PG_TIMETABLE_VERSION}_Linux_${pgtimetable_arch}.deb \
    # Cleanup
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /docker-entrypoint-initdb.d
COPY ./files/000_shared_libs.sh /docker-entrypoint-initdb.d/000_shared_libs.sh
COPY ./files/001_initdb_postgis.sh /docker-entrypoint-initdb.d/001_initdb_postgis.sh
# COPY ./files/002_timescaledb_tune.sh /docker-entrypoint-initdb.d/002_timescaledb_tune.sh

COPY ./files/update-postgis.sh /usr/local/bin
COPY ./files/docker-initdb.sh /usr/local/bin

USER postgres
CMD ["patroni", "/secrets/patroni.yml"]
