# Changelog

## 2026-10-10 — Native POS P1B persisted cart foundation

- Added migration `20260929330000_pos_cart_foundation_v1.sql` for persistent outlet-bound `ACTIVE`/`PARKED`/`CANCELLED` carts, item price evidence, append-only cart events, actor/payload-bound request replay, and revision guards.
- Added cashier-authorized exact barcode resolution and bounded POS product search, plus server actions/read model. OWNER/ADMIN can manage authorized outlet carts; KASIR can manage its own; GUDANG is denied. Price changes are visible and require an explicit server-verified acknowledgement.
- P1B has no sale completion, payment, revenue, stock movement, or costing writer. The disposable-clone PostgreSQL 15 rollback matrix validates cart behavior and unchanged operational fingerprints; production was not accessed.

## 2026-10-09 — Costing C3A local implementation

- Added forward-only local candidate migration `20260929290000_costing_purchase_receipt_acquisition_v1.sql` for protected receipt-item estimate revisions, explicit partial/provisional/unvalued projection fields, source-event uniqueness, and atomic receipt-post costing gated on `WAC_ACTIVE`.
- Receipt draft saves retain item identity for retained products and tombstone removed-item estimate evidence. Estimate, posting, and costing operations are database-controlled and actor-bound; GUDANG receives no financial values.
- Guarded PostgreSQL 15 staging C3A matrix passed and rolled back with durable state fingerprint unchanged. The migration is not deployed; bootstrap and WAC activation were not run.

## 2026-10-08 — Costing Engine v1 Initial HPP acceptance Checkpoint B (local UI)

- Added protected `/hpp-awal` workspace for OWNER/ADMIN with live bounded preview, server-side search/pagination, explicit preparation, exception resolution, stale handling, informational warnings, and OWNER-only approval.
- The UI calls only Checkpoint A contracts. It does not bootstrap, activate WAC, or modify stock/HPP data.

## 2026-10-08 — Costing Engine v1 Initial HPP acceptance Checkpoint A (deployed capability)

- Added migration `20260929260000_costing_initial_hpp_acceptance_v1.sql` with bounded manager preview, replay-safe preparation, exception dispositions, stale-fact checks, append-only audit, and OWNER-only approval evidence.
- Automatic eligibility uses source/HPP/history/review/override/finding/selling-price structure. Margin and absolute outlier signals remain warnings. Opening overrides and explicit zero acceptance do not rewrite legacy HPP or iPos history.
- Local rollback-only staging coverage passed. The capability migration was deployed; no production acceptance was prepared or approved, no bootstrap was run, and WAC remains inactive.

## 2026-10-08 — Costing Engine v1 Checkpoint 1 foundation (deployed capability)

- Deployed and read-only verified forward migration `20260929250000_costing_wac_foundation_v1.sql` for append-only cost batches/events, a separate valuation projection, outlet costing cutover state, controlled replay-safe bootstrap, and bounded OWNER/ADMIN read contract. It does not activate WAC or modify receipt/stock posting.
- Production costing tables and authority state remain empty. Business baselines were unchanged, and no costing bootstrap was run. The previously verified guarded PostgreSQL 15 local bootstrap/security matrix passed with its rollback fingerprint intact.
- Production HPP acceptance has not been prepared or approved. The deployed bootstrap still requires normal verified-HPP evidence and remains on hold; local Checkpoint A acceptance is not integrated with it. Checkpoint 2 and POS/COGS work remain pending.

## 2026-10-05 — Purchasing Phase 1: supplier master and physical goods receipt

