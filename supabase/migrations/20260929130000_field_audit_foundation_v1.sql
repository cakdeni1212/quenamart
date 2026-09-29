-- Phase 3B.1A: role-checked field review/correction and import reconciliation.
-- Additive only. Review and apply through the normal migration process.
begin;

-- A reconciliation row is a system/import or human decision event, not a
-- product_field_audit_reviews row. Values are field scoped; raw_data is never
-- copied as a whole.
create table public.product_field_reconciliation_events (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete restrict,
  outlet_id uuid not null references public.outlets(id) on delete restrict,
  field_key text collate "C" not null,
  batch_id uuid not null references public.ipos_import_batches(id) on delete restrict,
  source_import_row_id uuid not null,
  override_id uuid references public.product_field_overrides(id) on delete restrict,
  event_type text not null check (event_type in ('SOURCE_CONFLICT', 'SOURCE_SYNCED', 'HUMAN_ACCEPTED_SOURCE')),
  source_value jsonb,
  effective_value jsonb,
  actor_id uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint product_field_reconciliation_field_valid
    check (field_key in ('barcode', 'rack_label', 'hpp', 'selling_price')),
  constraint product_field_reconciliation_actor_valid check (
    (event_type = 'HUMAN_ACCEPTED_SOURCE' and actor_id is not null)
    or (event_type in ('SOURCE_CONFLICT', 'SOURCE_SYNCED') and actor_id is null)
  ),
  constraint product_field_reconciliation_source_fk
    foreign key (source_import_row_id, batch_id, outlet_id, product_id)
    references public.ipos_import_rows(id, batch_id, outlet_id, product_id)
    on delete restrict deferrable initially deferred
);

create unique index product_field_reconciliation_import_event_unique
  on public.product_field_reconciliation_events
  (source_import_row_id, field_key, override_id, event_type);
create index product_field_reconciliation_latest_idx
  on public.product_field_reconciliation_events
  (product_id, outlet_id, field_key, created_at desc, id desc);

alter table public.product_field_audit_reviews
  add column request_id uuid;
alter table public.product_field_audit_reviews
  add column barcode_id uuid,
  add constraint field_reviews_barcode_product_fk
    foreign key (barcode_id, product_id)
    references public.product_barcodes(id, product_id) on delete restrict;
create unique index product_field_audit_reviews_request_unique
  on public.product_field_audit_reviews(request_id) where request_id is not null;

-- Exact correction-request payloads are stored privately, including financial
-- values. The RPC alone reads/writes this table; request_id binds retries to
-- actor, target, source, operation, normalized value, and reason.
create table public.product_field_correction_requests (
  request_id uuid primary key,
  actor_id uuid not null references auth.users(id) on delete restrict,
  request_payload jsonb not null check (jsonb_typeof(request_payload) = 'object'),
  result jsonb not null check (jsonb_typeof(result) = 'object'),
  review_id uuid references public.product_field_audit_reviews(id) on delete restrict,
  created_at timestamptz not null default now()
);
alter table public.product_field_correction_requests enable row level security;
revoke all on public.product_field_correction_requests from public, anon, authenticated, service_role;

alter table public.product_field_reconciliation_events enable row level security;
revoke all on public.product_field_reconciliation_events from public, anon, authenticated, service_role;
grant select on public.product_field_reconciliation_events to authenticated;
create policy product_field_reconciliation_select_roles
  on public.product_field_reconciliation_events for select to authenticated
  using (
    public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role)
    or (public.current_active_user_role() = 'GUDANG'::public.user_role and field_key in ('barcode','rack_label'))
  );

-- Price review notes can contain HPP context even though selling price itself
-- is operationally readable. Restrict GUDANG's review-event visibility to its
-- approved field-audit scope.
drop policy if exists field_reviews_select_role_safe on public.product_field_audit_reviews;
create policy field_reviews_select_role_safe on public.product_field_audit_reviews for select to authenticated
  using (public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role)
    or (public.current_active_user_role() = 'GUDANG'::public.user_role
      and field_key in ('barcode','rack_label','quantity','minimum_quantity')));

create or replace function public.field_audit_record_reconciliation(
  p_product_id uuid,
  p_outlet_id uuid,
  p_field_key text,
  p_batch_id uuid,
  p_source_row_id uuid,
  p_override_id uuid,
  p_event_type text,
  p_source_value jsonb,
  p_effective_value jsonb,
  p_actor_id uuid default null
)
returns void
language plpgsql security definer
set search_path = pg_catalog
as $$
begin
  insert into public.product_field_reconciliation_events (
    product_id, outlet_id, field_key, batch_id, source_import_row_id,
    override_id, event_type, source_value, effective_value, actor_id
  ) values (
    p_product_id, p_outlet_id, p_field_key, p_batch_id, p_source_row_id,
    p_override_id, p_event_type, p_source_value, p_effective_value, p_actor_id
  ) on conflict (source_import_row_id, field_key, override_id, event_type) do nothing;
end;
$$;
alter function public.field_audit_record_reconciliation(uuid,uuid,text,uuid,uuid,uuid,text,jsonb,jsonb,uuid) owner to postgres;
revoke all on function public.field_audit_record_reconciliation(uuid,uuid,text,uuid,uuid,uuid,text,jsonb,jsonb,uuid)
  from public, anon, authenticated, service_role;

