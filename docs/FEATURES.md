# Features

## Implemented foundation

- Email/password login and logout via Supabase SSR.
- Persistent Supabase cookie session refresh through Next.js 16 `proxy.ts`.
- Server-verified active profile loading and role-aware landing.
- Protected workspace layout and server section checks.
- Responsive Quena Mart shell, sidebar, empty-state dashboard, and future metric/chart placeholders.
- `/pengaturan` provides a concise Settings directory. `/pengaturan/toko-outlet` edits the existing outlet identity; `/pengaturan/kasir-penjualan` manages outlet-scoped receipt presentation, checkout payment availability, hold behavior, and cart-cancellation confirmation. OWNER updates; OWNER/ADMIN read management settings; POS consumes a separate bounded effective-settings contract for KASIR. Future configuration sections remain unavailable and do not link to placeholders.
- Protected `/hpp-awal` Persiapan HPP Awal workspace for OWNER/ADMIN, using Checkpoint A bounded preview, explicit preparation, reasoned exception resolution, and OWNER-only approval. Warnings remain informational; approval does not bootstrap or change stock.

## Phase 3C.1B Stock workspace

- Implemented read-only `/stok` for OWNER, ADMIN, and GUDANG using the deployed stock projection and existing exact barcode resolver.
- Migration `20260929190000_stock_workspace_read_v1.sql` supplies one bounded `stock_workspace_read_page` RPC for server-side search/status/rack/category filters, summary counts, and 50-row pagination. It sources effective stock only from the projection and reports incomplete projections without snapshot fallback.
- Search is debounced and URL-backed; scanner submissions use exact barcode matching and surface unknown/ambiguous states.
- No stock mutations, opname actions, or HPP/cost fields are included. Stock opname operations remain a separate next phase.
- Migration 190000 is deployed, ledgered, production-verified, immutable, and matches local ledger state. `/stok` was browser-smoke-tested. After ANALYZE, local scale validation at about 5,103 products passed: page 1 333.201 ms, page 50 253.113 ms, HABIS 226.374 ms, MENIPIS 236.075 ms, rack-empty 223.425 ms, selective SKU 267.777 ms, and selective barcode 267.678 ms. The earlier pathological plan came from stale/missing synthetic transaction statistics; no SQL rewrite or index change was required.

## Phase 3C.2 Checkpoint 1 — Stock Opname session list

- Implemented read-only `/stok/opname` with bounded pagination and status filtering for OWNER/ADMIN/GUDANG; KASIR is denied.
- The page shows session/outlet/scope/status/progress information and has no mutation actions. Opname creation/count/review/post workflows remain unimplemented.

## Planned

See [TODO](TODO.md) and the individual module specifications for POS, loyalty, supplier tempo, corrections, and reporting work still pending.

# Product catalog and data audit — Phase 3A

- Implemented read-only `/produk`, `/audit-produk`, and `/produk/[id]` pages using normalized Supabase product data.
- Product search, filters, audit issue selection, and 25-row pagination are database-side. The UI shows persisted findings for the latest completed snapshot.
- OWNER/ADMIN may see HPP. GUDANG product responses omit HPP under RLS and the query projection; KASIR cannot access the product workspace. The query migration still requires manual application.
- No edit, correction, or daily sales import behavior is included.