- Added normalized supplier management and operational Barang Masuk routes for OWNER/ADMIN/GUDANG. KASIR remains denied; GUDANG receives operational fields only.
- Added migration `20260929220000_purchasing_receipts_v1.sql` for supplier, draft/posted receipt, item, event, and typed movement-source data plus controlled `POST_PURCHASE_RECEIPT` issue/apply RPCs.
- Receipt posting adds accepted plus bonus quantity through the existing movement ledger/projection path; rejected/damaged/short quantities do not enter stock. Posting is atomic, retry-safe, and makes the receipt immutable.
- The guarded local PostgreSQL 15 rollback-only receipt matrix passed and restored its durable fingerprint. Migration 220000 is deployed and verified in production. Invoice/payable/payment, WAC, supplier-return, attachment, and POS work remain separate from the Phase 1 stock receipt operation.

## 2026-10-05 — Purchasing Phase 2: simple nota and Cash/Tempo

- Added a separate invoice, payable, payment-allocation, event, and private invoice-document model. Invoice finalization recognizes supplier debt from the printed nota total; payment never changes stock.
- Added OWNER/ADMIN nota and Tempo Supplier screens for purchase prices, system-versus-supplier total comparison, Cash/Tempo, partial/full payments, derived balances/statuses, receipt links, and private photo/PDF evidence. GUDANG remains limited to operational receipts; KASIR remains denied.
- Goods-first receiving can be completed and posted without a nota, then linked to a later invoice without reposting stock. Purchase prices are retained for future WAC/COGS work, but HPP is not changed.
- Migration `20260929230000_purchasing_invoice_payables_v1.sql` is a local implementation candidate and has not been deployed. Staging runtime verification is required before a production preflight; production was not contacted or mutated for this phase.

## 2026-10-05 — Checkpoint 7 production deployment verified

- Migration `20260929210000_stock_opname_results_v1.sql` was deployed to the verified Quena Mart Supabase project and its official migration ledger, snapshot schema, trigger, RPC, security posture, and legacy POSTED read contract were verified read-only. No production stock/opname mutation was performed.

## 2026-10-05 — Phase 3C.2 Checkpoint 7D final verification

- Checkpoint 6 POST_SESSION regression and Checkpoint 7B results/snapshot staging matrices passed on guarded local PostgreSQL 15.18. The 5,103-item result RPC returned bounded pages and database-derived search/filter/summary results; measured execution was about 122 ms. Both runtime transactions rolled back and durable fingerprints matched.
- Checkpoint 7C application tests and full validation passed. At the time of this verification checkpoint, migration 210000 was awaiting its separate controlled production deployment; that deployment was later verified in the entry above.

## 2026-10-05 — Phase 3C.2 Checkpoint 7C Stock Opname results UI

- Added a read-only POSTED result view with database-derived summary, product/SKU search, result filters, bounded pagination, exception-specific display, metadata provenance notice, and session lifecycle timeline.
- Result rows use posting-time snapshots where available and historical opname quantities; the responsive desktop/mobile presentation does not read current projection values as historical results.

## 2026-10-05 — Phase 3C.2 Checkpoint 7B Stock Opname results foundation

- Added posting-time outlet and item metadata snapshots, deterministic active-barcode selection, immutable after-post snapshots, and no backfill of legacy POSTED sessions.
- Added the bounded `stock_opname_posted_results_page` RPC with DB-side summary/search/filter/pagination and `POST_SNAPSHOT`, `CURRENT_FALLBACK`, or `LEGACY_UNAVAILABLE` metadata provenance. Local staging runtime passed; production deployment is recorded in the later Checkpoint 7 deployment entry.

## 2026-10-04 — Phase 3C.2 Checkpoint 6 POST_SESSION local runtime passed

