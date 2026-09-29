# Features

## Implemented foundation

- Email/password login and logout via Supabase SSR.
- Persistent Supabase cookie session refresh through Next.js 16 `proxy.ts`.
- Server-verified active profile loading and role-aware landing.
- Protected workspace layout and server section checks.
- Responsive Quena Mart shell, sidebar, empty-state dashboard, and future metric/chart placeholders.

## Planned

See [TODO](TODO.md) and the individual module specifications for POS, loyalty, supplier tempo, corrections, and reporting work still pending.
# Product catalog and data audit — Phase 3A

- Implemented read-only `/produk`, `/audit-produk`, and `/produk/[id]` pages using normalized Supabase product data.
- Product search, filters, audit issue selection, and 25-row pagination are database-side. The UI shows persisted findings for the latest completed snapshot.
- OWNER/ADMIN may see HPP. GUDANG product responses omit HPP under RLS and the query projection; KASIR cannot access the product workspace. The query migration still requires manual application.
- No edit, correction, or daily sales import behavior is included.
