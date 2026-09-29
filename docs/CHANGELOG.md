# Changelog

## 2026-09-28 — iPos Phase 2B commit engine (executed and verified)

- Added the transactional commit migration, separate normalization lifecycle/proposal tables, raw-row link guard, versioned idempotency, global advisory serialization, and service-role direct-write revocations for normalized targets. The migration was applied and the 5,103-row production commit was independently verified complete.
- Added a server-only commit core and bearer-protected internal route. The route rebuilds the proposal through the shared verified preflight engine; PostgreSQL compares live product/barcode/override state before mutation and commits normalized values, database-triggered histories, snapshot findings/resolutions, override-conflict proposal records, row links, and completion atomically.
- Added normalization proposal/audit-code output and commit/migration contract tests. Production verification confirmed 5,103 products linked to 5,103 raw rows, 4,527 active barcodes, and 5,103 price/cost/inventory/outlet-setting rows.

## 2026-09-28 — iPos Phase 2B preflight verified

- Verified the preflight for batch `eb72f6ad-1cf2-42fb-b899-c894db102c30` against the independent workbook audit, including all 5,103 rows and finding counts.
- At the time of preflight verification, the immutable raw snapshot remained unlinked; the later Phase 2B commit is recorded above.

# 2026-09-28 — iPos Import Phase 2B preflight implementation

- Added deterministic normalization, Indonesian numeric parsing, exact-SKU matching, audit-candidate calculation, duplicate checks, and active manual-override conflict reporting for the immutable Phase 2A snapshot.
- Added a trusted internal preflight route with a distinct server-only bearer secret. It verifies completed raw snapshot invariants and performs SELECT-only reads; no normalized production writes or audit persistence occur.
- Added synthetic normalization/audit tests and documented the report's sensitive HPP content and non-transactional paginated-read limitation. The preflight was later verified against the production batch (see above).

## 2026-09-28 — iPos Import Phase 2A implementation

- Added a server-only iPos workbook parser and trusted worker core for format validation, checksum capture, and immutable `RAW_ONLY` row snapshots.
- Added a bearer-protected manual internal worker route; it is not invoked by the browser UI.
- Added transactional claim/finalize/fail RPC migration `20260928115000_ipos_worker_v1.sql`. Worker access requires server-only credentials.
- Added parser tests and documented Phase 2B as future work. No product, price/HPP, inventory, or audit writes were implemented.

## 2026-09-28 — iPos Import Phase 1

- Applied Product & iPos Import Schema v1 to Supabase; local and remote migration history both show version `20260928`.
- Added the role-protected `/import-ipos` page for OWNER, ADMIN, and GUDANG with XLSX extension/size validation, private original-file upload, authenticated import-request RPC, and request status display.
- Documented the Phase 1 contract and behavior when upload succeeds but request creation fails. No XLSX parsing, product writes, inventory/pricing/HPP updates, audit findings, or import worker were implemented.

## 2026-09-28 — Foundation verification

- Diagnosed stalled Node checks: the workspace and dependency files are marked `dataless` under macOS File Provider (`Documents` has File Provider domain metadata). Node's synchronous file reads stop while materializing placeholders; an ESLint process sample showed the main thread repeatedly inside Node file reads. Elevated lint showed the same stall, so sandboxing alone is not the cause. Bulk copying dependencies also stopped while reading a dataless dependency.
- `npm run lint`: started twice (including outside the sandbox); still stalled while loading ESLint dependencies. Not passed.
- `npx tsc --noEmit`: started; made slow progress through declaration files but remained stalled in `node_modules/@types/node` after several minutes. Not passed.
- Build was not run because lint and typecheck did not succeed. Webpack dev server was attempted on port 3001 but never reached ready; no HTTP/auth route tests could be run.
- Static auth review confirms server-side `auth.getUser()`, current-profile lookup from `public.profiles`, `is_active` enforcement, database-sourced role selection, and no service-role key references in app code. Runtime cookie/login/logout/redirect behavior remains unverified. Reviewed the OWNER/ADMIN/KASIR/GUDANG section matrix in `ARCHITECTURE.md`.
- Added a manual least-privilege profile RLS migration; it has not been applied to Supabase.

## 2026-09-28

