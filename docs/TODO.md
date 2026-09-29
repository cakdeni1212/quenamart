# TODO

## Foundation follow-up

- [x] Verify remote `public.profiles` RLS and grants: own-row SELECT only; anon has no privileges; authenticated is SELECT-only. Do not rerun or change the profiles migration as part of the product schema work.
- [ ] Move this working copy and `node_modules` out of the File Provider managed `Documents` folder (or pin them for offline use), then rerun lint, typecheck, build, and route/auth checks.
- [ ] Run the OWNER login, dashboard, logout, and unauthenticated redirect smoke tests after the checks and server can start. No OWNER password is stored in this repository or supplied for this verification.
- [x] Confirm deployed `public.profiles` policy and table grants. Verified Storage currently has zero buckets.
- [x] Apply the reviewed Product & iPos Import Schema v1 migration and verify local/remote migration history at version `20260928`.
- [x] Implement Phase 1 upload/request UI: validate/select XLSX, upload the original file through the authenticated session, call the request RPC, and display request status. This does not parse the workbook or mutate product data.
- [x] Apply the reviewed `20260928115000_ipos_worker_v1.sql` migration and verify the Phase 2A production snapshot: 5,103 immutable rows, Excel rows 3–5,105, zero product links.
- [x] Implement Phase 2A parser and trusted worker code, plus focused parser tests. The verified production request/batch was processed under manual control.
- [x] Implement Phase 2B read-only preflight normalization/audit calculation, exact-SKU matching, override conflict reporting, and focused tests. First controlled production preflight matched the independent audit for batch `eb72f6ad-1cf2-42fb-b899-c894db102c30`.
- [x] Implement the Phase 2B transactional commit RPC/route, idempotency guard, stale-preflight state comparison, normalized write/history/finding flow, and focused synthetic/static tests.
- [x] Review and apply the Phase 2B normalization migration; independently verify the successful production commit (5,103 product rows linked to raw data; status COMPLETED).
- [x] Review and apply `20260929100000_product_workspace_read_v1.sql`; Phase 3A product and audit pages are production verified.
- [x] Review and apply additive `20260929130000_field_audit_foundation_v1.sql`; verify production structure/security and synchronize local/remote migration ledgers. Runtime mutation tests remain intentionally pending in isolated staging.
- [ ] Provision/use isolated staging with synthetic product/import fixtures and real authenticated OWNER, ADMIN, GUDANG, and KASIR sessions; run the Phase 3B.1A runtime matrix without using production fixtures.
- [ ] In staging, verify review authorization/transitions/idempotency; correction authorization and request idempotency; barcode `ADD_ALIAS`, `REPLACE_SOURCE`, and duplicate conflict; KASIR/anonymous denials; and controlled re-import reconciliation/finalizer behavior.
- [x] Implement Phase 3B.1B-1 read-only focused Product Field Audit detail at `/audit-produk/[productId]`, with role-safe source/current/review/override/reconciliation reads and no mutation actions.
- [x] Implement Phase 3B.1B-2A human field-review transitions on `/audit-produk/[productId]` through `record_product_field_review`; correction controls remain out of scope.
- [x] Deploy review idempotency/intent migrations `20260929150000_product_field_review_notes_idempotency_v1.sql` and `20260929160000_product_field_review_intents_v1.sql`; authenticated mutation runtime verification remains pending in isolated staging.
- [ ] Verify review mutation authorization, transitions, stale-source handling, and request idempotency in isolated staging with real authenticated role sessions. Phase 3B.1B-2A is not production runtime verified; no production mutation test has been run.
- [x] Implement Phase 3B.1B-2B.2 correction controls on `/audit-produk/[productId]` using the deployed UUID-only correction intent path; no correction migration was needed.
- [ ] Verify correction intent issuance/recovery, correction replay/conflict, role permissions, and concurrency in isolated staging with dedicated authenticated roles and synthetic fixtures. Phase 3B.1B-2B.2 is not production mutation/runtime verified; do not run mutation tests against production.
- [x] Implement Phase 3B.1B-2B.1 local durable correction-intent database/server foundation, including UUID-only correction apply for reload-safe retry; correction UI remains out of scope.
- [x] Deploy `20260929170000_product_field_correction_intents_v1.sql`; migration ledger is user-confirmed synchronized through version `20260929170000`. Treat this applied migration as immutable; future database changes require a new additive migration.
- [x] Configure `IPOS_COMMIT_SECRET` only in a trusted server/operator secret store and perform the approved production commit after verifying the preflight.
- [x] Independently verify products, row links, histories, findings, provenance, and unchanged raw JSON after the production commit.
- [x] Use database advisory lock `(734921, 2)` in the deployed Phase 3B.1A product correction/import reconciliation functions.
- Inspect the original workbook's typed numeric cells against the parser behavior if values need comparison beyond the immutable raw JSON snapshot.
- Define authorization rules for sensitive financial data in modules beyond product HPP and encode them in database policies before implementing reports.
- Add managed server guards and RLS policies as each module is implemented; role-filtered navigation alone is insufficient.

## Product modules

- Follow the frozen v1 product mapping and audit rules in `docs/IPOS_IMPORT.md` and `docs/AUDIT_RULES.md`; additional audit findings require a later versioned decision.
- Implement POS carts, parked transactions, payments, member lookup, receipts, and stock consistency.
- Implement loyalty rules, member records, reward catalog, redemption, and point ledger.
- Implement supplier invoices, partial payment history, status logic, attachments, and reminder integration architecture.
- Implement reports and charts after accounting definitions and role permissions are agreed.
- Replace dashboard placeholders with authorized data only after source modules and definitions exist.