- Added OWNER/ADMIN-only POST_SESSION confirmation at `/stok/opname/[id]` through the existing intent/apply RPCs. The app sends only `session_id`; database content hashing, projection checks, movement posting, and atomic stale handling remain authoritative.
- Added distinct `SESSION_CHANGED`, `STALE_BASELINE`, known rejection, and uncertain apply outcomes. Retries reuse the session-scoped request UUID; POSTED is read-only. No durable movement summaries or schema changes were added.
- The guarded local PostgreSQL 15 staging matrix passed OWNER/ADMIN posting, GUDANG/KASIR denial, positive/negative/zero adjustments, reviewed exceptions, movement/projection ledger assertions, exact UUID replay, SESSION_CHANGED, and all-or-none STALE_BASELINE. The transaction rolled back and the durable fingerprint matched. The first attempt failed safely because it compared a KASIR RLS-filtered session count with an OWNER-visible count; no authorization leak occurred. No production mutation tests were performed.
- Browser mutation smoke remains deferred because no disposable local Supabase HTTP/Auth/PostgREST environment is verified.
- Documented the future authority-period invariant: decide and enforce how open opname sessions behave across period transitions before those transitions become operational.

## 2026-10-04 — Phase 3C.2 revision guard deployed and verified

- Deployed and ledgered immutable migration `20260929200000_stock_opname_revision_guard_v1.sql` (SHA-256 `167ff44d3076baeaf07ca6d554b84cf05a03b2a6f5e5fc370fac97e87bccd43f`). The production read-only checker passed gates 1–8; its informational data snapshot was unchanged: inventory 5,103, inventory history 5,103, projection 5,103, and no movements, opname sessions/items, count events, or operation requests.
- No production mutation tests were performed. Browser mutation smoke testing remains deferred because no disposable local Supabase API/Auth/PostgREST stack is verified. Checkpoint 4/5 UI is implemented; its staging runtime remains unverified.

## 2026-10-03 — Phase 3C.1B verified; Phase 3C.2 Checkpoint 1

- Migration `20260929190000_stock_workspace_read_v1.sql` is deployed, ledgered, production-verified, and immutable. Production migration ledger matches local through 190000. Artifact SHA-256: `f3e6382354bf0c1f5d9f7f1530180ed039375ac42a7e7afac4bc9d493cc3e576`.
- `/stok` was browser-smoke-tested. Local scale validation after ANALYZE passed at approximately 5,103 products: default page 1 333.201 ms; page 50 253.113 ms; HABIS 226.374 ms; MENIPIS 236.075 ms; rack-empty 223.425 ms; selective SKU 267.777 ms; selective barcode 267.678 ms. The earlier pathological plan was caused by stale/missing statistics in the synthetic transaction fixture; no query rewrite or index change was required.
- Added read-only `/stok/opname` session list for OWNER/ADMIN/GUDANG, with bounded pagination/filtering; KASIR is denied. No Opname mutation workflow is implemented yet.

## 2026-10-02 — Phase 3C.1B read-only Stock workspace

- Added `/stok` for OWNER, ADMIN, and GUDANG with effective stock from `stock_balance_projection`, product metadata, minimum stock, rack, barcode, presentation-only status, summary counts, live search, status/rack-empty filters, and server-side 50-row pagination.
- Scanner Enter uses the deployed exact `resolve_stock_barcode` RPC. Unknown and ambiguous barcodes are surfaced explicitly; no product creation or POS action is performed.
- The page is read-only and does not expose HPP/cost fields. Opname and stock mutation workflows remain out of scope.

## 2026-10-02 — Phase 3C.1B bounded Stock read proposal (superseded by deployment entry above)

- Added migration `20260929190000_stock_workspace_read_v1.sql` with one authenticated read-only RPC that returns a bounded page, filtered counts, summaries, and projection-integrity count.
- Refactored `/stok` to stop walking `product_workspace_list` pages and projection chunks; `stock_balance_projection.effective_quantity` remains authoritative. User-run PostgreSQL 15.18 local staging role, search/filter, summary, pagination, and bounded-row checks passed on the synthetic eight-product fixture. EXPLAIN ANALYZE took 2.316 ms on that fixture; this was not a production-scale benchmark. At the time of this proposal entry, migration 190000 had not yet been deployed; its verified deployment is recorded above.

## 2026-10-02 — Phase 3C.1A Stock Foundation deployed and verified

