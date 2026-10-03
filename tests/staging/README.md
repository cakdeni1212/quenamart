# Isolated local PostgreSQL staging harness

These scripts are for the synthetic native PostgreSQL database named
`quena_stock_staging` on loopback only. They never use Supabase CLI, linked
project metadata, `.env.local`, or database credentials from the application.

Run `bash tests/staging/prepare-stock-staging.sh` from the repository root to
bootstrap the minimal Supabase compatibility objects, apply the active local
migrations through the forward correction-intent fix `20260929171000`, and seed
synthetic identities plus iPos normalization fixtures. This command deliberately
stops before migration `20260929180000`.

After reviewing the prepared state, run
`bash tests/staging/apply-stock-foundation.sh` to apply only migration 180000
to this same guarded database. Then run
`bash tests/staging/run-stock-runtime-matrix.sh` for the synthetic transactional
assertions, and `bash tests/staging/verify-stock-staging.sh` for a read-only
summary. The separate `bash tests/staging/run-stock-concurrency-matrix.sh`
launches genuine concurrent psql connections for scenarios A/B/E/F/D/G. It
commits synthetic test operations, restores the product's stock effect, and
retains append-only tagged audit rows. Scenarios C and H are explicitly
deferred: there is no generic manual movement/Sale RPC, and public multi-product
operations internally sort product IDs so callers cannot request reverse lock
order. Use these guarded shell entry points rather than connecting with a bare
`psql` command. No script executes automatically as part of tests or application
startup.

If preparation stops after bootstrap or a migration, the optional reset entry
point is `bash tests/staging/reset-stock-staging.sh`. It requires the local
identity checks, the harness marker, a known migration ledger/schema set, and
typing `RESET quena_stock_staging`. It drops only the marked database-local
`public`, `auth`, `storage`, and `quena_staging` schemas in one transaction;
it does not drop the database or cluster roles. Unexpected schemas/extensions
cause it to refuse.

Every runner refuses a non-local server address, any database name other
than `quena_stock_staging`, a PostgreSQL major version other than 15, or a
non-UTF8 database. Preparation also refuses unexpected pre-existing
Quena/Supabase objects. Each migration contains its own transaction; the
private harness-ledger row is written immediately after that migration
commits. A process interruption in that narrow gap requires manual inspection
before continuing. Connections use a private empty mode-0600 password file,
`-w`, explicit loopback host/port/database/user, and cleared connection
variables. They do not read `.env.local` or `supabase/.temp`.

The bootstrap objects emulate only the migration dependencies used here:
roles, `auth.users`, `auth.uid()`, `public.user_role`, the minimal
`public.profiles` table, and the storage bucket/object tables. They are local
test support, not production migrations and not a complete Supabase Auth or
Storage implementation.

Bootstrap requires the local database connection role to have permission to
create the synthetic roles/schema/tables required by the migrations. If that
precondition is missing, the bootstrap transaction aborts without leaving
partial compatibility objects.

The fixture seed inserts only synthetic upload-object metadata, then follows the
real lifecycle: `request_ipos_import` creates a QUEUED request,
`claim_ipos_import_request` creates an UPLOADED batch and advances it to
PROCESSING, raw rows are inserted, `complete_ipos_import_request` completes the
snapshot, and the Phase 2B normalization RPC creates the normalized baseline.
It creates several stock baselines, a leading-zero barcode, same-product
aliases, and a duplicate barcode on two products. It contains no production
data. Runtime mutation/concurrency tests are a separate step and must run only
after migration 180000 has been applied to this isolated target.

The scripts never drop or recreate the database during runtime/concurrency
matrices. The concurrency runner recovers only tagged draft sessions and
neutralizes tagged posted stock effects before rerun; immutable audit rows are
retained. If a run stops or refuses due to an unexpected state, stop and inspect
the staging database; do not rerun a migration manually or alter objects until
the database contents are reviewed.

The Phase 3C.1 single-session and multi-session matrices passed on local
PostgreSQL 15. Migrations 171000 and 180000 are deployed and ledger-confirmed in
production. Migration 180000's 34-component read-only post-deployment checker
passed with no blocking failures or review gates; it verified 5,103 projection
rows, 5,103 inventory rows, 5,103 bootstrap events, and 4,527 active barcodes.
No production stock mutation tests were performed. Scenarios C and H remain
deferred for the API and lock-order reasons above. Those results cover the
Phase 3C.1A foundation and do not verify the later Stock Workspace read API.