-- Scalar imports use the same normalized proposal the Phase 2B commit used.
-- The source pointer only changes on imports; manual corrections preserve it.
create or replace function public.reconcile_field_override_on_import()
returns trigger
language plpgsql security definer
set search_path = pg_catalog
as $$
declare
  v_field text;
  v_product uuid;
  v_outlet uuid;
  v_batch uuid;
  v_raw jsonb;
  v_normalized jsonb;
  v_errors jsonb;
  v_importer uuid;
  v_override record;
  v_incoming jsonb;
  v_matches boolean;
begin
  if tg_op <> 'UPDATE' or new.source_import_row_id is null
    or new.source_import_row_id is not distinct from old.source_import_row_id then
    return new;
  end if;

  v_field := case
    when tg_table_name = 'product_outlet_settings' then 'rack_label'
    when tg_table_name = 'product_costs' then 'hpp'
    when tg_table_name = 'product_selling_prices' then 'selling_price'
    else null end;
  if v_field is null then return new; end if;
  v_product := new.product_id;
  v_outlet := new.outlet_id;

  select r.batch_id, r.outlet_id, r.raw_data, c.normalized_data, c.validation_errors,
    b.imported_by
  into v_batch, v_outlet, v_raw, v_normalized, v_errors, v_importer
  from public.ipos_import_rows r
  join public.ipos_import_batches b on b.id = r.batch_id and b.outlet_id = r.outlet_id
  join public.ipos_normalization_commit_rows c on c.source_row_id = r.id and c.batch_id = r.batch_id
  join public.ipos_normalization_commits n on n.id = c.commit_id and n.status = 'PROCESSING'
  where r.id = new.source_import_row_id and c.action in ('CREATE', 'UPDATE')
  limit 1;
  if not found or v_outlet is distinct from new.outlet_id then return new; end if;

  v_incoming := case v_field
    when 'rack_label' then v_raw -> 'RAK'
    when 'hpp' then v_raw -> 'HARGAPOKOK'
    else v_raw -> 'HARGAJUAL' end;

  for v_override in
    select o.id, o.corrected_value
    from public.product_field_overrides o
    where o.product_id = v_product and o.outlet_id = v_outlet
      and o.field_key = v_field and o.is_active and o.source_import_row_id is not null
    for update
  loop
    if v_field = 'rack_label' then
      v_matches := not exists (
        select 1 from jsonb_array_elements(coalesce(v_errors, '[]'::jsonb)) e
        where e ->> 'code' = 'INVALID_TEXT_TYPE' and e ->> 'field' = 'RAK'
      ) and v_normalized -> 'rackLabel' = v_override.corrected_value;
    else
      v_matches := not exists (
        select 1 from jsonb_array_elements(coalesce(v_errors, '[]'::jsonb)) e
        where e ->> 'code' = 'INVALID_NUMERIC_VALUE'
          and e ->> 'field' = case when v_field = 'hpp' then 'HARGAPOKOK' else 'HARGAJUAL' end
      ) and nullif(v_normalized ->> case when v_field = 'hpp' then 'hpp' else 'sellingPrice' end, '') is not null
        and (v_normalized ->> case when v_field = 'hpp' then 'hpp' else 'sellingPrice' end)::numeric = (v_override.corrected_value #>> '{}')::numeric;
    end if;

    perform public.field_audit_record_reconciliation(
      v_product, v_outlet, v_field, v_batch, new.source_import_row_id,
      v_override.id, case when v_matches then 'SOURCE_SYNCED' else 'SOURCE_CONFLICT' end,
      v_incoming, v_override.corrected_value, null
    );
    if v_matches then
      update public.product_field_overrides
      set is_active = false, deactivated_by = v_importer
      where id = v_override.id and is_active;
    else
      -- Keep the active correction effective while still advancing provenance
      -- to the newly accepted import row.
      if v_field = 'rack_label' then new.rack_label := old.rack_label;
      elsif v_field = 'hpp' then new.hpp := old.hpp;
      else new.amount := old.amount;
      end if;
    end if;
  end loop;
  return new;
end;
$$;
alter function public.reconcile_field_override_on_import() owner to postgres;
revoke all on function public.reconcile_field_override_on_import() from public, anon, authenticated, service_role;
create trigger a_product_settings_source_override_reconcile
  before update on public.product_outlet_settings
  for each row execute function public.reconcile_field_override_on_import();
create trigger a_product_costs_source_override_reconcile
  before update on public.product_costs
  for each row execute function public.reconcile_field_override_on_import();
create trigger a_product_prices_source_override_reconcile
  before update on public.product_selling_prices
  for each row execute function public.reconcile_field_override_on_import();

-- The product's last_import_row_id advances before Phase 2B links that raw row.
-- Its composite reconciliation FK is deferred until the commit transaction ends.
create or replace function public.reconcile_barcode_override_on_import()
returns trigger
language plpgsql security definer
set search_path = pg_catalog
as $$
declare
  v_batch uuid;
  v_outlet uuid;
  v_raw jsonb;
  v_normalized jsonb;
  v_importer uuid;
  v_override record;
  v_incoming text;
  v_valid boolean;
  v_matches boolean;
begin
  if tg_op <> 'UPDATE' or new.last_import_row_id is null
    or new.last_import_row_id is not distinct from old.last_import_row_id then
    return new;
  end if;
  select r.batch_id, r.outlet_id, r.raw_data, c.normalized_data, b.imported_by
  into v_batch, v_outlet, v_raw, v_normalized, v_importer
  from public.ipos_import_rows r
  join public.ipos_import_batches b on b.id = r.batch_id and b.outlet_id = r.outlet_id
  join public.ipos_normalization_commit_rows c on c.source_row_id = r.id and c.batch_id = r.batch_id
  join public.ipos_normalization_commits n on n.id = c.commit_id and n.status = 'PROCESSING'
  where r.id = new.last_import_row_id and c.action in ('CREATE', 'UPDATE')
  limit 1;
  if not found then return new; end if;

  v_incoming := v_normalized ->> 'barcode';
  v_valid := v_normalized ->> 'barcodeState' = 'VALID' and v_incoming is not null;
  for v_override in
    select o.id, o.barcode_id, o.corrected_value
    from public.product_field_overrides o
    where o.product_id = new.id and o.field_key = 'barcode'
      and o.is_active and o.source_import_row_id is not null
    for update
  loop
    v_matches := v_valid and to_jsonb(v_incoming) = v_override.corrected_value;
    if not v_matches then
      -- A conflict can be recorded before raw-row linking because its composite
      -- event FK is deferred. A match is finalized only by the AFTER raw-link
      -- trigger below, when the barcode association FK can be checked safely.
      perform public.field_audit_record_reconciliation(
        new.id, v_outlet, 'barcode', v_batch, new.last_import_row_id,
        v_override.id, 'SOURCE_CONFLICT',
        v_raw -> 'KODEBARCODE', v_override.corrected_value, null
      );
    end if;
  end loop;
  return new;
end;
$$;
alter function public.reconcile_barcode_override_on_import() owner to postgres;
revoke all on function public.reconcile_barcode_override_on_import() from public, anon, authenticated, service_role;
create trigger a_products_barcode_source_override_reconcile
  before update on public.products
  for each row execute function public.reconcile_barcode_override_on_import();

-- Phase 2B links ipos_import_rows.product_id after the products upsert and
-- before its barcode update/insert statements. Finalize matching replacements
-- here: both barcode provenance FKs are now valid, and the override stays active
-- until this same transaction transfers provenance and records synchronization.
create or replace function public.finalize_barcode_override_sync_after_raw_link()
returns trigger
language plpgsql security definer
set search_path = pg_catalog
as $$
declare
  v_normalized jsonb;
  v_importer uuid;
  v_override record;
begin
  if old.product_id is not null or new.product_id is null or new.status <> 'VALID' then
    return new;
  end if;

  select c.normalized_data, b.imported_by
  into v_normalized, v_importer
  from public.ipos_normalization_commit_rows c
  join public.ipos_normalization_commits n
    on n.id = c.commit_id and n.status = 'PROCESSING'
  join public.ipos_import_batches b
    on b.id = new.batch_id and b.outlet_id = new.outlet_id
  where c.source_row_id = new.id and c.batch_id = new.batch_id
    and c.product_id = new.product_id and c.action in ('CREATE', 'UPDATE')
  limit 1;
  if not found or v_normalized ->> 'barcodeState' <> 'VALID'
    or v_normalized ->> 'barcode' is null then
    return new;
  end if;

  for v_override in
    select o.id, o.barcode_id, o.corrected_value
    from public.product_field_overrides o
    where o.product_id = new.product_id and o.field_key = 'barcode'
      and o.is_active and o.source_import_row_id is not null
    for update
  loop
    if to_jsonb(v_normalized ->> 'barcode') = v_override.corrected_value then
      perform public.field_audit_record_reconciliation(
        new.product_id, new.outlet_id, 'barcode', new.batch_id, new.id,
        v_override.id, 'SOURCE_SYNCED', new.raw_data -> 'KODEBARCODE',
        v_override.corrected_value, null
      );
      update public.product_barcodes
      set source_import_row_id = new.id, updated_by = v_importer
      where id = v_override.barcode_id and product_id = new.product_id and is_active;
      if not found then
        raise exception 'Protected barcode association is missing during source synchronization';
      end if;
      update public.product_field_overrides
      set is_active = false, deactivated_by = v_importer
      where id = v_override.id and is_active;
    end if;
  end loop;
  return new;
end;
$$;
alter function public.finalize_barcode_override_sync_after_raw_link() owner to postgres;
revoke all on function public.finalize_barcode_override_sync_after_raw_link() from public, anon, authenticated, service_role;
create trigger ipos_barcode_override_sync_after_raw_link
  after update of product_id on public.ipos_import_rows
  for each row
  when (old.product_id is null and new.product_id is not null)
  execute function public.finalize_barcode_override_sync_after_raw_link();

-- Suppress an incoming barcode association only when a source-replacement
-- override remains active. Aliases have no source-bound override and survive.
create or replace function public.protect_manual_barcode_override_from_import()
returns trigger
language plpgsql security definer
set search_path = pg_catalog
as $$
declare
  v_source_row uuid;
begin
  if new.source_import_row_id is null then return new; end if;
  select o.source_import_row_id into v_source_row
  from public.product_field_overrides o
  where o.product_id = new.product_id and o.field_key = 'barcode'
    and o.is_active and o.source_import_row_id is not null
  limit 1;
  if v_source_row is null then return new; end if;

  if not exists (
    select 1 from public.product_field_reconciliation_events e
    where e.product_id = new.product_id and e.field_key = 'barcode'
      and e.source_import_row_id = new.source_import_row_id
      and e.event_type = 'SOURCE_SYNCED'
  ) then
    return null;
  end if;
  return new;
end;
$$;
alter function public.protect_manual_barcode_override_from_import() owner to postgres;
revoke all on function public.protect_manual_barcode_override_from_import() from public, anon, authenticated, service_role;
create trigger product_barcodes_manual_override_import_guard
  before insert on public.product_barcodes
  for each row execute function public.protect_manual_barcode_override_from_import();

-- Phase 2B upserts an incoming association on (product_id, barcode). Keep a
-- manually-added alias's NULL source pointer through that upsert so later
-- imports do not mistake the alias for the replaceable source association.
create or replace function public.preserve_manual_barcode_alias_provenance()
returns trigger
language plpgsql security definer
set search_path = pg_catalog
as $$
begin
  if old.source_import_row_id is null and not exists (
    select 1 from public.product_field_overrides o
    where o.barcode_id = old.id and o.field_key = 'barcode' and o.is_active
      and o.source_import_row_id is not null
  ) then
    new.source_import_row_id := null;
  end if;
  return new;
end;
$$;
alter function public.preserve_manual_barcode_alias_provenance() owner to postgres;
revoke all on function public.preserve_manual_barcode_alias_provenance() from public, anon, authenticated, service_role;
create trigger product_barcodes_preserve_manual_alias_provenance
  before update on public.product_barcodes
  for each row execute function public.preserve_manual_barcode_alias_provenance();

-- Add the single active source-replacement barcode override invariant. Additional
-- barcode aliases may be represented without a source_import_row_id.
create unique index product_field_overrides_one_source_barcode_unique
  on public.product_field_overrides(product_id)
  where field_key = 'barcode' and is_active and source_import_row_id is not null;

-- Narrow nonfinancial source projection for OWNER/ADMIN/GUDANG. It returns only
-- barcode and rack cells, never raw_data or financial fields.
create or replace function public.read_product_field_source(
  p_product_id uuid,
  p_outlet_id uuid
)
returns table (
  barcode_source_import_row_id uuid,
  barcode_batch_id uuid,
  barcode_source jsonb,
  rack_source_import_row_id uuid,
  rack_batch_id uuid,
  rack_source jsonb
)
language plpgsql security definer
set search_path = pg_catalog
as $$
declare role_value public.user_role;
begin
  role_value := public.current_active_user_role();
  if role_value is null or role_value not in ('OWNER'::public.user_role, 'ADMIN'::public.user_role, 'GUDANG'::public.user_role) then
    raise exception using errcode = '42501', message = 'Field audit source access denied';
  end if;
  return query
  select barcode_row.id, barcode_row.batch_id, barcode_row.raw_data -> 'KODEBARCODE',
    rack_row.id, rack_row.batch_id, rack_row.raw_data -> 'RAK'
  from public.products p
  left join public.ipos_import_rows barcode_row
    on barcode_row.id = p.last_import_row_id and barcode_row.product_id = p.id
      and barcode_row.status = 'VALID'
  left join public.product_outlet_settings settings
    on settings.product_id = p.id and settings.outlet_id = p_outlet_id
  left join public.ipos_import_rows rack_row
    on rack_row.id = settings.source_import_row_id and rack_row.product_id = p.id
      and rack_row.outlet_id = p_outlet_id and rack_row.status = 'VALID'
  where p.id = p_product_id;
end;
$$;
alter function public.read_product_field_source(uuid,uuid) owner to postgres;
revoke all on function public.read_product_field_source(uuid,uuid) from public, anon, authenticated, service_role;
grant execute on function public.read_product_field_source(uuid,uuid) to authenticated;

-- Financial source values are isolated in a separate OWNER/ADMIN-only result.
create or replace function public.read_product_financial_field_source(
  p_product_id uuid,
  p_outlet_id uuid
)
returns table (
  hpp_source_import_row_id uuid,
  hpp_batch_id uuid,
  hpp_source jsonb,
  selling_price_source_import_row_id uuid,
  selling_price_batch_id uuid,
  selling_price_source jsonb
)
language plpgsql security definer
set search_path = pg_catalog
as $$
declare role_value public.user_role;
begin
  role_value := public.current_active_user_role();
  if role_value is null or role_value not in ('OWNER'::public.user_role, 'ADMIN'::public.user_role) then
    raise exception using errcode = '42501', message = 'Financial field source access denied';
  end if;
  return query
  select hpp_row.id, hpp_row.batch_id, hpp_row.raw_data -> 'HARGAPOKOK',
    price_row.id, price_row.batch_id, price_row.raw_data -> 'HARGAJUAL'
  from public.products product
  left join public.product_costs cost
    on cost.product_id = product.id and cost.outlet_id = p_outlet_id
  left join public.ipos_import_rows hpp_row
    on hpp_row.id = cost.source_import_row_id and hpp_row.product_id = product.id
      and hpp_row.outlet_id = p_outlet_id and hpp_row.status = 'VALID'
  left join public.product_selling_prices price
    on price.product_id = product.id and price.outlet_id = p_outlet_id
  left join public.ipos_import_rows price_row
    on price_row.id = price.source_import_row_id and price_row.product_id = product.id
      and price_row.outlet_id = p_outlet_id and price_row.status = 'VALID'
  where product.id = p_product_id;
end;
$$;
alter function public.read_product_financial_field_source(uuid,uuid) owner to postgres;
revoke all on function public.read_product_financial_field_source(uuid,uuid) from public, anon, authenticated, service_role;
grant execute on function public.read_product_financial_field_source(uuid,uuid) to authenticated;

-- Append-only, actor-derived human review transitions. PERLU_KOREKSI_IPOS is
-- deliberately not accepted here; it is derived from reconciliation events.
create or replace function public.record_product_field_review(
  p_request_id uuid,
  p_product_id uuid,
  p_outlet_id uuid,
  p_field_key text,
  p_status public.product_field_audit_status,
  p_source_import_row_id uuid,
  p_evidence_notes text default null
)
returns uuid
language plpgsql security definer
set search_path = pg_catalog
as $$
declare actor_id uuid := auth.uid(); role_value public.user_role; prior public.product_field_audit_reviews%rowtype;
  current_source_id uuid; prior_status public.product_field_audit_status;
  prior_request public.product_field_audit_reviews%rowtype; source_outlet uuid;
  latest_source uuid;
begin
  if actor_id is null then raise exception using errcode = '42501', message = 'Authentication required'; end if;
  role_value := public.current_active_user_role();
  if role_value is null or role_value = 'KASIR'::public.user_role then
    raise exception using errcode = '42501', message = 'Field audit access denied';
  end if;
  if p_status not in ('SEDANG_DICEK'::public.product_field_audit_status,
      'SUDAH_DIVERIFIKASI'::public.product_field_audit_status)
    or p_field_key not in ('barcode','rack_label','hpp','selling_price','quantity','minimum_quantity') then
    raise exception using errcode = '22023', message = 'Invalid review field or transition';
  end if;
  if role_value = 'GUDANG'::public.user_role and p_field_key not in ('barcode','rack_label','quantity','minimum_quantity') then
    raise exception using errcode = '42501', message = 'Field audit permission denied';
  end if;
  if p_request_id is null or p_source_import_row_id is null then
    raise exception using errcode = '22023', message = 'Request and source row are required';
  end if;
  if p_field_key = 'barcode' and p_outlet_id is not null then
    raise exception using errcode = '22023', message = 'Barcode review is not outlet-scoped';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(734921, 2);

  select * into prior_request from public.product_field_audit_reviews r where r.request_id = p_request_id;
  if found then
    if prior_request.reviewer_id <> actor_id or prior_request.product_id <> p_product_id
      or prior_request.field_key <> p_field_key
      or prior_request.outlet_id is distinct from p_outlet_id
      or prior_request.source_import_row_id is distinct from p_source_import_row_id
      or prior_request.status is distinct from p_status then
      raise exception using errcode = '22023', message = 'Request ID was already used for another review';
    end if;
    return prior_request.id;
  end if;
  if exists (select 1 from public.product_field_correction_requests c where c.request_id = p_request_id) then
    raise exception using errcode = '22023', message = 'IDEMPOTENCY_KEY_REUSED';
  end if;

  select p.last_import_row_id into latest_source from public.products p where p.id = p_product_id for update;
  if not found then raise exception using errcode = '22023', message = 'Product not found'; end if;
  select r.outlet_id into source_outlet from public.ipos_import_rows r
  where r.id = p_source_import_row_id and r.product_id = p_product_id and r.status = 'VALID';
  if not found or (p_outlet_id is not null and source_outlet <> p_outlet_id) then
    raise exception using errcode = '22023', message = 'Source row does not belong to this product/outlet';
  end if;
  if p_field_key = 'barcode' then current_source_id := latest_source;
  elsif p_field_key = 'rack_label' then
    select s.source_import_row_id into current_source_id from public.product_outlet_settings s
      where s.product_id = p_product_id and s.outlet_id = p_outlet_id;
  elsif p_field_key in ('hpp','selling_price') then
    if p_field_key = 'hpp' then select c.source_import_row_id into current_source_id from public.product_costs c where c.product_id=p_product_id and c.outlet_id=p_outlet_id;
    else select s.source_import_row_id into current_source_id from public.product_selling_prices s where s.product_id=p_product_id and s.outlet_id=p_outlet_id; end if;
  else
    select i.source_import_row_id into current_source_id from public.product_inventory i where i.product_id=p_product_id and i.outlet_id=p_outlet_id;
  end if;
  if current_source_id is distinct from p_source_import_row_id then
    raise exception using errcode = '40001', message = 'Source changed; reload the field before reviewing';
  end if;
  select * into prior from public.product_field_audit_reviews r
  where r.product_id = p_product_id and r.field_key = p_field_key
    and r.outlet_id is not distinct from p_outlet_id
  order by r.reviewed_at desc, r.created_at desc, r.id desc limit 1;
  if found and prior.source_import_row_id = p_source_import_row_id then prior_status := prior.status;
  else prior_status := 'BELUM_DICEK'::public.product_field_audit_status; end if;
  if (p_status = 'SEDANG_DICEK'::public.product_field_audit_status and prior_status not in ('BELUM_DICEK'::public.product_field_audit_status, 'SEDANG_DICEK'::public.product_field_audit_status, 'SUDAH_DIVERIFIKASI'::public.product_field_audit_status))
    or (p_status = 'SUDAH_DIVERIFIKASI'::public.product_field_audit_status and prior_status <> 'SEDANG_DICEK'::public.product_field_audit_status) then
    raise exception using errcode = '22023', message = 'Invalid human review transition';
  end if;
  insert into public.product_field_audit_reviews (
    product_id, outlet_id, field_key, status, source_import_row_id,
    reviewer_id, evidence_notes, request_id
  ) values (
    p_product_id, p_outlet_id, p_field_key, p_status, p_source_import_row_id,
    actor_id, nullif(btrim(p_evidence_notes), ''), p_request_id
  ) returning id into current_source_id;
  return current_source_id;
end;
$$;
alter function public.record_product_field_review(uuid,uuid,uuid,text,public.product_field_audit_status,uuid,text) owner to postgres;
revoke all on function public.record_product_field_review(uuid,uuid,uuid,text,public.product_field_audit_status,uuid,text)
  from public, anon, authenticated, service_role;
grant execute on function public.record_product_field_review(uuid,uuid,uuid,text,public.product_field_audit_status,uuid,text)
  to authenticated;

-- One atomic correction endpoint. Actor identity is auth.uid(); the client
-- supplies no reviewer ID. The return value contains status/IDs only, never HPP.
create or replace function public.apply_product_field_correction(
  p_request_id uuid,
  p_product_id uuid,
  p_outlet_id uuid,
  p_field_key text,
  p_corrected_value jsonb,
  p_reason text,
  p_source_import_row_id uuid,
  p_barcode_operation text default null
)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog
as $$
declare actor_id uuid := auth.uid(); role_value public.user_role;
  prior_correction_request public.product_field_correction_requests%rowtype;
  source_batch uuid; source_outlet uuid; source_raw jsonb; source_norm jsonb; source_errors jsonb;
  source_field jsonb; source_valid boolean := false; normalized_value jsonb;
  value_text text; value_reason text; value_num numeric; same_as_source boolean := false;
  request_payload jsonb; result_value jsonb;
  active_override public.product_field_overrides%rowtype; has_override boolean := false;
  latest_review public.product_field_audit_reviews%rowtype;
  barcode_row uuid; conflict_found boolean; already_present boolean := false;
  new_review uuid; reconciliation_kind text;
begin
  if actor_id is null then raise exception using errcode = '42501', message = 'Authentication required'; end if;
  role_value := public.current_active_user_role();
  if role_value is null or role_value = 'KASIR'::public.user_role then
    raise exception using errcode = '42501', message = 'Field correction permission denied';
  end if;
  if p_field_key not in ('barcode','rack_label','hpp','selling_price') then
    raise exception using errcode = '22023', message = 'Field is not editable in Phase 3B.1';
  end if;
  if p_field_key = 'barcode' then
    if p_barcode_operation is null or p_barcode_operation not in ('ADD_ALIAS','REPLACE_SOURCE') then
      raise exception using errcode = '22023', message = 'Barcode operation must be ADD_ALIAS or REPLACE_SOURCE';
    end if;
  elsif p_barcode_operation is not null then
    raise exception using errcode = '22023', message = 'Barcode operation is only valid for BARCODE';
  end if;
  if p_field_key = 'barcode' and p_outlet_id is not null then
    raise exception using errcode='22023', message='Barcode correction is not outlet-scoped';
  end if;
  if role_value = 'GUDANG'::public.user_role and p_field_key not in ('barcode','rack_label') then
    raise exception using errcode = '42501', message = 'Field correction permission denied';
  end if;
  value_reason := regexp_replace(coalesce(p_reason,''), '^[[:space:]]+|[[:space:]]+$', '', 'g');
  if p_request_id is null or p_source_import_row_id is null or value_reason = '' then
    raise exception using errcode = '22023', message = 'Request, source row, and correction reason are required';
  end if;
  if p_field_key in ('barcode','rack_label') then
    if p_corrected_value is null or jsonb_typeof(p_corrected_value) <> 'string' then raise exception using errcode='22023', message='Text value required'; end if;
    value_text := regexp_replace(p_corrected_value #>> '{}', '^[[:space:]]+|[[:space:]]+$', '', 'g');
    if value_text = '' or value_text ~ '[[:cntrl:]]' then raise exception using errcode='22023', message='Blank/control-character value is not allowed'; end if;
    normalized_value := to_jsonb(value_text);
    if p_field_key = 'barcode' and char_length(value_text) > 256 then raise exception using errcode='22023', message='Barcode is too long'; end if;
  else
    if p_corrected_value is null or jsonb_typeof(p_corrected_value) <> 'number' then raise exception using errcode='22023', message='Numeric value required'; end if;
    value_num := (p_corrected_value #>> '{}')::numeric;
    if value_num < 0 or value_num >= 1000000000000::numeric or value_num <> trunc(value_num, 2) then
      raise exception using errcode='22023', message='Price/HPP value is outside the allowed range or scale';
    end if;
    normalized_value := to_jsonb(value_num);
  end if;
  if p_field_key in ('rack_label','hpp','selling_price') and p_outlet_id is null then
    raise exception using errcode='22023', message='Outlet is required for this field';
  end if;
  request_payload := jsonb_build_object(
    'actor_id', actor_id,
    'product_id', p_product_id,
    'outlet_id', case when p_field_key = 'barcode' then null else p_outlet_id end,
    'field_key', p_field_key,
    'source_import_row_id', p_source_import_row_id,
    'operation_type', p_barcode_operation,
    'corrected_value', normalized_value,
    'reason', value_reason
  );
  perform pg_catalog.pg_advisory_xact_lock(734921, 2);

  select * into prior_correction_request
  from public.product_field_correction_requests r where r.request_id=p_request_id for update;
  if found then
    if prior_correction_request.actor_id <> actor_id
      or prior_correction_request.request_payload is distinct from request_payload then
      raise exception using errcode='22023', message='IDEMPOTENCY_KEY_REUSED';
    end if;
    return prior_correction_request.result;
  end if;
  if exists (select 1 from public.product_field_audit_reviews r where r.request_id=p_request_id) then
    raise exception using errcode='22023', message='IDEMPOTENCY_KEY_REUSED';
  end if;

  perform 1 from public.products p where p.id=p_product_id for update;
  if not found then raise exception using errcode='22023', message='Product not found'; end if;
  select r.batch_id, r.outlet_id, r.raw_data, c.normalized_data, c.validation_errors
    into source_batch, source_outlet, source_raw, source_norm, source_errors
  from public.ipos_import_rows r
  join public.ipos_import_batches b on b.id=r.batch_id and b.outlet_id=r.outlet_id and b.status='COMPLETED'
  join public.ipos_normalization_commit_rows c on c.source_row_id=r.id and c.batch_id=r.batch_id
  join public.ipos_normalization_commits n on n.id=c.commit_id and n.status='COMPLETED'
  where r.id=p_source_import_row_id and r.product_id=p_product_id and r.status='VALID'
    and c.action in ('CREATE','UPDATE') limit 1;
  if not found or (p_outlet_id is not null and source_outlet<>p_outlet_id) then
    raise exception using errcode='22023', message='Source row does not belong to this product/outlet';
  end if;
  if p_field_key='barcode' then
    if (select p.last_import_row_id from public.products p where p.id=p_product_id) is distinct from p_source_import_row_id then
      raise exception using errcode='40001', message='Barcode source changed; reload before correcting';
    end if;
    source_field := source_raw->'KODEBARCODE';
    source_valid := source_norm->>'barcodeState'='VALID' and source_norm->>'barcode' is not null;
    if source_valid then same_as_source := to_jsonb(source_norm->>'barcode')=normalized_value; end if;
  elsif p_field_key='rack_label' then
    if source_outlet<>p_outlet_id or (select s.source_import_row_id from public.product_outlet_settings s where s.product_id=p_product_id and s.outlet_id=p_outlet_id) is distinct from p_source_import_row_id then
      raise exception using errcode='40001', message='Rack source changed; reload before correcting';
    end if;
    source_field := source_raw->'RAK';
    source_valid := not exists(select 1 from jsonb_array_elements(coalesce(source_errors,'[]'::jsonb)) e where e->>'code'='INVALID_TEXT_TYPE' and e->>'field'='RAK');
    if source_valid and source_norm->'rackLabel' <> 'null'::jsonb then same_as_source := source_norm->'rackLabel'=normalized_value; end if;
  else
    if source_outlet<>p_outlet_id then raise exception using errcode='22023', message='Financial source outlet mismatch'; end if;
    if p_field_key='hpp' then
      if (select c.source_import_row_id from public.product_costs c where c.product_id=p_product_id and c.outlet_id=p_outlet_id) is distinct from p_source_import_row_id then raise exception using errcode='40001', message='HPP source changed; reload before correcting'; end if;
      source_field := source_raw->'HARGAPOKOK';
      source_valid := source_norm->>'hpp' is not null and not exists(select 1 from jsonb_array_elements(coalesce(source_errors,'[]'::jsonb)) e where e->>'code'='INVALID_NUMERIC_VALUE' and e->>'field'='HARGAPOKOK');
      if source_valid then same_as_source := (source_norm->>'hpp')::numeric=value_num; end if;
    else
      if (select s.source_import_row_id from public.product_selling_prices s where s.product_id=p_product_id and s.outlet_id=p_outlet_id) is distinct from p_source_import_row_id then raise exception using errcode='40001', message='Price source changed; reload before correcting'; end if;
      source_field := source_raw->'HARGAJUAL';
      source_valid := source_norm->>'sellingPrice' is not null and not exists(select 1 from jsonb_array_elements(coalesce(source_errors,'[]'::jsonb)) e where e->>'code'='INVALID_NUMERIC_VALUE' and e->>'field'='HARGAJUAL');
      if source_valid then same_as_source := (source_norm->>'sellingPrice')::numeric=value_num; end if;
    end if;
  end if;

  -- A correction may only be finalized from a live review session for this exact source snapshot.
  select * into latest_review from public.product_field_audit_reviews r
  where r.product_id=p_product_id and r.field_key=p_field_key and r.outlet_id is not distinct from
    case when p_field_key='barcode' then null::uuid else p_outlet_id end
  order by r.reviewed_at desc,r.created_at desc,r.id desc limit 1;
  if not found or latest_review.status<>'SEDANG_DICEK'::public.product_field_audit_status
    or latest_review.source_import_row_id is distinct from p_source_import_row_id then
    raise exception using errcode='22023', message='Begin review for the current source row before saving a correction';
  end if;

  if p_field_key='barcode' then
    select exists(select 1 from public.product_barcodes b where b.barcode=value_text and b.is_active and b.product_id<>p_product_id) into conflict_found;
    if conflict_found then
      result_value := jsonb_build_object('ok',false,'code','BARCODE_CONFLICT');
      insert into public.product_field_correction_requests(request_id,actor_id,request_payload,result)
      values(p_request_id,actor_id,request_payload,result_value);
      return result_value;
    end if;
    if p_barcode_operation = 'REPLACE_SOURCE' then
      select * into active_override from public.product_field_overrides o
      where o.product_id=p_product_id and o.field_key='barcode' and o.is_active and o.source_import_row_id is not null
      limit 1 for update;
      has_override := found;
    end if;
  else
    select * into active_override from public.product_field_overrides o
      where o.product_id=p_product_id and o.outlet_id=p_outlet_id and o.field_key=p_field_key and o.is_active
      limit 1 for update;
    has_override := found;
  end if;

  if p_field_key = 'barcode' and p_barcode_operation = 'ADD_ALIAS' then
    select b.id into barcode_row from public.product_barcodes b
      where b.product_id=p_product_id and b.barcode=value_text and b.is_active
      limit 1 for update;
    already_present := found;
    if not already_present then
      insert into public.product_barcodes(product_id,barcode,is_active,source_import_row_id,created_by,updated_by)
      values(p_product_id,value_text,true,null,actor_id,actor_id) returning id into barcode_row;
    end if;
  elsif has_override and active_override.corrected_value=normalized_value and not same_as_source then
    null; -- Idempotent confirmation of an already-active source replacement.
  else
    if has_override then
      update public.product_field_overrides set is_active=false,
        deactivated_by=actor_id where id=active_override.id;
      if p_field_key='barcode' then
        update public.product_barcodes set is_active=false,updated_by=actor_id
        where id=active_override.barcode_id and is_active;
      end if;
    end if;

    if p_field_key='barcode' then
      -- Retire active imported/source associations, not manual aliases. The
      -- latest raw row can be blank/malformed and therefore have no barcode
      -- association of its own; source provenance distinguishes imported rows
      -- (non-NULL source row) from aliases (NULL source row).
      update public.product_barcodes set is_active=false,updated_by=actor_id
      where product_id=p_product_id and is_active and source_import_row_id is not null;
      select b.id into barcode_row from public.product_barcodes b
        where b.product_id=p_product_id and b.barcode=value_text and b.is_active limit 1;
      if barcode_row is null then
        insert into public.product_barcodes(product_id,barcode,is_active,source_import_row_id,created_by,updated_by)
        values(p_product_id,value_text,true,case when same_as_source then p_source_import_row_id else null end,actor_id,actor_id) returning id into barcode_row;
      end if;
      if not same_as_source then
        insert into public.product_field_overrides(product_id,barcode_id,outlet_id,field_key,
          corrected_value,reason,source_import_row_id,corrected_by)
        values(p_product_id,barcode_row,null,'barcode',normalized_value,value_reason,p_source_import_row_id,actor_id);
      end if;
    else
      if p_field_key='rack_label' then
        update public.product_outlet_settings set rack_label=value_text,updated_by=actor_id
        where product_id=p_product_id and outlet_id=p_outlet_id;
      elsif p_field_key='hpp' then
        update public.product_costs set hpp=value_num,updated_by=actor_id
        where product_id=p_product_id and outlet_id=p_outlet_id;
      else
        update public.product_selling_prices set amount=value_num,updated_by=actor_id
        where product_id=p_product_id and outlet_id=p_outlet_id;
      end if;
      if not same_as_source then
        insert into public.product_field_overrides(product_id,barcode_id,outlet_id,field_key,
          corrected_value,reason,source_import_row_id,corrected_by)
        values(p_product_id,null,p_outlet_id,p_field_key,normalized_value,value_reason,p_source_import_row_id,actor_id);
      end if;
    end if;
  end if;

  if (p_field_key <> 'barcode' or p_barcode_operation = 'REPLACE_SOURCE')
    and same_as_source and has_override then
    perform public.field_audit_record_reconciliation(p_product_id,source_outlet,p_field_key,
      source_batch,p_source_import_row_id,active_override.id,'HUMAN_ACCEPTED_SOURCE',
      source_field,normalized_value,actor_id);
  elsif (p_field_key <> 'barcode' or p_barcode_operation = 'REPLACE_SOURCE')
    and not same_as_source then
    perform public.field_audit_record_reconciliation(p_product_id,source_outlet,p_field_key,
      source_batch,p_source_import_row_id,
      (select o.id from public.product_field_overrides o where o.product_id=p_product_id
        and o.field_key=p_field_key and o.is_active
        and (p_field_key='barcode' and o.source_import_row_id is not null
          or p_field_key<>'barcode' and o.outlet_id=p_outlet_id) limit 1),
      'SOURCE_CONFLICT',source_field,normalized_value,null);
  end if;

  insert into public.product_field_audit_reviews(product_id,outlet_id,field_key,status,
    source_import_row_id,reviewer_id,evidence_notes,request_id,barcode_id)
  values(p_product_id,case when p_field_key='barcode' then null::uuid else p_outlet_id end,
    p_field_key,'SUDAH_DIVERIFIKASI'::public.product_field_audit_status,p_source_import_row_id,
    actor_id,left(btrim(p_reason),4000),p_request_id,
    case when p_field_key='barcode' then barcode_row else null::uuid end)
  returning id into new_review;
  result_value := jsonb_build_object('ok',true,'reviewId',new_review,'alreadyApplied',false,
    'sourceSynchronized',same_as_source,
    'barcodeAssociationId',case when p_field_key='barcode' then barcode_row else null::uuid end,
    'alreadyPresent',case when p_field_key='barcode' then already_present else null end);
  insert into public.product_field_correction_requests(
    request_id,actor_id,request_payload,result,review_id
  ) values(p_request_id,actor_id,request_payload,result_value,new_review);
  return result_value;

end;
$$;
alter function public.apply_product_field_correction(uuid,uuid,uuid,text,jsonb,text,uuid,text) owner to postgres;
revoke all on function public.apply_product_field_correction(uuid,uuid,uuid,text,jsonb,text,uuid,text)
  from public, anon, authenticated, service_role;
grant execute on function public.apply_product_field_correction(uuid,uuid,uuid,text,jsonb,text,uuid,text)
  to authenticated;

commit;