- Deployed and ledger-confirmed the forward-only correction-intent ambiguity fix `20260929171000`; read-only post-deployment checks passed for the ledger, function definitions/signatures, overloads, and security/grants.
- Deployed and ledger-confirmed stock foundation `20260929180000`. Its 34-component read-only production post-deployment checker passed: `overall_gate=PASS`, `blocking_failures=0`, `review_gates=0`.
- Production verification confirmed 5,103/5,103 stock projection rows, 5,103 inventory rows, 5,103 bootstrap events, and 4,527 active barcodes, with no unexpected movement, reconciliation, opname, or stock-operation request rows.
- Local PostgreSQL 15 single-session and multi-session matrices passed. Concurrency scenarios A/B/D/E/F/G passed with real lock overlap; C (no generic manual movement/Sale RPC) and H (no public reverse-order multi-product call path) remain deferred. No production mutation tests were performed.
- Phase 3C.1A is complete and did not include a native Stock UI; no production mutation tests were performed.

## 2026-09-30 — Stock database foundation (Phase 3C.1A; local staging verified)

- Added migration `20260929180000_stock_foundation_v1.sql` for a separate transitional stock balance projection, provenance-aware iPos baseline observations, immutable Quena movement ledger, explicit source reconciliation, stock-opname sessions/count history, and private operation idempotency requests. At the time of this entry it had only been applied to isolated local PostgreSQL staging; its current production status is recorded above.
- `product_inventory` remains the normalized iPos snapshot. Stock operations update only the projection and immutable movement/event records. Daily iPos sales imports remain reporting-only; no stock UI or importer behavior was added.
- Revised the local proposal after adversarial review: initial bootstrap now validates normalized `STOK` against the stored inventory quantity; ordinary imports only record observations (no upload-time/UUID chronology); barcode resolution groups matching rows by distinct product; and reversal pairs reconcile atomically by net delta.
- Documented the v1 no-negative-effective-stock rule, strictly increasing stale/count revisions, and deterministic FULL scope captured at session creation. Migration 180000 and forward fix 171000 passed the synthetic local PostgreSQL 15 runtime matrix; its transaction rolled back. Bootstrap verified 8/8 projection rows matched source and baseline values.
- Runtime coverage includes authenticated OWNER/GUDANG/KASIR behavior, barcode resolution, count/recount/post, exact retry, stale-baseline handling, negative-stock rejection, observation-only imports, reversal-group reconciliation, and immutability. Bootstrap verified 8/8 projection rows against source and baseline. The single-session matrix rolled back. At that checkpoint no native Stock UI had been implemented.
- Updated migration 180000 so every `RECORD_COUNT` intent requires and binds caller-observed `expected_revision`. A stale client revision returns replayable `STALE_BASELINE`/`ITEM_REVISION_MISMATCH` without overwriting the count or consuming a revision; projection-baseline staleness remains distinct. The revised migration passed the user-run PostgreSQL 15 local staging single-session matrix.
- The local-only multi-session harness passed A/B/E/F/D/G with separate psql sessions and observed database lock overlap. C is deferred because 180000 exposes no generic manual movement/Sale RPC. H is deferred because public multi-product paths sort product IDs internally and expose no caller-controlled reverse lock order. The runner commits local synthetic operations, neutralizes stock effects, and retains append-only audit rows. These staging results do not constitute production deployment or production mutation testing.
- At the time of this 2026-09-30 entry, production migration history remained through 170000 and neither 171000 nor 180000 was deployed. Current status is recorded in the 2026-10-02 entry above.

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
- Added forward-only migration `20260929150000_product_field_review_notes_idempotency_v1.sql` so review RPC retries compare the same trimmed evidence note stored by the RPC. This migration is deployed.
- Added forward-only migration `20260929160000_product_field_review_intents_v1.sql` for the private intent registry and issue/read RPCs. Exact completed retries reach database replay before freshness checks; fresh intents are checked against current source before issuing and again transactionally by the review RPC. This migration is deployed.
- Added safe typed error handling and deterministic latest-review ordering. Phase 3B.1B-2A has not been production runtime verified; authenticated review mutation verification remains pending in isolated staging.

