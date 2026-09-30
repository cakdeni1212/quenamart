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
summary. Use these guarded shell entry points rather than connecting with a
bare `psql` command. The runtime matrix rolls back its test transaction; it does
not test multi-session concurrency or durable behavior across independent
transactions. No script executes automatically as part of tests or application
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

The scripts never drop or recreate the database. If a run stops or refuses due
to an unexpected state, stop and inspect the staging database; do not rerun a
migration manually or alter objects until the database contents are reviewed.
