# Quena Mart

This is the entry point for future coding agents. Read this file first, then the relevant files in `docs/` before changing a business module.

## Current state

Quena Mart is a Next.js 16.3.6 App Router application using TypeScript, Tailwind CSS 4, and Supabase. The current implementation covers email/password authentication, server-verified active profiles, role-aware landing and navigation, protected workspace routes, a dashboard shell, and the initial architecture documentation. Business modules remain placeholders.

## Working agreements

- Preserve existing `.env.local` values. Only `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` may be used by browser-capable code. Never expose a service role key.
- Use `@supabase/ssr` browser and server clients. Use `proxy.ts` for cookie refresh and optimistic redirects only; verify identity/profile and authorization in server layouts, actions, route handlers, and database RLS policies.
- Roles are `OWNER`, `ADMIN`, `KASIR`, and `GUDANG`. The current profile is fetched from `public.profiles`; inactive or invalid profiles are denied.
- Dashboard financial cards intentionally show placeholders. Do not invent business or financial values.
- For this Next.js version, read relevant installed guides under `node_modules/next/dist/docs/` before editing framework conventions. Use Webpack for local development (`npm run dev -- --webpack --port 3001`) because Turbopack has shown intermittent filesystem/read errors.
- Keep modules small and permission checks on the server. UI filtering is for usability, not authorization.

## Documentation map

- [Architecture](ARCHITECTURE.md): routing, sessions, role checks, and security boundaries.
- [Database](DATABASE.md): current Supabase schema and future data guidance.
- [iPos import](IPOS_IMPORT.md), [product audit](AUDIT_RULES.md), [POS](POS.md), [loyalty](LOYALTY.md), [supplier terms](TEMPO_SUPPLIER.md), [reporting](REPORTING.md), and [Costing Engine](COSTING.md): data contracts and future integration guidance.
- [Features](FEATURES.md): implemented and planned scope.
- [Changelog](CHANGELOG.md): shipped changes.
- [TODO](TODO.md): next work and open decisions.

## iPos import requirements

Future import must accept raw XLSX exports from iPos. The current source dataset contains 5,103 SKUs. Preserve the original workbook/source rows and values; do not overwrite them with normalized or corrected data. Automated audit flags can overlap for a single SKU. Provide a future correction workflow and export without losing source values or audit history.

The frozen v1 database mapping, parsing, snapshot, correction, and audit contract is documented in [iPos Import](IPOS_IMPORT.md), [Product Audit Rules](AUDIT_RULES.md), and [Database](DATABASE.md). Phase 2B was successfully committed and independently verified in production: 5,103 normalized products linked to 5,103 raw iPos rows, 4,527 active normalized barcodes, and 5,103 rows each for inventory, selling price, HPP/cost, and outlet settings; normalization version `ipos-v1-preflight`, status `COMPLETED`. Phase 3A's read-only, server-rendered product list and audit overview are backed by the applied and production-verified database migration. OWNER/ADMIN can see HPP; GUDANG cannot query cost through RLS and receives no HPP value. KASIR has no product workspace access. Phase 3B.1A migration `20260929130000_field_audit_foundation_v1.sql` is applied, local/remote migration ledgers are synchronized, and production structural/security verification passed. Its 49-test static/contract suite passed. Runtime mutation tests were intentionally deferred because independent PostgREST transactions and persistent audit/history records prevent guaranteed exact cleanup; the complete matrix remains for isolated staging with real authenticated role sessions and synthetic fixtures. No correction UI is implemented yet. Next is Phase 3B.1B — Field Audit UI/workflow. iPos remains the transaction system of record until native Quena Mart POS is production-ready. A future phase will import daily iPos sales reports for analytics and combine them with native POS sales in a shared reporting model that retains source identity (`IPOS_IMPORT` or `QUENA_POS`). Daily sales import is out of scope for Phase 3B.1A.