For the local Phase 3C.1B read API, the user-run PostgreSQL 15.18 staging test
passed on the synthetic eight-product fixture. OWNER/ADMIN/GUDANG/KASIR,
search/filter/summary, and pagination assertions passed; EXPLAIN ANALYZE took
2.316 ms on this small fixture, not a production-scale benchmark. Migration
190000 is deployed, ledgered, production-verified, and immutable; its SHA-256
is `f3e6382354bf0c1f5d9f7f1530180ed039375ac42a7e7afac4bc9d493cc3e576`.
The app's `/stok` route was browser-smoke-tested. To verify an already-applied local
copy without reapplying it, run
`bash tests/staging/run-stock-workspace-read-check.sh`; the runner requires the
loopback, database, PostgreSQL 15, marker, ledger, and exact function-signature
guards and applies no migration.

The representative scale harness is
`bash tests/staging/run-stock-workspace-scale-check.sh`. It verifies the local
190000 migration ledger and the reviewed SQL file SHA-256 before opening a
single transaction. It creates synthetic iPos rows through the staging import
and normalization RPCs, adds provenance-matched projection baselines, runs the
OWNER/RLS Stock RPC correctness cases and EXPLAIN ANALYZE measurements, then
rolls the entire transaction back. The intended dataset is 5,104 outlet
memberships (the existing eight plus 5,096 synthetic products), 5,103 usable
projections, and one intentionally missing projection. Do not interpret its
synthetic results as production data. The validated after-ANALYZE local scale
timings were: default page 1 333.201 ms, page 50 253.113 ms, HABIS 226.374 ms,
MENIPIS 236.075 ms, rack-empty 223.425 ms, selective SKU 267.777 ms, and
selective barcode 267.678 ms. The earlier pathological plan was due to stale or
missing synthetic transaction statistics; no query rewrite or index change was
needed.

Phase 3C.2 Checkpoint 1 adds the bounded, read-only `/stok/opname` session list
for OWNER/ADMIN/GUDANG; KASIR is denied. The list has pagination and status
filtering and performs no mutations. Session creation and counting were added
in later checkpoints; rebase/exception revision hardening is covered by the
local-only 200000 matrix described below.

For Phase 3C.2 Checkpoint 2 CREATE_SESSION database validation, run
`bash tests/staging/run-stock-opname-create-matrix.sh`. This runner requires
the guarded local target, staging marker, and both 180000/190000 local ledger
entries; it never applies a migration. Its authenticated OWNER/ADMIN/GUDANG/
KASIR checks call only the existing CREATE_SESSION intent/apply RPCs. Each
case is isolated by a rollback-only PL/pgSQL subtransaction and the outer SQL
transaction ends with ROLLBACK, so no opname session, request, event, movement,
or stock change is retained. The matrix also checks same-request replay,
post-completion request identity, and active-scope overlap behavior.

For Phase 3C.2 Checkpoint 3 RECORD_COUNT validation, run
`bash tests/staging/run-stock-opname-count-matrix.sh`. It uses the same guarded
local target and durable-state fingerprint. OWNER/ADMIN/GUDANG count cases,
KASIR denial, zero and three-decimal quantities, replacement revisions, stale
client revisions, exact request replay, and a projection-baseline-stale result
are exercised through the existing trusted intent/apply RPCs. The stale
baseline setup uses existing create/count/review/post/reversal RPCs inside the
same transaction. The entire transaction rolls back; the runner then confirms
the durable staging fingerprint is unchanged. It never applies a migration.
The local PostgreSQL 15 RECORD_COUNT matrix passed. Browser mutation smoke
testing remains deferred because the available port 3001 app is production-
backed and no disposable local Supabase API/Auth/PostgREST stack is verified.
No production mutation was performed.

For the forward-only REBASE_ITEM / REVIEW_EXCEPTION revision guard and
database-derived progress contract, first review
`supabase/migrations/20260929200000_stock_opname_revision_guard_v1.sql`, then
run `bash tests/staging/apply-stock-opname-revision-guard.sh`. That runner
requires the exact local migration ledger through 190000, the synthetic stock
fixture marker, loopback PostgreSQL 15, and the 200000 functions to be absent;
it applies only 200000 and records the local harness ledger row afterward.
Then run `bash tests/staging/run-stock-opname-revision-guard-matrix.sh`. The
matrix covers role gates, revision mismatch without item/event mutation,
matching rebase/exception, retries, legacy pending requests, progress counts,
and unchanged stock quantities. All runtime mutations occur in one
rollback-only transaction, followed by a durable-state fingerprint comparison.
The revision-guard runtime matrix passed on local PostgreSQL staging, including
rollback and matching post-rollback durable-state fingerprints. Migration
200000 is not deployed to production. These are local staging checks only; do
not use these scripts against production. The revision guard does not add UI
or counting/review lifecycle controls.
