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

Costing HPP acceptance Checkpoint A is validated by
`bash tests/staging/apply-costing-hpp-acceptance.sh` followed by
`bash tests/staging/run-costing-hpp-acceptance-matrix.sh`. The runtime matrix
uses only rollback-scoped HPP, source, review, selling-price, audit-finding,
acceptance, and permission fixtures; it verifies source/stock/WAC fingerprints
after rollback. `bash tests/staging/rollback-costing-hpp-acceptance.sh` removes
only the candidate Checkpoint A schema when its private harness ledger entry is
the latest. These scripts do not contact Supabase or perform bootstrap.

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
200000 is now deployed, ledgered, and production-verified; its read-only
postdeploy gates 1–8 passed and the informational data snapshot was unchanged.
These scripts remain local staging checks only; do not use them against
production. No production mutation tests were performed, and browser mutation
smoke testing remains deferred because no disposable local Supabase
API/Auth/PostgREST stack is verified.

For Phase 3C.2 Checkpoint 6 POST_SESSION runtime validation, run
`bash tests/staging/run-stock-opname-post-matrix.sh`. The runner refuses any
target other than loopback `quena_stock_staging` on PostgreSQL 15 with the
staging marker and migrations through 200000 ledgered; it applies no migration.
It uses the existing synthetic OWNER/ADMIN/GUDANG/KASIR profiles and stock
fixtures, runs intent/apply requests in one transaction, and rolls the matrix
back. It checks negative/positive/zero adjustments, reviewed exceptions, batch
and movement linkage, projection versions/events, OWNER/ADMIN access,
GUDANG/KASIR denial, exact replay, rejection of a new post after POSTED,
SESSION_CHANGED, and all-or-none STALE_BASELINE behavior. The user-run matrix
passed on local PostgreSQL 15 staging; the transaction rolled back and the
durable stock/opname/inventory fingerprint matched. Its first attempt failed
safely because a session count was compared under KASIR RLS rather than OWNER
visibility; that harness assertion was corrected, with no authorization
change. The runner never applies a migration, contacts production, or reads
`.env.local`. No production mutation tests were performed, and browser mutation
smoke remains deferred until a disposable local Supabase HTTP/Auth/PostgREST
environment is verified.

Phase 3C.2 Checkpoint 7B adds posting-time product/outlet display snapshots and
the bounded, read-only `stock_opname_posted_results_page` RPC. After reviewing
`supabase/migrations/20260929210000_stock_opname_results_v1.sql`, apply only
that forward migration to the guarded local target with
`bash tests/staging/apply-stock-opname-results.sh`. Then run
`bash tests/staging/run-stock-opname-results-matrix.sh`; it first reruns the
complete rollback-only Checkpoint 6 POST_SESSION regression matrix, then tests
posting-time snapshots, legacy metadata provenance, result filters/search,
summary/pagination at 5,103 items, role gates, and unchanged master metadata
after posting. Both SQL matrices end with ROLLBACK, and the runner compares
durable stock/opname/master-data fingerprints before and after. This validates
local PostgreSQL behavior only; it does not contact production or perform
production mutation tests. Browser mutation smoke remains deferred until a
disposable local Supabase HTTP/Auth/PostgREST environment is verified.
The local Checkpoint 7B matrix passed with the Checkpoint 6 post regression
matrix; both rollback fingerprints matched. The final 5,103-row result RPC
measurement completed in about 164 ms on the local synthetic fixture. The
matrix runner verifies the migration checksum and refreshes only the results
RPC from that pinned source; it does not replay the migration. The existing
product SKU immutability guard rejects a direct SKU re-key, so that case
verifies the rejection and confirms result snapshots remain stable; the test
does not bypass that guard. Migration 210000 is installed only in local staging
and has not been deployed to production.

For Costing Engine v1 Checkpoint 1, review
`supabase/migrations/20260929250000_costing_wac_foundation_v1.sql`, then run
`bash tests/staging/apply-costing-wac-foundation.sh`. It requires the exact
guarded local migration chain through 240000 and applies only 250000 to
`localhost:5432/quena_stock_staging`. Then run
`bash tests/staging/run-costing-wac-foundation-matrix.sh`. The runtime cases
use existing synthetic stock fixtures, insert temporary verification evidence
and adjust only fixture state inside one rollback-only transaction, then
assert the durable stock projection, product_inventory, product_costs,
product_cost_history, iPos rows, and review fingerprint is restored. It tests
verified-HPP opening value, positive stock with missing HPP as UNVALUED, zero
stock semantics, exact replay and second-bootstrap refusal, manager versus
GUDANG/KASIR reads and direct writes, ledger immutability, event/version links,
precision, and negative valuation rejection. This foundation does not activate
WAC or alter receipt stock posting. No production target, data, or credentials
are used.

For the HPP acceptance preview performance replacement, apply only
`20260929270000_costing_hpp_acceptance_preview_performance_v1.sql` to the
guarded local target with
`bash tests/staging/apply-costing-hpp-preview-performance.sh`. Then run
`bash tests/staging/run-costing-hpp-preview-performance.sh`. The runtime script
uses a read-only transaction, compares summary/filter/search/page results with
the unchanged evaluator, and prints `EXPLAIN ANALYZE` timings for exceptions,
candidates, warnings, search, and page 2. It does not create acceptance rows or
change business data. Its timings are representative only of the local staging
dataset available at the time; no production endpoint is used.