## 2026-09-29 — Durable correction intent foundation (Phase 3B.1B-2B.1)

- Added forward-only migration `20260929170000_product_field_correction_intents_v1.sql`. It adds actor-bound correction intents, safe issue/recovery RPCs, and a UUID-only apply RPC. The existing completed correction request ledger remains the exact-result replay authority; persisted `BARCODE_CONFLICT` results complete their intent. Deployment is **LEDGER CONFIRMED**; remote structural verification was unavailable. The applied migration is immutable and future database changes require a new additive migration.
- Refactored the compatible correction RPC and UUID-only apply RPC to use one private correction implementation. Corrected values and reasons stay inside PostgreSQL during retry; metadata recovery does not return them.
- Added minimal authenticated server actions for intent issuance, safe metadata recovery, and UUID-only apply. No correction form UI was added.
- Added static SQL-contract and input-canonicalization tests. Authenticated correction-intent mutation and PostgreSQL concurrency runtime verification have NOT been performed; all mutation verification remains pending in isolated staging with dedicated role sessions and synthetic fixtures. No production mutation tests should be run.

## 2026-09-29 — Product field correction UI (Phase 3B.1B-2B.2)

- Added correction controls to `/audit-produk/[productId]` for supported fields only while the exact field is in `SEDANG_DICEK`. Barcode alias and iPos-source replacement are presented as separate actions; stock and minimum stock remain informational.
- OWNER/ADMIN can correct barcode, rack, HPP, and selling price. GUDANG can correct barcode and rack only; the existing server read model continues to omit financial source data for GUDANG. KASIR remains denied by the audit route/actions and database RPCs.
- The client keeps only the opaque database-issued correction intent UUID in local storage. Values and reasons are cleared from form state after intent issuance and stay in the private database intent; retries call the UUID-only apply action. Confirmed success/conflict consumes the stored UUID, and stale source errors require refreshing the audit.
- Added Indonesian currency parsing/formatting for HPP and selling price, a confirmation summary, barcode conflict messaging, and UI/contract tests. No database migration was created. Authenticated correction runtime and concurrency verification remains pending in isolated staging; the UI is not production mutation/runtime verified.
# 2026-10-10 — C3B local costing implementation

- Added protected source quantity layers, mutable balance projections, and immutable layer allocation evidence.
- Added atomic WAC costing for stock-opname variance and movement reversal, including proportional provenance allocation and exact reversal dependency checks.
- Extended future bootstrap and C3A purchase-receipt costing to create source layers. WAC activation and bootstrap execution remain separate, unauthorized actions.
# 2026-10-10 — C3C manual stock correction

- Added a manager-only, revision-guarded manual stock correction workflow with auditable drafts and immutable posted movements.
- Positive corrections remain UNVALUED; negative corrections reuse C3B unvalued-first, proportional source-layer depletion and aggregate-WAC financial depletion.
- Added capability for atomic stock/cost/source-layer posting under WAC_ACTIVE, a pre-mutation BOOTSTRAP_READY gate, and standard C3B movement reversal compatibility. WAC remains inactive and bootstrap is not run by this migration.

# 2026-10-10 — C3D supplier returns

- Added supplier-linked physical return drafts with optional native receipt-item attribution and support for unlinked legacy inventory.
- Posting validates both accepted-plus-bonus attribution and current stock. WAC_ACTIVE uses aggregate WAC and C3B unvalued-first proportional source-layer depletion atomically; source receipt prices do not determine return value.
- OWNER/ADMIN post, GUDANG may manage drafts, and KASIR is denied. Supplier invoices, payables, and payments remain unchanged. This migration is a local capability candidate only.
