# Product Audit Rules — Schema v1

The deployed schema is `supabase/migrations/20260928_product_ipos_schema_v1.sql` (migration version `20260928`). Audit findings are independent, snapshot-aware rows in `product_audit_findings`. Multiple findings can apply to one product and one source snapshot. `product_field_audit_reviews` stores append-only human field review events with reviewer, time, evidence/notes, status, and source-row provenance. Raw iPos values remain in immutable import rows. Phase 2B migration `20260928143000_ipos_normalization_commit_v1.sql` and the initial normalization commit are applied and independently verified.

## V1 findings

| Finding code | Condition |
|---|---|
| `MISSING_BARCODE` | KODEBARCODE is blank after outer trimming. Blank remains allowed and normalized as no barcode. |
| `MALFORMED_BARCODE` | KODEBARCODE contains a control character. Preserve raw value; do not silently strip it into a different barcode. |
| `DUPLICATE_BARCODE` | Same nonblank, well-formed normalized barcode is associated with more than one product. There is no global barcode uniqueness constraint in v1. |
| `ZERO_OR_MISSING_HPP` | HPP is zero or missing. An invalid numeric parse is a validation error and is not treated as zero. |
| `SELLING_PRICE_BELOW_HPP` | Valid selling price is less than valid HPP. |
| `ZERO_STOCK` | Valid normalized stock is zero. |
| `STOCK_AT_OR_BELOW_MINIMUM` | Minimum stock is greater than zero and stock is less than or equal to minimum. This may overlap with zero stock. |
| `MISSING_RACK` | RAK is blank after trimming. |
| `DUPLICATE_PRODUCT_NAME` | Exact match on the v1 normalized-name key: Unicode NFC, lowercase, trim outer whitespace, collapse repeated whitespace to one space; punctuation is preserved. This is a review finding only and never merges or re-identifies products. No fuzzy match in v1. |

There is no blank-brand or blank-supplier finding in v1. `SUPPLIER1` remains raw-only. Zero margin, safe SKU, and other proposed future audit flags are out of v1 scope.

## Snapshot and correction lifecycle

- Create findings with their triggering batch and import-row IDs. Do not delete historical findings.
- A later clean snapshot may mark an earlier open finding `RESOLVED`, recording who/when and the resolution batch. If the same problem remains in the new snapshot, create a new finding for that snapshot; retain the prior finding history.
- Field statuses are exactly `BELUM_DICEK`, `SEDANG_DICEK`, `SUDAH_DIVERIFIKASI`, and `PERLU_KOREKSI_IPOS`. Each review is a separate event so status history remains traceable.
- Manual corrections are stored as active field overrides with a field-scoped JSON value, reason, actor, timestamp, and source row. Database checks constrain the value shape and master/outlet scope. An override must match the normalized current value when created. Deactivate, do not delete, superseded overrides. Authenticated clients have no direct DML grants; trusted transactional handlers perform corrections.
- Barcode correction intent is explicit. `ADD_ALIAS` adds a second (or later) legitimate barcode association, retains all active associations, creates no source-replacement override, and preserves the manual association's NULL source pointer through matching import upserts. `REPLACE_SOURCE` corrects the barcode represented by the reviewed iPos row; it preserves/deactivates the prior association row and protects the replacement with a source-bound active override. A manual alias does not replace or protect the iPos source barcode. Do not infer a primary barcode; the schema has no canonical/primary field.
- Product SKU cannot be changed through the ordinary edit path. A genuine SKU re-key needs a separate workflow that records old and new identity and is not part of v1.
- If a later iPos row still supplies a value different from the active manual override, retain the override and do not replace its normalized value. The Phase 2B commit proposal records the conflicting source row and field for OWNER/ADMIN review; immutable `raw_data` retains the exact incoming value. The importer does not claim a person reviewed it or fabricate a `PERLU_KOREKSI_IPOS` review event. In the proposed Phase 3B.1A model, that status is derived from unresolved system reconciliation state. The database rejects an attempted normalized-field overwrite. When iPos catches up, snapshot findings can be resolved through the guarded lifecycle; clearing an override requires an explicit, attributable deactivation.
- Correction request UUIDs are bound in a private database request ledger to actor, product/outlet, field, source row, operation, normalized value, and reason. An exact semantic retry replays its stored response without repeating writes; a different payload using that UUID raises `IDEMPOTENCY_KEY_REUSED`. Both paths serialize with import/correction work on advisory lock `(734921, 2)`. This is deployed in Phase 3B.1A migration `20260929130000_field_audit_foundation_v1.sql`; production structural/security verification passed, while runtime mutation testing is deferred to isolated staging.
- Human review IDs are generated by the database intent issuer and bound to the active actor plus canonical field/source/status/notes payload. The server verifies an opaque browser-persisted UUID against the private intent ledger after reload; the browser does not store financial/source values. Exact completed retries replay before source freshness checks, while new intents require current-source validation. Confirmed success consumes the local retry token; a later review gets a new ID. Local migrations `20260929150000_product_field_review_notes_idempotency_v1.sql` and `20260929160000_product_field_review_intents_v1.sql` are **NOT DEPLOYED**. Phase 3B.1B-2A is not production runtime verified; run authenticated review mutation checks only in isolated staging.
- Do not put source/corrected numeric values in general audit findings. HPP and HPP correction values stay in manager-only tables; GUDANG cannot read HPP findings/reviews/overrides.

New findings must be `OPEN` with all resolution fields empty. Only `OPEN -> RESOLVED` is permitted; resolution timestamps and actors are stamped by the database, and resolved snapshot identity/history cannot be rewritten. A finding must reference a source row, product, batch, and outlet consistently. HPP-related findings and reviews are visible only to OWNER/ADMIN.

Price, HPP, and inventory history rows are created automatically in the same transaction as current-value changes and are append-only. Numeric precision validation rejects values beyond two decimal places for money/HPP and three for inventory before any typmod can round them.

The preflight calculates the codes above through the shared normalization engine. The Phase 2B commit RPC inserts current snapshot findings as OPEN and resolves an older OPEN finding for a product only when that finding type is absent from the new snapshot. Import disagreements are stored on manager-only normalization proposal rows; the commit does not insert human field-review events. Phase 3A audit counts read persisted findings for the latest completed snapshot. Deployed Phase 3B.1A adds separate system reconciliation events. The complete runtime review/correction and controlled re-import matrix remains pending in isolated staging; production RPC mutation tests were not run because exact cleanup cannot be guaranteed across independent PostgREST transactions.
