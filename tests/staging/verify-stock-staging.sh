#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap cleanup_local_pgpass EXIT

# Read-only report, with identity checked before opening the report SQL file.
guard_local_target
assert_local_staging_marker
psql_local -f "$SCRIPT_DIR/verify-stock-staging.sql"
