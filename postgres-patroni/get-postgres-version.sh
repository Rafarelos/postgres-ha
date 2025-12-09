#!/bin/bash
# Fetches the latest minor version for a given PostgreSQL major version from Docker Hub
# Usage: ./get-postgres-version.sh <major_version>
# Example: ./get-postgres-version.sh 16 -> 16.6

set -e

if [ $# -ne 1 ]; then
    echo "Usage: $0 <major_version>" >&2
    echo "Example: $0 16" >&2
    exit 1
fi

MAJOR_VERSION="$1"

# Validate that it's a number
if ! [[ "$MAJOR_VERSION" =~ ^[0-9]+$ ]]; then
    echo "Error: Major version must be a number" >&2
    exit 1
fi

echo "Fetching latest PostgreSQL ${MAJOR_VERSION}.x version from Docker Hub..." >&2

# Query Docker Hub API for postgres tags and filter for the major version
# We look for tags matching "MAJOR.MINOR" pattern (no suffix like -alpine, -bookworm, etc.)
LATEST_VERSION=$(curl -s "https://hub.docker.com/v2/repositories/library/postgres/tags?page_size=100" | \
    jq -r ".results[].name" | \
    grep -E "^${MAJOR_VERSION}\.[0-9]+$" | \
    sort -V | \
    tail -n 1)

if [ -z "$LATEST_VERSION" ]; then
    echo "Error: Could not find any version for PostgreSQL ${MAJOR_VERSION}" >&2
    echo "Please check https://hub.docker.com/_/postgres for available versions" >&2
    exit 1
fi

echo "Found: ${LATEST_VERSION}" >&2
echo "$LATEST_VERSION"
