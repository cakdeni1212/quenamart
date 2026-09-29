-- Transactional Phase 2B normalization commit boundary.
-- The Phase 2A batch remains COMPLETED; normalization has its own lifecycle.
begin;

create table public.ipos_normalization_commits (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null,
  outlet_id uuid not null,
  normalization_version text not null,
  status text not null default 'PROCESSING',
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  raw_row_count integer not null,
  linked_row_count integer not null default 0,
  invalid_row_count integer not null default 0,
  finding_counts jsonb not null default '{}'::jsonb,
  preflight_state_md5 text not null,
  result jsonb,
  created_at timestamptz not null default now(),
  constraint ipos_normalization_commits_batch_outlet_fk
    foreign key (batch_id, outlet_id)
    references public.ipos_import_batches(id, outlet_id) on delete restrict,
  constraint ipos_normalization_commits_batch_version_unique
    unique (batch_id, normalization_version),
  constraint ipos_normalization_commits_id_outlet_unique unique (id, outlet_id),
  constraint ipos_normalization_commits_version_valid
    check (normalization_version = 'ipos-v1-preflight'),
  constraint ipos_normalization_commits_status_valid
    check (status in ('PROCESSING', 'COMPLETED')),
  constraint ipos_normalization_commits_lifecycle_valid check (
    (status = 'PROCESSING' and completed_at is null and result is null)
    or (status = 'COMPLETED' and completed_at is not null and result is not null)
  ),
  constraint ipos_normalization_commits_counts_valid
    check (raw_row_count >= 0 and linked_row_count >= 0 and invalid_row_count >= 0
      and (status = 'PROCESSING' or linked_row_count + invalid_row_count = raw_row_count)),
  constraint ipos_normalization_commits_findings_object
    check (jsonb_typeof(finding_counts) = 'object'),
  constraint ipos_normalization_commits_md5_valid
    check (preflight_state_md5 ~ '^[0-9a-f]{32}$')
);

create table public.ipos_normalization_commit_rows (
  commit_id uuid not null references public.ipos_normalization_commits(id) on delete restrict,
  batch_id uuid not null,
  outlet_id uuid not null,
  source_row_id uuid not null,
  source_row_number integer not null,
  action text not null,
  sku text collate "C",
  expected_product_id uuid references public.products(id) on delete restrict,
  product_id uuid references public.products(id) on delete restrict,
  normalized_data jsonb not null,
  finding_codes public.product_audit_finding_code[] not null default '{}',
  validation_errors jsonb not null default '[]'::jsonb,
  override_conflicts text[] not null default '{}',
  created_at timestamptz not null default now(),
  primary key (commit_id, source_row_number),
  constraint ipos_normalization_commit_rows_batch_outlet_fk
    foreign key (batch_id, outlet_id)
    references public.ipos_import_batches(id, outlet_id) on delete restrict,
  constraint ipos_normalization_commit_rows_commit_outlet_fk
    foreign key (commit_id, outlet_id)
    references public.ipos_normalization_commits(id, outlet_id) on delete restrict,
  constraint ipos_normalization_commit_rows_raw_provenance_fk
    foreign key (source_row_id, batch_id, outlet_id)
    references public.ipos_import_rows(id, batch_id, outlet_id) on delete restrict,
  constraint ipos_normalization_commit_rows_product_provenance_fk
    foreign key (source_row_id, product_id)
    references public.ipos_import_rows(id, product_id) on delete restrict deferrable initially deferred,
  constraint ipos_normalization_commit_rows_action_valid
    check (action in ('CREATE', 'UPDATE', 'INVALID')),
  constraint ipos_normalization_commit_rows_normalized_object
    check (jsonb_typeof(normalized_data) = 'object'),
  constraint ipos_normalization_commit_rows_errors_array
    check (jsonb_typeof(validation_errors) = 'array'),
  constraint ipos_normalization_commit_rows_action_shape check (
    action = 'INVALID'
    or (action = 'CREATE' and sku is not null and btrim(sku) <> '' and expected_product_id is null)
    or (action = 'UPDATE' and sku is not null and btrim(sku) <> '' and expected_product_id is not null)
  )
);

create unique index ipos_normalization_commit_rows_valid_sku_unique
  on public.ipos_normalization_commit_rows (commit_id, sku)
  where action in ('CREATE', 'UPDATE');
create index ipos_normalization_commits_batch_idx
  on public.ipos_normalization_commits (batch_id, completed_at desc);

