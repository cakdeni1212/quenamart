# Architecture

## Application

Next.js App Router, TypeScript, Tailwind CSS 4. Route groups under `app/(workspace)` share an authenticated shell; `/login` is outside that group. `src/lib/auth/roles.ts` defines the role vocabulary, section access matrix, and landing paths. `src/lib/auth/session.ts` resolves the current Supabase user and active profile on the server.

## Supabase session

`src/lib/supabase/client.ts` is the browser client. `src/lib/supabase/server.ts` uses the asynchronous Next.js `cookies()` API and `@supabase/ssr`. Root `proxy.ts` refreshes auth cookies with `auth.getUser()` only. Protected workspace layouts/actions verify the user with Supabase and load `profiles` under the caller's RLS context.

Login and logout are server actions. Login validates credentials, requires an active profile with a recognized role, and routes OWNER/ADMIN to Dashboard, KASIR to Kasir, and GUDANG to Produk. Workspace section pages validate permissions on the server. Sidebar filtering is only presentation; every future mutation/query must also check authorization server-side and be constrained by RLS.

## Current section access matrix

| Section | OWNER | ADMIN | KASIR | GUDANG |
| --- | --- | --- | --- | --- |
| Dashboard | Yes | Yes | Yes | Yes |
| Kasir, Transaksi | Yes | Yes | Yes | — |
| Produk, Stok, Audit Produk, Pembelian | Yes | Yes | — | Yes |
| Tempo Supplier, Laporan, Pengaturan | Yes | Yes | — | — |
| Member | Yes | Yes | Yes | — |
| Import iPos | Yes | Yes | — | Yes |

This is the application foundation matrix in `src/lib/auth/roles.ts`; OWNER is full access and ADMIN has operational management access. HPP access is enforced by the deployed product-cost RLS policy and the Phase 3A database projection.

## Product & iPos data boundaries

The deployed schema in `supabase/migrations/20260928_product_ipos_schema_v1.sql` separates sensitive `product_costs`/cost history from cashier-readable selling prices. OWNER and ADMIN can read HPP, raw iPos rows, and original workbooks. GUDANG can read normalized non-cost product, inventory, rack, price, and audit data, and can upload an XLSX and enqueue an import request. GUDANG cannot read/list/download the workbook or access raw rows, HPP, cost history, or cost-related audit data. KASIR can read product, barcode, stock, and selling-price data. All user-facing access requires an active profile and RLS remains the database read boundary.

The original XLSX is stored in private bucket `quena-ipos-imports`, limited to XLSX MIME and 25 MiB. Uploads use `incoming/<authenticated-user-uuid>/<random-uuid>.xlsx`; GUDANG can insert only into its own user-scoped path, while OWNER/ADMIN can insert manager paths. OWNER/ADMIN can list and download. No authenticated role can update/delete snapshot objects. The authenticated `request_ipos_import(p_outlet_id uuid, p_storage_path text)` RPC allows OWNER, ADMIN, and GUDANG, validates the uploader path and stored object, inserts a request, and returns its UUID.

Application Phase 1 at `/import-ipos` implements only file selection/validation, authenticated Storage upload, RPC request creation, and reading the new request's state/time under RLS. It uses the browser anon key and user session; it does not use a service-role key. If request creation fails after upload, the UI reports the retained object and can retry the request for the same path.

Phase 2A adds a server-only XLSX parser and worker core at `src/lib/ipos`. A manual internal POST route requires a separate bearer secret and is not linked from the UI. The worker's Supabase admin client is guarded by `server-only` and reads the private workbook using `SUPABASE_SERVICE_ROLE_KEY`; neither privileged secret is browser-capable. The follow-up migration supplies atomic claim/batch creation and atomic completion/failure functions. Concurrent invocations can claim a QUEUED request only once. The worker validates the iPos format, hashes the workbook, and stores immutable source rows in chunks. The verified production snapshot has 5,103 rows and no product links. The worker does not normalize or mutate products, barcodes, prices, HPP, inventory, overrides, or audit findings. Failed attempts retain any inserted rows and cannot be silently marked complete. Crashed attempts require manual investigation; no automatic lease/reclaim is implemented.