- Replaced the Next.js starter screen with Quena Mart login, authenticated shell, responsive dashboard placeholders, and role-aware workspace navigation.
- Added Supabase server client, cookie refresh proxy, login/logout actions, active profile loading, and server section guards.
- Added role and module documentation. No database changes made.
## 2026-09-29 — Product & Audit workspace (Phase 3A)

- Added paginated read-only product list, audit overview, and product detail routes backed by normalized Supabase data.
- Added `20260929100000_product_workspace_read_v1.sql` for server-side filtering, pagination, persisted latest-snapshot audit counts, and role-aware HPP projection. Migration applied and functionally verified in production.
- Documented verified Phase 2B production commit and the transition roadmap for iPos and native POS reporting.

## 2026-09-29 — Field audit database foundation (Phase 3B.1A)

- Applied additive migration `20260929130000_field_audit_foundation_v1.sql` to production; local and remote migration ledgers are synchronized.
- Post-migration structural/security verification passed: reconciliation and private correction-request tables exist; review request/barcode columns and the post-raw-link barcode finalizer trigger exist; privileged functions have the verified owner/security settings; anon cannot execute correction/review RPCs; authenticated execution is gated by database role checks; and RLS is enabled with the correction ledger private and reconciliation events role-filtered.
- Static/contract tests passed: 49 tests. Production mutation/runtime RPC tests were intentionally not run because each PostgREST RPC has its own transaction and successful calls persist review, correction, history, or idempotency records without guaranteed exact cleanup.
- Phase 3B.1A is deployed and structurally/security verified, but is not end-to-end runtime verified. The full review/correction/idempotency/barcode/authorization matrix and controlled import reconciliation/finalizer test remain pending against isolated staging with real authenticated role sessions and synthetic fixtures.
- Next development phase: Phase 3B.1B — Field Audit UI/workflow.

## 2026-09-29 — Read-only focused field audit detail (Phase 3B.1B-1)

- Added a server-only field-audit read model and `/audit-produk/[productId]` detail screen. It separates snapshot findings, source/current values, human review, active overrides, and reconciliation state; stock/minimum remain informational.
- Financial source/audit reads are loaded only for OWNER/ADMIN. GUDANG receives only nonfinancial source, review, override, reconciliation, and inventory data through the session-bound Supabase server client. No mutation RPCs or service-role client are used.
- Added issue-badge navigation from the existing product list and focused read-model/query-context contract tests. This is a read-only first slice; review actions were added later in Phase 3B.1B-2A, while corrections, next-item navigation, and staging runtime verification remain pending.

## 2026-09-29 — Human field review workflow (Phase 3B.1B-2A)

- Added authenticated server action and focused audit controls for starting a field review and marking it verified through the deployed `record_product_field_review` RPC.
- The action derives the active profile from the cookie session, checks audit access and field permissions, re-reads the current source row before submitting, and does not accept actor/role values from the browser. It uses the normal session-bound Supabase client; no correction RPC or service-role client is used.
- Review status and optional evidence remain separate from imported findings, overrides, and source reconciliation. Stock/minimum can be reviewed as informational fields, but no stock values can be changed. HPP source reads remain OWNER/ADMIN-only.
- Mutation runtime verification remains pending in isolated staging with authenticated role sessions; no production mutation test was run.

## 2026-09-29 — Review retry/idempotency hardening (Phase 3B.1B-2A)

- Review forms now use database-issued, actor- and canonical-payload-bound intent UUIDs. The browser persists only the opaque ID so the same pending/unknown intent can be recovered after reload; confirmed success consumes it, and a later action receives a new ID.
- Added local, forward-only migration `20260929150000_product_field_review_notes_idempotency_v1.sql` so review RPC retries compare the same trimmed evidence note stored by the RPC. This migration is **LOCAL / NOT DEPLOYED**.
- Added local, forward-only migration `20260929160000_product_field_review_intents_v1.sql` for the private intent registry and issue/read RPCs. Exact completed retries reach database replay before freshness checks; fresh intents are checked against current source before issuing and again transactionally by the review RPC. This migration is **LOCAL / NOT DEPLOYED**.
- Added safe typed error handling and deterministic latest-review ordering. Phase 3B.1B-2A has not been production runtime verified; authenticated review mutation verification remains pending in isolated staging.