alter table public.ipos_normalization_commits enable row level security;
alter table public.ipos_normalization_commit_rows enable row level security;
revoke all on public.ipos_normalization_commits, public.ipos_normalization_commit_rows
  from public, anon, authenticated, service_role;
grant select on public.ipos_normalization_commits, public.ipos_normalization_commit_rows to authenticated;
create policy ipos_normalization_commits_select_managers
  on public.ipos_normalization_commits for select to authenticated
  using (public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role));
create policy ipos_normalization_commit_rows_select_managers
  on public.ipos_normalization_commit_rows for select to authenticated
  using (public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role));

create or replace function public.guard_ipos_raw_row_immutability()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  if new.id is distinct from old.id
    or new.created_at is distinct from old.created_at
    or new.batch_id is distinct from old.batch_id
    or new.outlet_id is distinct from old.outlet_id
    or new.source_row_number is distinct from old.source_row_number
    or new.raw_data is distinct from old.raw_data then
    raise exception 'iPos raw source rows are immutable';
  end if;

  if old.status <> 'RAW_ONLY' or old.product_id is not null
    or new.status not in ('VALID', 'INVALID')
    or (new.status = 'VALID' and new.product_id is null)
    or (new.status = 'INVALID' and new.product_id is not null)
    or jsonb_typeof(new.validation_errors) <> 'array'
    or not exists (
      select 1
      from public.ipos_normalization_commits c
      join public.ipos_import_batches b on b.id = c.batch_id and b.outlet_id = c.outlet_id
      where c.batch_id = old.batch_id
        and c.outlet_id = old.outlet_id
        and c.status = 'PROCESSING'
        and b.status = 'COMPLETED'
    ) then
    raise exception 'Raw rows can only be linked once by a running normalization commit';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_ipos_raw_row_immutability() from public, anon, authenticated, service_role;

create or replace function public.guard_ipos_normalization_commit_update()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  if new.id is distinct from old.id
    or new.batch_id is distinct from old.batch_id
    or new.outlet_id is distinct from old.outlet_id
    or new.normalization_version is distinct from old.normalization_version
    or new.started_at is distinct from old.started_at
    or new.raw_row_count is distinct from old.raw_row_count
    or new.preflight_state_md5 is distinct from old.preflight_state_md5
    or new.created_at is distinct from old.created_at
    or old.status <> 'PROCESSING'
    or new.status <> 'COMPLETED'
    or new.completed_at is null
    or new.result is null then
    raise exception 'Normalization commit identity is immutable and only PROCESSING to COMPLETED is allowed';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_ipos_normalization_commit_update() from public, anon, authenticated, service_role;
create trigger ipos_normalization_commits_lifecycle_guard
  before update on public.ipos_normalization_commits
  for each row execute function public.guard_ipos_normalization_commit_update();

create or replace function public.guard_ipos_normalization_commit_row_update()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  if new.commit_id is distinct from old.commit_id
    or new.batch_id is distinct from old.batch_id
    or new.outlet_id is distinct from old.outlet_id
    or new.source_row_id is distinct from old.source_row_id
    or new.source_row_number is distinct from old.source_row_number
    or new.action is distinct from old.action
    or new.sku is distinct from old.sku
    or new.expected_product_id is distinct from old.expected_product_id
    or new.normalized_data is distinct from old.normalized_data
    or new.finding_codes is distinct from old.finding_codes
    or new.validation_errors is distinct from old.validation_errors
    or new.override_conflicts is distinct from old.override_conflicts
    or new.created_at is distinct from old.created_at
    or old.product_id is not null
    or new.product_id is null
    or not exists (
      select 1 from public.ipos_normalization_commits c
      where c.id = old.commit_id and c.status = 'PROCESSING'
    ) then
    raise exception 'Normalization proposal is immutable; product links are assigned once during commit';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_ipos_normalization_commit_row_update() from public, anon, authenticated, service_role;
create trigger ipos_normalization_commit_rows_link_guard
  before update on public.ipos_normalization_commit_rows
  for each row execute function public.guard_ipos_normalization_commit_row_update();

create or replace function public.reject_ipos_normalization_commit_delete()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  raise exception 'Normalization commit evidence is append-only';
end;
$$;
revoke all on function public.reject_ipos_normalization_commit_delete() from public, anon, authenticated, service_role;
create trigger ipos_normalization_commits_no_delete
  before delete on public.ipos_normalization_commits
  for each row execute function public.reject_ipos_normalization_commit_delete();