Phase 2B preflight code (`normalize.ts`, `preflight-engine.ts`, and `preflight.ts`) calculates normalization proposals and audit candidates from an already-completed raw snapshot. The internal `POST /api/internal/ipos-preflight` route uses a distinct `IPOS_PREFLIGHT_SECRET`; it is not linked to the browser and performs SELECT-only Supabase calls. It checks snapshot integrity and reads existing products, barcodes, and active overrides to report exact-SKU create/update candidates, audit counts, and override conflicts. Its response includes proposed HPP and is sensitive. The production preflight for batch `eb72f6ad-1cf2-42fb-b899-c894db102c30` was verified against the independent audit.

The Phase 2B commit engine was executed and independently verified. Its internal `POST /api/internal/ipos-commit` route used a separate `IPOS_COMMIT_SECRET` and regenerated the proposal with the same preflight normalizer. The applied `20260928143000_ipos_normalization_commit_v1.sql` migration adds transaction-scoped serialization, a versioned idempotency record, protected proposal rows, and a guarded one-time `RAW_ONLY` to `VALID`/`INVALID` link transition. The commit wrote 5,103 products, linked the raw rows, persisted normalized outlet values/history/findings, and recorded `ipos-v1-preflight` as `COMPLETED`. The original Phase 2A batch remains `COMPLETED` and raw JSON remains immutable.

The production commit route was called for the verified snapshot. Its response contains counts only, not HPP values. Any future normalized writer must use advisory lock `(734921, 2)`; service-role direct write privileges are revoked from normalized commit targets by the applied Phase 2B migration.

## Authorization principles

- Use the anon/publishable key with the user's session for normal application operations.
- Do not place a service role key in client code or use it to bypass intended RLS.
- Add server-side role checks to every server action and route handler. Treat client input and hidden UI as untrusted.
- Enforce data boundaries with Supabase RLS as the final database control. The app's role matrix is a UX and server foundation, not a replacement for RLS.
- Sensitive HPP, capital, profit, and other financial fields need explicit role grants and database policies. The deployed product schema grants HPP access to OWNER and ADMIN only; other financial modules remain undecided.

## Routes

`/login` is public and redirects active authenticated profiles to their role landing page. `/dashboard` and workspace routes require an active profile. Unknown workspace section URLs return 404. Current modules beyond dashboard/Kasir/Produk are deliberate placeholders.
# Phase 3A Product & Audit workspace

`/produk`, `/audit-produk`, and `/produk/[id]` are authenticated, server-rendered pages. The product route checks `canAccessSection`; RLS remains authoritative for data. Search, exact category/rack filters, finding/no-finding filters, and 25-row pagination run in Postgres. Audit cards count persisted OPEN findings on the latest completed normalization snapshot. The product detail page is read-only.

The query migration uses invoker functions with the session-bound Supabase client. OWNER/ADMIN can read `product_costs`; the existing cost policy denies other roles. Returned HPP is explicitly projected only for OWNER/ADMIN. KASIR is not authorized for the product section. No privileged credential is sent to the browser. The latest-snapshot helper returns only identifiers and requires an active role.

## Phase 3B.1A field-audit database foundation (deployed; staging runtime verification pending)

Migration `20260929130000_field_audit_foundation_v1.sql` is applied in production, and local/remote migration ledgers are synchronized. Post-migration structural/security verification passed for the reconciliation and private request tables, review columns, post-raw-link finalizer trigger/function, function ownership/security settings, RPC grants, RLS, and role-based reconciliation reads. Corrections are limited to barcode, rack, HPP, and selling price; inventory quantity and minimum remain informational. HPP reads/corrections/reconciliation are OWNER/ADMIN only. GUDANG can review/correct barcode and rack, and KASIR has no field-audit access. Request IDs are bound in a private database table to actor, product/outlet, field, source row, operation, normalized value, and reason; exact retries replay the original result, while payload reuse is rejected. Raw import JSON is never updated and direct authenticated table DML remains revoked.

The existing static/contract suite passed (49 tests). Runtime mutation tests were not run against production: independent PostgREST RPC transactions cannot be wrapped in one client rollback, and successful review/correction calls persist audit/history/request records without guaranteed exact cleanup. Phase 3B.1A is deployed and structurally/security verified, not end-to-end runtime verified. Run the full authorization, review, correction, idempotency, barcode, conflict, and controlled re-import/finalizer matrix in isolated staging with real authenticated OWNER/ADMIN/GUDANG/KASIR sessions and synthetic fixtures. The next development phase is Phase 3B.1B — Field Audit UI/workflow.