create trigger ipos_normalization_commit_rows_no_delete
  before delete on public.ipos_normalization_commit_rows
  for each row execute function public.reject_ipos_normalization_commit_delete();

create or replace function public.commit_ipos_normalization(
  p_batch_id uuid,
  p_normalization_version text,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  batch_row public.ipos_import_batches%rowtype;
  prior_commit public.ipos_normalization_commits%rowtype;
  commit_id_value uuid;
  row_count_value integer;
  linked_count_value integer;
  invalid_count_value integer;
  finding_counts_value jsonb;
  expected_state_value jsonb;
  actual_state_value jsonb;
  result_value jsonb;
  payload_row_count integer;
  first_source_row integer;
  last_source_row integer;
begin
  select * into batch_row
  from public.ipos_import_batches
  where id = p_batch_id
  for update;
  if not found then raise exception 'iPos batch not found'; end if;

  select * into prior_commit
  from public.ipos_normalization_commits
  where batch_id = p_batch_id and normalization_version = p_normalization_version
  for update;
  if found then
    if prior_commit.status = 'COMPLETED' then
      return prior_commit.result || jsonb_build_object('alreadyCompleted', true);
    end if;
    raise exception 'A normalization attempt is already present and requires investigation';
  end if;

  if p_payload is null then
    return jsonb_build_object('alreadyCompleted', false, 'commitRequired', true);
  end if;
  if p_normalization_version <> 'ipos-v1-preflight'
    or batch_row.status <> 'COMPLETED'
    or batch_row.actual_data_row_count is null
    or batch_row.expected_data_row_count is distinct from batch_row.actual_data_row_count
    or coalesce(batch_row.validation_errors, '[]'::jsonb) <> '[]'::jsonb then
    raise exception 'Batch is not an eligible completed raw snapshot';
  end if;
  if p_payload->>'normalizationVersion' is distinct from p_normalization_version
    or p_payload->>'batchId' is distinct from p_batch_id::text
    or p_payload->>'outletId' is distinct from batch_row.outlet_id::text
    or jsonb_typeof(p_payload->'expectedState') <> 'object'
    or jsonb_typeof(p_payload->'rows') <> 'array' then
    raise exception 'Normalization payload metadata is invalid';
  end if;

  -- Serialize commits across batches so SKU/name/barcode checks see a stable
  -- normalized catalog. Future normalized writers must take this same lock.
  perform pg_catalog.pg_advisory_xact_lock(734921, 2);

  expected_state_value := p_payload->'expectedState';
  with proposed as (
    select r.normalized_data->>'sku' as sku,
      r.normalized_data->>'barcode' as barcode
    from jsonb_to_recordset(p_payload->'rows') as r(normalized_data jsonb)
  ), sku_set as (
    select distinct sku from proposed where sku is not null and sku <> ''
  ), candidate_products as (
    select p.id from public.products p join sku_set s on s.sku = p.sku
  ), barcode_set as (
    select distinct barcode from proposed where barcode is not null and barcode <> ''
  )
  select jsonb_build_object(
    'products', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'sku', p.sku, 'name', p.name) order by p.id)
      from public.products p
    ), '[]'::jsonb),
    'barcodes', coalesce((
      select jsonb_agg(jsonb_build_object('id', b.id, 'product_id', b.product_id,
        'barcode', b.barcode, 'source_import_row_id', b.source_import_row_id) order by b.id)
      from public.product_barcodes b
      where b.is_active and (
        b.product_id in (select cp.id from candidate_products cp)
        or b.barcode in (select bs.barcode from barcode_set bs)
      )
    ), '[]'::jsonb),
    'overrides', coalesce((
      select jsonb_agg(jsonb_build_object('id', o.id, 'product_id', o.product_id,
        'barcode_id', o.barcode_id, 'outlet_id', o.outlet_id,
        'field_key', o.field_key, 'corrected_value', o.corrected_value) order by o.id)
      from public.product_field_overrides o
      where o.is_active and o.product_id in (select cp.id from candidate_products cp)
    ), '[]'::jsonb)
  ) into actual_state_value;
  if actual_state_value is distinct from expected_state_value then
    raise exception 'Normalized products, barcodes, or overrides changed since preflight; rerun preflight';
  end if;

  select count(*)::integer, min(r.source_row_number), max(r.source_row_number)
  into row_count_value, first_source_row, last_source_row
  from public.ipos_import_rows r where r.batch_id = p_batch_id;
  select count(*)::integer into payload_row_count
  from jsonb_array_elements(p_payload->'rows');
  if row_count_value <> batch_row.actual_data_row_count
    or payload_row_count <> row_count_value
    or (row_count_value > 0 and (first_source_row <> 3 or last_source_row <> row_count_value + 2))
    or exists (
      select 1 from public.ipos_import_rows r
      where r.batch_id = p_batch_id
        and (r.status <> 'RAW_ONLY' or r.product_id is not null)
    ) then
    raise exception 'Raw snapshot is not wholly RAW_ONLY or payload row count differs';
  end if;

  commit_id_value := gen_random_uuid();
  insert into public.ipos_normalization_commits (
    id, batch_id, outlet_id, normalization_version, status, raw_row_count,
    preflight_state_md5, finding_counts
  ) values (
    commit_id_value, p_batch_id, batch_row.outlet_id, p_normalization_version,
    'PROCESSING', row_count_value, md5(expected_state_value::text), '{}'::jsonb
  );

  insert into public.ipos_normalization_commit_rows (
    commit_id, batch_id, outlet_id, source_row_id, source_row_number,
    action, sku, expected_product_id, normalized_data, finding_codes, validation_errors, override_conflicts
  )
  select commit_id_value, p_batch_id, batch_row.outlet_id,
    (x.source_row_id)::uuid, (x.source_row)::integer, x.action, x.sku, x.expected_product_id,
    x.normalized_data,
    array(select jsonb_array_elements_text(coalesce(x.audit_findings, '[]'::jsonb))::public.product_audit_finding_code),
    coalesce(x.issues, '[]'::jsonb),
    array(select jsonb_array_elements_text(coalesce(x.blocked_override_fields, '[]'::jsonb)))
  from jsonb_to_recordset(p_payload->'rows') as x(
    source_row_id text, source_row integer, action text, sku text, expected_product_id uuid,
    normalized_data jsonb, audit_findings jsonb, issues jsonb, blocked_override_fields jsonb
  );

  if (select count(*) from public.ipos_normalization_commit_rows c where c.commit_id = commit_id_value) <> row_count_value
    or exists (
      select 1 from public.ipos_normalization_commit_rows c
      left join public.ipos_import_rows r on r.id = c.source_row_id
        and r.batch_id = c.batch_id and r.outlet_id = c.outlet_id
        and r.source_row_number = c.source_row_number
      where c.commit_id = commit_id_value and r.id is null
    )
    or exists (
      select 1 from public.ipos_normalization_commit_rows c
      where c.commit_id = commit_id_value and c.action in ('CREATE', 'UPDATE')
        and (c.sku is null or c.sku = '' or c.sku ~ '[[:cntrl:]]'
          or c.normalized_data->>'sku' is distinct from c.sku
          or c.normalized_data->>'name' is null
          or btrim(c.normalized_data->>'name') = '')
    ) then
    raise exception 'Proposal rows or product identity validation failed';
  end if;

  if exists (
    select 1 from public.ipos_normalization_commit_rows c
    left join public.products p on p.sku = c.sku
    where c.commit_id = commit_id_value and (
      (c.action = 'CREATE' and p.id is not null)
      or (c.action = 'UPDATE' and p.id is distinct from c.expected_product_id)
    )
  ) then
    raise exception 'CREATE/UPDATE SKU matching changed since preflight';
  end if;

  insert into public.products as current_product (
    sku, name, category_label, brand_label, unit_label, department_label,
    source_description, source_reference_code, created_from_import_row_id,
    last_import_row_id, created_by, updated_by
  )
  select c.sku, c.normalized_data->>'name', c.normalized_data->>'categoryLabel',
    c.normalized_data->>'brandLabel', c.normalized_data->>'unitLabel',
    c.normalized_data->>'departmentLabel', c.normalized_data->>'sourceDescription',
    c.normalized_data->>'sourceReferenceCode', c.source_row_id, c.source_row_id,
    batch_row.imported_by, batch_row.imported_by
  from public.ipos_normalization_commit_rows c
  where c.commit_id = commit_id_value and c.action in ('CREATE', 'UPDATE')
  on conflict (sku) do update set
    name = coalesce((select o.corrected_value #>> '{}' from public.product_field_overrides o
      where o.product_id = current_product.id and o.outlet_id is null
        and o.barcode_id is null and o.field_key = 'name' and o.is_active), excluded.name),
    category_label = coalesce((select o.corrected_value #>> '{}' from public.product_field_overrides o
      where o.product_id = current_product.id and o.outlet_id is null
        and o.barcode_id is null and o.field_key = 'category_label' and o.is_active),
      case when exists (select 1 from public.ipos_normalization_commit_rows c
        where c.commit_id = commit_id_value and c.product_id = current_product.id
          and exists (select 1 from jsonb_array_elements(c.validation_errors) e
            where e->>'code' = 'INVALID_TEXT_TYPE' and e->>'field' = 'JENIS'))
        then current_product.category_label else excluded.category_label end),
    brand_label = coalesce((select o.corrected_value #>> '{}' from public.product_field_overrides o
      where o.product_id = current_product.id and o.outlet_id is null
        and o.barcode_id is null and o.field_key = 'brand_label' and o.is_active),
      case when exists (select 1 from public.ipos_normalization_commit_rows c
        where c.commit_id = commit_id_value and c.product_id = current_product.id
          and exists (select 1 from jsonb_array_elements(c.validation_errors) e
            where e->>'code' = 'INVALID_TEXT_TYPE' and e->>'field' = 'MEREK'))
        then current_product.brand_label else excluded.brand_label end),
    unit_label = coalesce((select o.corrected_value #>> '{}' from public.product_field_overrides o
      where o.product_id = current_product.id and o.outlet_id is null
        and o.barcode_id is null and o.field_key = 'unit_label' and o.is_active),
      case when exists (select 1 from public.ipos_normalization_commit_rows c
        where c.commit_id = commit_id_value and c.product_id = current_product.id
          and exists (select 1 from jsonb_array_elements(c.validation_errors) e
            where e->>'code' = 'INVALID_TEXT_TYPE' and e->>'field' = 'SATUAN'))
        then current_product.unit_label else excluded.unit_label end),
    department_label = coalesce((select o.corrected_value #>> '{}' from public.product_field_overrides o
      where o.product_id = current_product.id and o.outlet_id is null
        and o.barcode_id is null and o.field_key = 'department_label' and o.is_active),
      case when exists (select 1 from public.ipos_normalization_commit_rows c
        where c.commit_id = commit_id_value and c.product_id = current_product.id
          and exists (select 1 from jsonb_array_elements(c.validation_errors) e
            where e->>'code' = 'INVALID_TEXT_TYPE' and e->>'field' = 'DEPT'))
        then current_product.department_label else excluded.department_label end),
    source_description = coalesce((select o.corrected_value #>> '{}' from public.product_field_overrides o
      where o.product_id = current_product.id and o.outlet_id is null
        and o.barcode_id is null and o.field_key = 'source_description' and o.is_active),
      case when exists (select 1 from public.ipos_normalization_commit_rows c
        where c.commit_id = commit_id_value and c.product_id = current_product.id
          and exists (select 1 from jsonb_array_elements(c.validation_errors) e
            where e->>'code' = 'INVALID_TEXT_TYPE' and e->>'field' = 'KETERANGAN'))
        then current_product.source_description else excluded.source_description end),
    source_reference_code = coalesce((select o.corrected_value #>> '{}' from public.product_field_overrides o
      where o.product_id = current_product.id and o.outlet_id is null
        and o.barcode_id is null and o.field_key = 'source_reference_code' and o.is_active),
      case when exists (select 1 from public.ipos_normalization_commit_rows c
        where c.commit_id = commit_id_value and c.product_id = current_product.id
          and exists (select 1 from jsonb_array_elements(c.validation_errors) e
            where e->>'code' = 'INVALID_TEXT_TYPE' and e->>'field' = 'KODEREFERENSI'))
        then current_product.source_reference_code else excluded.source_reference_code end),
    last_import_row_id = excluded.last_import_row_id,
    updated_by = batch_row.imported_by;

  update public.ipos_normalization_commit_rows c
  set product_id = p.id
  from public.products p
  where c.commit_id = commit_id_value and c.action in ('CREATE', 'UPDATE') and p.sku = c.sku;

  select count(*)::integer into linked_count_value
  from public.ipos_normalization_commit_rows c
  where c.commit_id = commit_id_value and c.action in ('CREATE', 'UPDATE') and c.product_id is not null;
  invalid_count_value := row_count_value - linked_count_value;
  if linked_count_value <> (
    select count(*) from public.ipos_normalization_commit_rows c
    where c.commit_id = commit_id_value and c.action in ('CREATE', 'UPDATE')
  ) then raise exception 'A valid proposal could not be linked to its product'; end if;

  update public.ipos_import_rows r
  set product_id = c.product_id,
      status = case when c.action = 'INVALID' then 'INVALID'::public.ipos_import_row_status
        else 'VALID'::public.ipos_import_row_status end,
      validation_errors = c.validation_errors
  from public.ipos_normalization_commit_rows c
  where c.commit_id = commit_id_value and r.id = c.source_row_id;

  update public.product_barcodes b
  set is_active = false, updated_by = batch_row.imported_by
  from public.ipos_normalization_commit_rows c
  where c.commit_id = commit_id_value and c.product_id = b.product_id
    and c.action in ('CREATE', 'UPDATE') and b.is_active
    and b.source_import_row_id is not null
    and (c.normalized_data->>'barcodeState' = 'BLANK'
      or (c.normalized_data->>'barcodeState' = 'VALID'
        and b.barcode <> c.normalized_data->>'barcode'))
    and not exists (
      select 1 from public.product_field_overrides o
      where o.product_id = c.product_id and o.field_key = 'barcode'
        and o.barcode_id = b.id and o.is_active
    );

  insert into public.product_barcodes as existing_barcode (
    product_id, barcode, is_active, source_import_row_id, created_by, updated_by
  )
  select c.product_id, c.normalized_data->>'barcode', true,
    c.source_row_id, batch_row.imported_by, batch_row.imported_by
  from public.ipos_normalization_commit_rows c
  where c.commit_id = commit_id_value and c.action in ('CREATE', 'UPDATE')
    and c.normalized_data->>'barcode' is not null
    and c.normalized_data->>'barcodeState' = 'VALID'
    and not exists (
      select 1 from public.product_field_overrides o
      join public.product_barcodes protected_barcode on protected_barcode.id = o.barcode_id
      where o.product_id = c.product_id and o.field_key = 'barcode' and o.is_active
        and protected_barcode.source_import_row_id is not null
    )
  on conflict (product_id, barcode) where is_active do update set
    source_import_row_id = excluded.source_import_row_id,
    updated_by = batch_row.imported_by
  where existing_barcode.source_import_row_id is not null;

  insert into public.product_outlet_settings as current_settings (
    product_id, outlet_id, rack_label, source_import_row_id, created_by, updated_by
  )
  select c.product_id, batch_row.outlet_id,
    coalesce((select o.corrected_value #>> '{}' from public.product_field_overrides o
      where o.product_id = c.product_id and o.outlet_id = batch_row.outlet_id
        and o.field_key = 'rack_label' and o.is_active),
      case when exists (select 1 from jsonb_array_elements(c.validation_errors) e
        where e->>'code' = 'INVALID_TEXT_TYPE' and e->>'field' = 'RAK') then null
        else c.normalized_data->>'rackLabel' end),
    c.source_row_id, batch_row.imported_by, batch_row.imported_by
  from public.ipos_normalization_commit_rows c
  where c.commit_id = commit_id_value and c.action in ('CREATE', 'UPDATE')
  on conflict (product_id, outlet_id) do update set
    rack_label = coalesce((select (o.corrected_value #>> '{}') from public.product_field_overrides o
      where o.product_id = excluded.product_id and o.outlet_id = excluded.outlet_id
        and o.field_key = 'rack_label' and o.is_active),
      case when exists (select 1 from public.ipos_normalization_commit_rows c
        where c.commit_id = commit_id_value and c.product_id = excluded.product_id
          and exists (select 1 from jsonb_array_elements(c.validation_errors) e
            where e->>'code' = 'INVALID_TEXT_TYPE' and e->>'field' = 'RAK'))
        then current_settings.rack_label else excluded.rack_label end),
    source_import_row_id = excluded.source_import_row_id,
    updated_by = batch_row.imported_by;

  insert into public.product_inventory as current_inventory (
    product_id, outlet_id, quantity, minimum_quantity, source_import_row_id, created_by, updated_by
  )
  select c.product_id, batch_row.outlet_id,
    case when exists (select 1 from jsonb_array_elements(c.validation_errors) e
      where e->>'code' = 'INVALID_NUMERIC_VALUE' and e->>'field' = 'STOK') then null
      else nullif(c.normalized_data->>'quantity', '')::numeric end,
    case when exists (select 1 from jsonb_array_elements(c.validation_errors) e
      where e->>'code' = 'INVALID_NUMERIC_VALUE' and e->>'field' = 'STOKMIN') then null
      else nullif(c.normalized_data->>'minimumQuantity', '')::numeric end,
    c.source_row_id, batch_row.imported_by, batch_row.imported_by
  from public.ipos_normalization_commit_rows c
  where c.commit_id = commit_id_value and c.action in ('CREATE', 'UPDATE')
  on conflict (product_id, outlet_id) do update set
    quantity = coalesce((select (o.corrected_value #>> '{}')::numeric
      from public.product_field_overrides o where o.product_id = excluded.product_id
        and o.outlet_id = excluded.outlet_id and o.field_key = 'quantity' and o.is_active),
      case when exists (select 1 from public.ipos_normalization_commit_rows c
        where c.commit_id = commit_id_value and c.product_id = excluded.product_id
          and exists (select 1 from jsonb_array_elements(c.validation_errors) e
            where e->>'code' = 'INVALID_NUMERIC_VALUE' and e->>'field' = 'STOK'))
        then current_inventory.quantity else excluded.quantity end),
    minimum_quantity = coalesce((select (o.corrected_value #>> '{}')::numeric
      from public.product_field_overrides o where o.product_id = excluded.product_id
        and o.outlet_id = excluded.outlet_id and o.field_key = 'minimum_quantity' and o.is_active),
      case when exists (select 1 from public.ipos_normalization_commit_rows c
        where c.commit_id = commit_id_value and c.product_id = excluded.product_id
          and exists (select 1 from jsonb_array_elements(c.validation_errors) e
            where e->>'code' = 'INVALID_NUMERIC_VALUE' and e->>'field' = 'STOKMIN'))
        then current_inventory.minimum_quantity else excluded.minimum_quantity end),
    source_import_row_id = excluded.source_import_row_id,
    updated_by = batch_row.imported_by;

  insert into public.product_selling_prices as current_price (
    product_id, outlet_id, amount, source_import_row_id, created_by, updated_by
  )
  select c.product_id, batch_row.outlet_id,
    case when exists (select 1 from jsonb_array_elements(c.validation_errors) e
      where e->>'code' = 'INVALID_NUMERIC_VALUE' and e->>'field' = 'HARGAJUAL') then null
      else nullif(c.normalized_data->>'sellingPrice', '')::numeric end,
    c.source_row_id, batch_row.imported_by, batch_row.imported_by
  from public.ipos_normalization_commit_rows c
  where c.commit_id = commit_id_value and c.action in ('CREATE', 'UPDATE')
  on conflict (product_id, outlet_id) do update set
    amount = coalesce((select (o.corrected_value #>> '{}')::numeric
      from public.product_field_overrides o where o.product_id = excluded.product_id
        and o.outlet_id = excluded.outlet_id and o.field_key = 'selling_price' and o.is_active),
      case when exists (select 1 from public.ipos_normalization_commit_rows c
        where c.commit_id = commit_id_value and c.product_id = excluded.product_id
          and exists (select 1 from jsonb_array_elements(c.validation_errors) e
            where e->>'code' = 'INVALID_NUMERIC_VALUE' and e->>'field' = 'HARGAJUAL'))
        then current_price.amount else excluded.amount end),
    source_import_row_id = excluded.source_import_row_id,
    updated_by = batch_row.imported_by;

  insert into public.product_costs as current_cost (
    product_id, outlet_id, hpp, source_import_row_id, created_by, updated_by
  )
  select c.product_id, batch_row.outlet_id,
    case when exists (select 1 from jsonb_array_elements(c.validation_errors) e
      where e->>'code' = 'INVALID_NUMERIC_VALUE' and e->>'field' = 'HARGAPOKOK') then null
      else nullif(c.normalized_data->>'hpp', '')::numeric end,
    c.source_row_id, batch_row.imported_by, batch_row.imported_by
  from public.ipos_normalization_commit_rows c
  where c.commit_id = commit_id_value and c.action in ('CREATE', 'UPDATE')
  on conflict (product_id, outlet_id) do update set
    hpp = coalesce((select (o.corrected_value #>> '{}')::numeric
      from public.product_field_overrides o where o.product_id = excluded.product_id
        and o.outlet_id = excluded.outlet_id and o.field_key = 'hpp' and o.is_active),
      case when exists (select 1 from public.ipos_normalization_commit_rows c
        where c.commit_id = commit_id_value and c.product_id = excluded.product_id
          and exists (select 1 from jsonb_array_elements(c.validation_errors) e
            where e->>'code' = 'INVALID_NUMERIC_VALUE' and e->>'field' = 'HARGAPOKOK'))
        then current_cost.hpp else excluded.hpp end),
    source_import_row_id = excluded.source_import_row_id,
    updated_by = batch_row.imported_by;

  insert into public.product_audit_findings (
    product_id, outlet_id, batch_id, import_row_id, finding_code
  )
  select c.product_id, batch_row.outlet_id, p_batch_id, c.source_row_id, finding_rows.finding_code
  from public.ipos_normalization_commit_rows c
  cross join lateral unnest(c.finding_codes) as finding_rows(finding_code)
  where c.commit_id = commit_id_value and c.product_id is not null
  on conflict (import_row_id, finding_code) do nothing;

  update public.product_audit_findings f
  set status = 'RESOLVED', resolution_batch_id = p_batch_id, resolved_by = batch_row.imported_by
  where f.outlet_id = batch_row.outlet_id and f.status = 'OPEN' and f.batch_id <> p_batch_id
    and exists (
      select 1 from public.ipos_normalization_commit_rows c
      where c.commit_id = commit_id_value and c.product_id = f.product_id
    )
    and not exists (
      select 1 from public.ipos_normalization_commit_rows c
      cross join lateral unnest(c.finding_codes) as finding_rows(finding_code)
      where c.commit_id = commit_id_value and c.product_id = f.product_id
        and finding_rows.finding_code = f.finding_code
    );

  select (count(*) filter (where c.action in ('CREATE', 'UPDATE')))::integer,
    (count(*) filter (where c.action = 'INVALID'))::integer
  into linked_count_value, invalid_count_value
  from public.ipos_normalization_commit_rows c where c.commit_id = commit_id_value;

  select coalesce(jsonb_object_agg(code, finding_count), '{}'::jsonb)
  into finding_counts_value
  from (
    select finding_code::text as code, count(*)::integer as finding_count
  from public.ipos_normalization_commit_rows c
  cross join lateral unnest(c.finding_codes) as finding_rows(finding_code)
  where c.commit_id = commit_id_value and c.product_id is not null
  group by finding_rows.finding_code
  ) counts;

  result_value := jsonb_build_object(
    'alreadyCompleted', false,
    'commitId', commit_id_value,
    'batchId', p_batch_id,
    'normalizationVersion', p_normalization_version,
    'rawRows', row_count_value,
    'linkedRows', linked_count_value,
    'invalidRows', invalid_count_value,
    'auditFindingCountByType', jsonb_build_object(
      'MISSING_BARCODE', 0, 'MALFORMED_BARCODE', 0, 'DUPLICATE_BARCODE', 0,
      'ZERO_OR_MISSING_HPP', 0, 'SELLING_PRICE_BELOW_HPP', 0, 'ZERO_STOCK', 0,
      'STOCK_AT_OR_BELOW_MINIMUM', 0, 'MISSING_RACK', 0, 'DUPLICATE_PRODUCT_NAME', 0
    ) || finding_counts_value,
    'newProducts', (select count(*)::integer from public.ipos_normalization_commit_rows c
      where c.commit_id = commit_id_value and c.action = 'CREATE'),
    'updatedProducts', (select count(*)::integer from public.ipos_normalization_commit_rows c
      where c.commit_id = commit_id_value and c.action = 'UPDATE'),
    'overrideConflictCount', (
      select coalesce(sum(cardinality(c.override_conflicts)), 0)::integer
      from public.ipos_normalization_commit_rows c where c.commit_id = commit_id_value
    )
  );
  update public.ipos_normalization_commits
  set status = 'COMPLETED', completed_at = now(), linked_row_count = linked_count_value,
    invalid_row_count = invalid_count_value, finding_counts = finding_counts_value,
    result = result_value
  where id = commit_id_value;
  return result_value;
end;
$$;

alter function public.commit_ipos_normalization(uuid, text, jsonb) owner to postgres;
revoke all on function public.commit_ipos_normalization(uuid, text, jsonb)
  from public, anon, authenticated, service_role;
grant execute on function public.commit_ipos_normalization(uuid, text, jsonb) to service_role;

-- Normalized writes and row linking now occur only inside the trusted RPC.
revoke insert, update on public.ipos_import_rows from service_role;
grant insert on public.ipos_import_rows to service_role;
revoke insert, update on public.products, public.product_barcodes,
  public.product_outlet_settings, public.product_inventory,
  public.product_selling_prices, public.product_costs,
  public.product_audit_findings, public.product_field_audit_reviews,
  public.product_field_overrides from service_role;

commit;
