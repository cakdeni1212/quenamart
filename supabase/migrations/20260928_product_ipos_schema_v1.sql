-- Proposed Product & iPos Import Schema v1.
-- This migration is versioned source only; review and apply manually.
-- It does not alter public.profiles or its policies.

begin;

create type public.ipos_import_batch_status as enum (
  'UPLOADED',
  'PROCESSING',
  'COMPLETED',
  'COMPLETED_WITH_ERRORS',
  'FAILED'
);

create type public.ipos_import_row_status as enum (
  'RAW_ONLY',
  'VALID',
  'INVALID'
);

create type public.product_audit_finding_code as enum (
  'MISSING_BARCODE',
  'MALFORMED_BARCODE',
  'DUPLICATE_BARCODE',
  'ZERO_OR_MISSING_HPP',
  'SELLING_PRICE_BELOW_HPP',
  'ZERO_STOCK',
  'STOCK_AT_OR_BELOW_MINIMUM',
  'MISSING_RACK',
  'DUPLICATE_PRODUCT_NAME'
);

create type public.product_audit_finding_status as enum (
  'OPEN',
  'RESOLVED'
);

create type public.product_field_audit_status as enum (
  'BELUM_DICEK',
  'SEDANG_DICEK',
  'SUDAH_DIVERIFIKASI',
  'PERLU_KOREKSI_IPOS'
);

create or replace function public.current_active_user_role()
returns public.user_role
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p.role
  from public.profiles as p
  where p.id = (select auth.uid())
    and p.is_active
  limit 1
$$;

revoke all on function public.current_active_user_role() from public, anon;
grant execute on function public.current_active_user_role() to authenticated;

create or replace function public.quena_ipos_set_updated_at()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
revoke all on function public.quena_ipos_set_updated_at() from public, anon, authenticated;

create or replace function public.normalize_product_name(input_name text)
returns text
language sql
immutable
set search_path = pg_catalog
as $$
  select lower(
    regexp_replace(
      btrim(normalize(input_name, NFC)),
      '[[:space:]]+',
      ' ',
      'g'
    )
  ) collate "C"
$$;
revoke all on function public.normalize_product_name(text) from public, anon;
grant execute on function public.normalize_product_name(text) to authenticated;

create table public.outlets (
  id uuid primary key default gen_random_uuid(),
  code text collate "C" not null unique,
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint outlets_code_nonblank check (btrim(code) <> ''),
  constraint outlets_name_nonblank check (btrim(name) <> '')
);

insert into public.outlets (code, name)
values ('QUENA-MART-1', 'Quena Mart')
on conflict (code) do nothing;

create table public.ipos_import_batches (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references public.outlets(id) on delete restrict,
  original_filename text not null,
  storage_bucket text not null default 'quena-ipos-imports',
  storage_path text not null,
  file_sha256 text,
  source_sheet text not null default 'Satu Harga',
  header_row_number integer not null default 2,
  first_data_row_number integer not null default 3,
  expected_data_row_count integer,
  actual_data_row_count integer,
  validation_errors jsonb not null default '[]'::jsonb,
  imported_by uuid not null references auth.users(id) on delete restrict,
  status public.ipos_import_batch_status not null default 'UPLOADED',
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ipos_batches_filename_nonblank check (btrim(original_filename) <> ''),
  constraint ipos_batches_storage_path_nonblank check (btrim(storage_path) <> ''),
  constraint ipos_batches_private_bucket check (storage_bucket = 'quena-ipos-imports'),
  constraint ipos_batches_file_path_unique unique (storage_bucket, storage_path),
  constraint ipos_batches_source_rows_nonnegative check (expected_data_row_count is null or expected_data_row_count >= 0),
  constraint ipos_batches_actual_rows_nonnegative check (actual_data_row_count is null or actual_data_row_count >= 0),
  constraint ipos_batches_errors_array check (jsonb_typeof(validation_errors) = 'array'),
  constraint ipos_batches_row_layout check (header_row_number > 0 and first_data_row_number > header_row_number),
  constraint ipos_batches_sha256_format check (file_sha256 is null or file_sha256 ~ '^[0-9a-fA-F]{64}$')
);
alter table public.ipos_import_batches add constraint ipos_batches_id_outlet_unique unique (id, outlet_id);

create or replace function public.guard_ipos_batch_source_immutability()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  if old.status in ('COMPLETED', 'COMPLETED_WITH_ERRORS', 'FAILED')
    and (to_jsonb(new) - 'updated_at') is distinct from (to_jsonb(old) - 'updated_at') then
    raise exception 'Completed iPos batches are immutable';
  end if;
  if new.outlet_id is distinct from old.outlet_id
    or new.request_id is distinct from old.request_id
    or new.original_filename is distinct from old.original_filename
    or new.storage_bucket is distinct from old.storage_bucket
    or new.storage_path is distinct from old.storage_path
    or new.file_sha256 is distinct from old.file_sha256
    or new.source_sheet is distinct from old.source_sheet
    or new.header_row_number is distinct from old.header_row_number
    or new.first_data_row_number is distinct from old.first_data_row_number
    or new.imported_by is distinct from old.imported_by
  then
    raise exception 'iPos batch source metadata is immutable';
  end if;
  if new.status is distinct from old.status then
    if not ((old.status = 'UPLOADED' and new.status in ('PROCESSING', 'FAILED'))
      or (old.status = 'PROCESSING' and new.status in ('COMPLETED', 'COMPLETED_WITH_ERRORS', 'FAILED'))) then
      raise exception 'Invalid iPos batch status transition';
    end if;
    if new.status = 'PROCESSING' then new.started_at := now(); end if;
    if new.status <> 'PROCESSING' then new.started_at := old.started_at; end if;
    if new.status in ('COMPLETED', 'COMPLETED_WITH_ERRORS', 'FAILED') then new.completed_at := now();
    else new.completed_at := old.completed_at; end if;
  elsif new.started_at is distinct from old.started_at or new.completed_at is distinct from old.completed_at then
    raise exception 'iPos batch lifecycle timestamps are system managed';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_ipos_batch_source_immutability() from public, anon, authenticated;

create or replace function public.guard_ipos_request_lifecycle()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  if new.id is distinct from old.id
    or new.outlet_id is distinct from old.outlet_id
    or new.requested_by is distinct from old.requested_by
    or new.storage_path is distinct from old.storage_path
    or new.created_at is distinct from old.created_at then
    raise exception 'iPos import request identity is immutable';
  end if;
  if new.state is distinct from old.state
    and not ((old.state = 'QUEUED' and new.state in ('PROCESSING', 'FAILED'))
      or (old.state = 'PROCESSING' and new.state in ('COMPLETED', 'FAILED'))) then
    raise exception 'Invalid iPos import request state transition';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_ipos_request_lifecycle() from public, anon, authenticated;

create table public.products (
  id uuid primary key default gen_random_uuid(),
  sku text collate "C" not null unique,
  name text not null,
  category_label text,
  brand_label text,
  unit_label text,
  department_label text,
  source_description text,
  source_reference_code text,
  created_from_import_row_id uuid,
  last_import_row_id uuid,
  created_by uuid not null references auth.users(id) on delete restrict,
  updated_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint products_sku_valid check (
    sku <> '' and sku = btrim(sku) and sku !~ '[[:cntrl:]]'
    and sku !~ '^[[:space:]]|[[:space:]]$'
  ),
  constraint products_name_nonblank check (btrim(name) <> '')
);

create table public.ipos_import_rows (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.ipos_import_batches(id) on delete restrict,
  outlet_id uuid not null references public.outlets(id) on delete restrict,
  source_row_number integer not null,
  raw_data jsonb not null,
  status public.ipos_import_row_status not null default 'RAW_ONLY',
  product_id uuid references public.products(id) on delete restrict,
  validation_errors jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  constraint ipos_import_rows_source_row_valid check (source_row_number >= 3),
  constraint ipos_import_rows_raw_object check (jsonb_typeof(raw_data) = 'object'),
  constraint ipos_import_rows_errors_array check (jsonb_typeof(validation_errors) = 'array'),
  constraint ipos_import_rows_batch_row_unique unique (batch_id, source_row_number)
);
alter table public.ipos_import_rows
  add constraint ipos_rows_batch_outlet_fk foreign key (batch_id, outlet_id)
    references public.ipos_import_batches(id, outlet_id) on delete restrict,
  add constraint ipos_rows_id_product_unique unique (id, product_id),
  add constraint ipos_rows_id_product_outlet_unique unique (id, product_id, outlet_id),
  add constraint ipos_rows_id_batch_outlet_unique unique (id, batch_id, outlet_id),
  add constraint ipos_rows_full_provenance_unique unique (id, batch_id, outlet_id, product_id);

create table public.ipos_import_requests (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references public.outlets(id) on delete restrict,
  requested_by uuid not null references auth.users(id) on delete restrict,
  storage_path text not null unique,
  state text not null default 'QUEUED' check (state in ('QUEUED', 'PROCESSING', 'COMPLETED', 'FAILED')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ipos_request_path_nonblank check (btrim(storage_path) <> '')
);
alter table public.ipos_import_requests add constraint ipos_requests_id_outlet_unique unique (id, outlet_id);
alter table public.ipos_import_batches
  add column request_id uuid not null unique,
  add constraint ipos_batches_request_outlet_fk
    foreign key (request_id, outlet_id)
    references public.ipos_import_requests(id, outlet_id) on delete restrict,
  add constraint ipos_batches_request_path_fk
    foreign key (storage_path)
    references public.ipos_import_requests(storage_path) on delete restrict;

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
    or new.raw_data is distinct from old.raw_data
  then
    raise exception 'iPos raw source rows are immutable';
  end if;
  if not exists (
    select 1 from public.ipos_import_batches b
    where b.id = old.batch_id and b.status = 'PROCESSING'
  ) then
    raise exception 'Processed iPos rows are immutable';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_ipos_raw_row_immutability() from public, anon, authenticated;

create or replace function public.guard_ipos_raw_row_insert()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  if not exists (
    select 1 from public.ipos_import_batches b
    where b.id = new.batch_id and b.outlet_id = new.outlet_id and b.status = 'PROCESSING'
  ) then
    raise exception 'Raw iPos rows can be inserted only into a processing batch';
  end if;
  new.created_at := now();
  return new;
end;
$$;
revoke all on function public.guard_ipos_raw_row_insert() from public, anon, authenticated;

create trigger ipos_import_batches_source_immutable
  before update on public.ipos_import_batches
  for each row execute function public.guard_ipos_batch_source_immutability();
create trigger ipos_import_rows_source_immutable
  before update on public.ipos_import_rows
  for each row execute function public.guard_ipos_raw_row_immutability();
create trigger ipos_import_rows_processing_only
  before insert on public.ipos_import_rows
  for each row execute function public.guard_ipos_raw_row_insert();

alter table public.products
  add constraint products_created_import_row_fk
    foreign key (created_from_import_row_id) references public.ipos_import_rows(id) on delete restrict deferrable initially deferred,
  add constraint products_last_import_row_fk
    foreign key (last_import_row_id) references public.ipos_import_rows(id) on delete restrict deferrable initially deferred;

create table public.product_barcodes (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete restrict,
  barcode text collate "C" not null,
  is_active boolean not null default true,
  source_import_row_id uuid references public.ipos_import_rows(id) on delete restrict,
  created_by uuid not null references auth.users(id) on delete restrict,
  updated_by uuid not null references auth.users(id) on delete restrict,
  deactivated_at timestamptz,
  deactivated_by uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint product_barcodes_nonblank check (btrim(barcode) <> ''),
  constraint product_barcodes_no_controls check (barcode !~ '[[:cntrl:]]'),
  constraint product_barcodes_deactivation_consistent check (
    (is_active and deactivated_at is null and deactivated_by is null)
    or (not is_active and deactivated_at is not null and deactivated_by is not null)
  )
);
alter table public.product_barcodes add constraint product_barcodes_id_product_unique unique (id, product_id);
create unique index product_barcodes_active_product_value_unique
  on public.product_barcodes (product_id, barcode) where is_active;

create table public.product_outlet_settings (
  product_id uuid not null references public.products(id) on delete restrict,
  outlet_id uuid not null references public.outlets(id) on delete restrict,
  rack_label text,
  source_import_row_id uuid references public.ipos_import_rows(id) on delete restrict,
  created_by uuid not null references auth.users(id) on delete restrict,
  updated_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (product_id, outlet_id)
);

create table public.product_inventory (
  product_id uuid not null references public.products(id) on delete restrict,
  outlet_id uuid not null references public.outlets(id) on delete restrict,
  quantity numeric,
  minimum_quantity numeric,
  source_import_row_id uuid references public.ipos_import_rows(id) on delete restrict,
  created_by uuid not null references auth.users(id) on delete restrict,
  updated_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (product_id, outlet_id),
  constraint product_inventory_quantity_nonnegative check (quantity is null or (quantity >= 0 and quantity < 100000000000 and quantity = trunc(quantity, 3))),
  constraint product_inventory_minimum_nonnegative check (minimum_quantity is null or (minimum_quantity >= 0 and minimum_quantity < 100000000000 and minimum_quantity = trunc(minimum_quantity, 3)))
);

create table public.product_selling_prices (
  product_id uuid not null references public.products(id) on delete restrict,
  outlet_id uuid not null references public.outlets(id) on delete restrict,
  amount numeric,
  source_import_row_id uuid references public.ipos_import_rows(id) on delete restrict,
  created_by uuid not null references auth.users(id) on delete restrict,
  updated_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (product_id, outlet_id),
  constraint product_selling_prices_nonnegative check (amount is null or (amount >= 0 and amount < 1000000000000 and amount = trunc(amount, 2)))
);

create table public.product_costs (
  product_id uuid not null references public.products(id) on delete restrict,
  outlet_id uuid not null references public.outlets(id) on delete restrict,
  hpp numeric,
  source_import_row_id uuid references public.ipos_import_rows(id) on delete restrict,
  created_by uuid not null references auth.users(id) on delete restrict,
  updated_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (product_id, outlet_id),
  constraint product_costs_nonnegative check (hpp is null or (hpp >= 0 and hpp < 1000000000000 and hpp = trunc(hpp, 2)))
);

create table public.product_selling_price_history (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete restrict,
  outlet_id uuid not null references public.outlets(id) on delete restrict,
  amount numeric,
  effective_at timestamptz not null default now(),
  source_import_row_id uuid references public.ipos_import_rows(id) on delete restrict,
  changed_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint selling_price_history_nonnegative check (amount is null or (amount >= 0 and amount < 1000000000000 and amount = trunc(amount, 2)))
);

create table public.product_cost_history (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete restrict,
  outlet_id uuid not null references public.outlets(id) on delete restrict,
  hpp numeric,
  effective_at timestamptz not null default now(),
  source_import_row_id uuid references public.ipos_import_rows(id) on delete restrict,
  changed_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint product_cost_history_nonnegative check (hpp is null or (hpp >= 0 and hpp < 1000000000000 and hpp = trunc(hpp, 2)))
);

create table public.product_inventory_history (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete restrict,
  outlet_id uuid not null references public.outlets(id) on delete restrict,
  quantity numeric,
  minimum_quantity numeric,
  effective_at timestamptz not null default now(),
  source_import_row_id uuid references public.ipos_import_rows(id) on delete restrict,
  changed_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint inventory_history_quantity_nonnegative check (quantity is null or (quantity >= 0 and quantity < 100000000000 and quantity = trunc(quantity, 3))),
  constraint inventory_history_minimum_nonnegative check (minimum_quantity is null or (minimum_quantity >= 0 and minimum_quantity < 100000000000 and minimum_quantity = trunc(minimum_quantity, 3)))
);

create table public.product_audit_findings (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete restrict,
  outlet_id uuid not null references public.outlets(id) on delete restrict,
  batch_id uuid not null references public.ipos_import_batches(id) on delete restrict,
  import_row_id uuid not null references public.ipos_import_rows(id) on delete restrict,
  finding_code public.product_audit_finding_code not null,
  status public.product_audit_finding_status not null default 'OPEN',
  detected_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references auth.users(id) on delete restrict,
  resolution_batch_id uuid references public.ipos_import_batches(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint product_audit_finding_snapshot_unique unique (import_row_id, finding_code),
  constraint product_audit_finding_resolution_consistent check (
    (status = 'OPEN' and resolved_at is null and resolved_by is null and resolution_batch_id is null)
    or (status = 'RESOLVED' and resolved_at is not null and resolved_by is not null)
  )
);
alter table public.product_audit_findings
  add constraint product_findings_batch_outlet_fk
    foreign key (batch_id, outlet_id) references public.ipos_import_batches(id, outlet_id) on delete restrict,
  add constraint product_findings_resolution_batch_outlet_fk
    foreign key (resolution_batch_id, outlet_id) references public.ipos_import_batches(id, outlet_id) on delete restrict,
  add constraint product_findings_row_snapshot_fk
    foreign key (import_row_id, batch_id, outlet_id, product_id)
    references public.ipos_import_rows(id, batch_id, outlet_id, product_id) on delete restrict;

create table public.product_field_audit_reviews (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete restrict,
  outlet_id uuid references public.outlets(id) on delete restrict,
  field_key text collate "C" not null,
  status public.product_field_audit_status not null default 'BELUM_DICEK',
  source_import_row_id uuid references public.ipos_import_rows(id) on delete restrict,
  reviewer_id uuid not null references auth.users(id) on delete restrict,
  reviewed_at timestamptz not null default now(),
  evidence_notes text,
  created_at timestamptz not null default now(),
  constraint product_field_audit_field_known check (field_key in (
    'sku', 'barcode', 'name', 'category_label', 'brand_label', 'unit_label',
    'department_label', 'source_description', 'source_reference_code',
    'rack_label', 'quantity', 'minimum_quantity', 'selling_price', 'hpp'
  ))
);

create table public.product_field_overrides (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete restrict,
  barcode_id uuid,
  outlet_id uuid references public.outlets(id) on delete restrict,
  field_key text collate "C" not null,
  corrected_value jsonb not null,
  reason text not null,
  source_import_row_id uuid references public.ipos_import_rows(id) on delete restrict,
  corrected_by uuid not null references auth.users(id) on delete restrict,
  corrected_at timestamptz not null default now(),
  is_active boolean not null default true,
  deactivated_at timestamptz,
  deactivated_by uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint product_field_overrides_field_known check (field_key in (
    'barcode', 'name', 'category_label', 'brand_label', 'unit_label',
    'department_label', 'source_description', 'source_reference_code',
    'rack_label', 'quantity', 'minimum_quantity', 'selling_price', 'hpp'
  )),
  constraint product_field_overrides_reason_nonblank check (btrim(reason) <> ''),
  constraint product_field_overrides_value_json_type check (
    case
      when field_key in ('quantity', 'minimum_quantity', 'selling_price', 'hpp')
        then jsonb_typeof(corrected_value) = 'number'
          and (corrected_value #>> '{}')::numeric >= 0
          and (corrected_value #>> '{}')::numeric < case
            when field_key in ('quantity', 'minimum_quantity') then 100000000000::numeric
            else 1000000000000::numeric end
          and (corrected_value #>> '{}')::numeric = trunc(
            (corrected_value #>> '{}')::numeric,
            case when field_key in ('quantity', 'minimum_quantity') then 3 else 2 end
          )
      when field_key in ('barcode', 'name', 'category_label', 'brand_label', 'unit_label',
        'department_label', 'source_description', 'source_reference_code', 'rack_label')
        then jsonb_typeof(corrected_value) = 'string'
          and (field_key not in ('barcode', 'name', 'rack_label') or btrim(corrected_value #>> '{}') <> '')
          and (field_key <> 'barcode' or (corrected_value #>> '{}') !~ '[[:cntrl:]]')
      else false
    end
  ),
  constraint product_field_overrides_scope_valid check (
    (field_key = 'barcode' and barcode_id is not null and outlet_id is null)
    or (field_key in ('name', 'category_label', 'brand_label', 'unit_label',
      'department_label', 'source_description', 'source_reference_code') and barcode_id is null and outlet_id is null)
    or (field_key in ('rack_label', 'quantity', 'minimum_quantity', 'selling_price', 'hpp') and barcode_id is null and outlet_id is not null)
  ),
  constraint product_field_overrides_deactivation_consistent check (
    (is_active and deactivated_at is null and deactivated_by is null)
    or (not is_active and deactivated_at is not null and deactivated_by is not null)
  )
);

alter table public.product_outlet_settings
  add constraint product_settings_source_consistent_fk
    foreign key (source_import_row_id, product_id, outlet_id)
    references public.ipos_import_rows(id, product_id, outlet_id) on delete restrict;
alter table public.product_inventory
  add constraint product_inventory_source_consistent_fk
    foreign key (source_import_row_id, product_id, outlet_id)
    references public.ipos_import_rows(id, product_id, outlet_id) on delete restrict;
alter table public.product_selling_prices
  add constraint product_prices_source_consistent_fk
    foreign key (source_import_row_id, product_id, outlet_id)
    references public.ipos_import_rows(id, product_id, outlet_id) on delete restrict;
alter table public.product_costs
  add constraint product_costs_source_consistent_fk
    foreign key (source_import_row_id, product_id, outlet_id)
    references public.ipos_import_rows(id, product_id, outlet_id) on delete restrict;
alter table public.product_selling_price_history
  add constraint selling_price_history_source_consistent_fk
    foreign key (source_import_row_id, product_id, outlet_id)
    references public.ipos_import_rows(id, product_id, outlet_id) on delete restrict;
alter table public.product_cost_history
  add constraint product_cost_history_source_consistent_fk
    foreign key (source_import_row_id, product_id, outlet_id)
    references public.ipos_import_rows(id, product_id, outlet_id) on delete restrict;
alter table public.product_inventory_history
  add constraint product_inventory_history_source_consistent_fk
    foreign key (source_import_row_id, product_id, outlet_id)
    references public.ipos_import_rows(id, product_id, outlet_id) on delete restrict;
alter table public.product_barcodes
  add constraint product_barcodes_source_product_fk
    foreign key (source_import_row_id, product_id)
    references public.ipos_import_rows(id, product_id) on delete restrict;
alter table public.product_field_audit_reviews
  add constraint field_reviews_source_product_fk
    foreign key (source_import_row_id, product_id)
    references public.ipos_import_rows(id, product_id) on delete restrict,
  add constraint field_reviews_source_outlet_fk
    foreign key (source_import_row_id, product_id, outlet_id)
    references public.ipos_import_rows(id, product_id, outlet_id) on delete restrict;

create unique index product_field_overrides_active_outlet_unique
  on public.product_field_overrides (product_id, outlet_id, field_key)
  where is_active and outlet_id is not null;
create unique index product_field_overrides_active_master_unique
  on public.product_field_overrides (product_id, field_key)
  where is_active and outlet_id is null and barcode_id is null;
create unique index product_field_overrides_active_barcode_unique
  on public.product_field_overrides (barcode_id) where is_active and barcode_id is not null;

create or replace function public.guard_product_sku_immutability()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  if new.sku is distinct from old.sku then
    raise exception 'Product SKU is immutable; a re-key requires a dedicated audited workflow';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_product_sku_immutability() from public, anon, authenticated;

create or replace function public.stamp_product_actor()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := coalesce((select auth.uid()), new.created_by);
  else
    new.created_by := old.created_by;
  end if;
  new.updated_by := coalesce((select auth.uid()), new.updated_by);
  return new;
end;
$$;
revoke all on function public.stamp_product_actor() from public, anon, authenticated;

create or replace function public.stamp_barcode_deactivation()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  if old.is_active and not new.is_active then
    new.deactivated_at := now();
    new.deactivated_by := coalesce((select auth.uid()), new.deactivated_by);
  elsif not old.is_active and new.is_active then
    new.deactivated_at := null;
    new.deactivated_by := null;
  end if;
  return new;
end;
$$;
revoke all on function public.stamp_barcode_deactivation() from public, anon, authenticated;

create or replace function public.stamp_import_uploader()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  if new.status <> 'UPLOADED' or new.started_at is not null or new.completed_at is not null then
    raise exception 'New iPos batches must start UPLOADED without lifecycle timestamps';
  end if;
  new.created_at := now();
  new.updated_at := now();
  if new.request_id is not null then
    select r.requested_by into new.imported_by
    from public.ipos_import_requests r where r.id = new.request_id;
  else
    new.imported_by := coalesce((select auth.uid()), new.imported_by);
  end if;
  return new;
end;
$$;
revoke all on function public.stamp_import_uploader() from public, anon, authenticated;

create or replace function public.guard_resolution_actor()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  if old.status = 'RESOLVED' then
    if new.status is distinct from old.status
      or new.resolved_at is distinct from old.resolved_at
      or new.resolved_by is distinct from old.resolved_by
      or new.resolution_batch_id is distinct from old.resolution_batch_id
    then
      raise exception 'Resolved audit findings are immutable';
    end if;
  elsif new.status = 'RESOLVED' then
    new.resolved_at := now();
    new.resolved_by := coalesce((select auth.uid()), new.resolved_by);
  elsif new.resolved_at is distinct from old.resolved_at
    or new.resolved_by is distinct from old.resolved_by
    or new.resolution_batch_id is distinct from old.resolution_batch_id then
    raise exception 'Audit finding resolution metadata is system managed';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_resolution_actor() from public, anon, authenticated;

create or replace function public.guard_new_audit_finding()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  if new.status <> 'OPEN'
    or new.resolved_at is not null
    or new.resolved_by is not null
    or new.resolution_batch_id is not null
  then
    raise exception 'New audit findings must start OPEN without resolution metadata';
  end if;
  new.detected_at := now();
  new.created_at := now();
  new.updated_at := now();
  return new;
end;
$$;
revoke all on function public.guard_new_audit_finding() from public, anon, authenticated;

create or replace function public.stamp_override_actor()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  if tg_op = 'INSERT' then
    new.corrected_by := coalesce((select auth.uid()), new.corrected_by);
    new.corrected_at := now();
  else
    new.deactivated_by := coalesce((select auth.uid()), new.deactivated_by);
    new.deactivated_at := now();
  end if;
  return new;
end;
$$;
revoke all on function public.stamp_override_actor() from public, anon, authenticated;

create or replace function public.guard_audit_finding_history()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  if new.product_id is distinct from old.product_id
    or new.outlet_id is distinct from old.outlet_id
    or new.batch_id is distinct from old.batch_id
    or new.import_row_id is distinct from old.import_row_id
    or new.finding_code is distinct from old.finding_code
    or new.detected_at is distinct from old.detected_at
    or new.created_at is distinct from old.created_at
    or (old.status = 'RESOLVED' and new.status <> old.status)
  then
    raise exception 'Audit finding snapshot identity/history is immutable';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_audit_finding_history() from public, anon, authenticated;

create or replace function public.guard_field_override_history()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  if new.product_id is distinct from old.product_id
    or new.barcode_id is distinct from old.barcode_id
    or new.outlet_id is distinct from old.outlet_id
    or new.field_key is distinct from old.field_key
    or new.corrected_value is distinct from old.corrected_value
    or new.reason is distinct from old.reason
    or new.source_import_row_id is distinct from old.source_import_row_id
    or new.corrected_by is distinct from old.corrected_by
    or new.corrected_at is distinct from old.corrected_at
    or new.created_at is distinct from old.created_at
    or not old.is_active
    or new.is_active
    or new.deactivated_at is null
    or new.deactivated_by is null
  then
    raise exception 'Field correction history is immutable; only explicit deactivation is allowed';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_field_override_history() from public, anon, authenticated;

create or replace function public.guard_product_active_override()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
declare
  override_row record;
  value_key text;
begin
  for override_row in
    select field_key, corrected_value
    from public.product_field_overrides
    where product_id = coalesce(
        (to_jsonb(new) -> case when tg_table_name = 'products' then 'id' else 'product_id' end) #>> '{}',
        ''
      )::uuid
      and is_active
      and (outlet_id is null or outlet_id = ((to_jsonb(new) -> 'outlet_id') #>> '{}')::uuid)
      and (field_key <> 'barcode' or (tg_table_name = 'product_barcodes'
        and barcode_id = ((to_jsonb(new) -> 'id') #>> '{}')::uuid))
  loop
    value_key := case when override_row.field_key = 'selling_price' then 'amount' else override_row.field_key end;
    if override_row.field_key = 'barcode'
      and new.is_active is distinct from old.is_active then
      raise exception 'Deactivate the active barcode correction before changing barcode activity';
    end if;
    if (to_jsonb(new) -> value_key) is distinct from (to_jsonb(old) -> value_key)
      and (to_jsonb(new) -> value_key) is distinct from override_row.corrected_value then
      raise exception 'An active manual correction cannot be overwritten';
    end if;
  end loop;
  return new;
end;
$$;
revoke all on function public.guard_product_active_override() from public, anon, authenticated;

create or replace function public.guard_override_matches_current_value()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  current_value jsonb;
begin
  if new.field_key = 'barcode' then
    select to_jsonb(b) -> 'barcode' into current_value
    from public.product_barcodes b
    where b.id = new.barcode_id and b.product_id = new.product_id and b.is_active;
  elsif new.outlet_id is null then
    select to_jsonb(p) -> new.field_key into current_value
    from public.products p where p.id = new.product_id;
  elsif new.field_key = 'rack_label' then
    select to_jsonb(s) -> 'rack_label' into current_value
    from public.product_outlet_settings s where s.product_id = new.product_id and s.outlet_id = new.outlet_id;
  elsif new.field_key in ('quantity', 'minimum_quantity') then
    select to_jsonb(i) -> new.field_key into current_value
    from public.product_inventory i where i.product_id = new.product_id and i.outlet_id = new.outlet_id;
  elsif new.field_key = 'selling_price' then
    select to_jsonb(p) -> 'amount' into current_value
    from public.product_selling_prices p where p.product_id = new.product_id and p.outlet_id = new.outlet_id;
  elsif new.field_key = 'hpp' then
    select to_jsonb(c) -> 'hpp' into current_value
    from public.product_costs c where c.product_id = new.product_id and c.outlet_id = new.outlet_id;
  end if;
  if current_value is distinct from new.corrected_value then
    raise exception 'Apply the corrected value to its normalized field before recording the override';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_override_matches_current_value() from public, anon, authenticated;
create trigger override_value_consistency before insert on public.product_field_overrides
  for each row execute function public.guard_override_matches_current_value();

create trigger products_active_override_guard before update on public.products
  for each row execute function public.guard_product_active_override();
create trigger barcodes_active_override_guard before update on public.product_barcodes
  for each row execute function public.guard_product_active_override();
create trigger product_settings_active_override_guard before update on public.product_outlet_settings
  for each row execute function public.guard_product_active_override();
create trigger product_inventory_active_override_guard before update on public.product_inventory
  for each row execute function public.guard_product_active_override();
create trigger product_prices_active_override_guard before update on public.product_selling_prices
  for each row execute function public.guard_product_active_override();
create trigger product_costs_active_override_guard before update on public.product_costs
  for each row execute function public.guard_product_active_override();

alter table public.products
  add constraint products_created_row_product_fk
    foreign key (created_from_import_row_id, id)
    references public.ipos_import_rows(id, product_id) on delete restrict deferrable initially deferred,
  add constraint products_last_row_product_fk
    foreign key (last_import_row_id, id)
    references public.ipos_import_rows(id, product_id) on delete restrict deferrable initially deferred;
alter table public.product_field_overrides
  add constraint overrides_source_product_outlet_fk
    foreign key (source_import_row_id, product_id, outlet_id)
    references public.ipos_import_rows(id, product_id, outlet_id) on delete restrict,
  add constraint overrides_source_product_fk
    foreign key (source_import_row_id, product_id)
    references public.ipos_import_rows(id, product_id) on delete restrict,
  add constraint overrides_barcode_product_fk
    foreign key (barcode_id, product_id)
    references public.product_barcodes(id, product_id) on delete restrict;

create index ipos_import_batches_outlet_created_idx on public.ipos_import_batches (outlet_id, created_at desc);
create index ipos_import_batches_status_created_idx on public.ipos_import_batches (status, created_at desc);
create index ipos_import_rows_product_idx on public.ipos_import_rows (product_id) where product_id is not null;
create index ipos_import_rows_batch_status_idx on public.ipos_import_rows (batch_id, status);
create index products_created_import_row_idx on public.products (created_from_import_row_id) where created_from_import_row_id is not null;
create index products_last_import_row_idx on public.products (last_import_row_id) where last_import_row_id is not null;
create index product_barcodes_barcode_idx on public.product_barcodes (barcode) where is_active;
create index product_barcodes_source_row_idx on public.product_barcodes (source_import_row_id) where source_import_row_id is not null;
create index products_name_normalized_idx on public.products (public.normalize_product_name(name));
create index products_category_idx on public.products (category_label);
create index products_brand_idx on public.products (brand_label);
create index product_outlet_settings_outlet_rack_idx on public.product_outlet_settings (outlet_id, rack_label);
create index product_outlet_settings_source_row_idx on public.product_outlet_settings (source_import_row_id) where source_import_row_id is not null;
create index product_inventory_outlet_idx on public.product_inventory (outlet_id, product_id);
create index product_inventory_source_row_idx on public.product_inventory (source_import_row_id) where source_import_row_id is not null;
create index product_selling_prices_outlet_idx on public.product_selling_prices (outlet_id, product_id);
create index product_selling_prices_source_row_idx on public.product_selling_prices (source_import_row_id) where source_import_row_id is not null;
create index product_costs_outlet_idx on public.product_costs (outlet_id, product_id);
create index product_costs_source_row_idx on public.product_costs (source_import_row_id) where source_import_row_id is not null;
create index selling_price_history_product_time_idx on public.product_selling_price_history (product_id, outlet_id, effective_at desc);
create index product_cost_history_product_time_idx on public.product_cost_history (product_id, outlet_id, effective_at desc);
create index product_inventory_history_product_time_idx on public.product_inventory_history (product_id, outlet_id, effective_at desc);
create index product_audit_findings_open_idx on public.product_audit_findings (outlet_id, finding_code, product_id) where status = 'OPEN';
create index product_audit_findings_product_time_idx on public.product_audit_findings (product_id, detected_at desc);
create index product_audit_findings_batch_idx on public.product_audit_findings (batch_id);
create index product_field_reviews_latest_idx on public.product_field_audit_reviews (product_id, field_key, reviewed_at desc);
create index product_field_reviews_source_row_idx on public.product_field_audit_reviews (source_import_row_id) where source_import_row_id is not null;
create index product_field_overrides_lookup_idx on public.product_field_overrides (product_id, field_key) where is_active;

create index ipos_import_requests_state_idx on public.ipos_import_requests (state, created_at);

create or replace function public.capture_ipos_value_history()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  actor_id uuid := coalesce(auth.uid(), new.updated_by);
  source_id uuid := new.source_import_row_id;
begin
  if tg_table_name = 'product_selling_prices' then
    if tg_op = 'INSERT' or new.amount is distinct from old.amount then
      insert into public.product_selling_price_history
        (product_id, outlet_id, amount, source_import_row_id, changed_by)
      values (new.product_id, new.outlet_id, new.amount, source_id, actor_id);
    end if;
  elsif tg_table_name = 'product_costs' then
    if tg_op = 'INSERT' or new.hpp is distinct from old.hpp then
      insert into public.product_cost_history
        (product_id, outlet_id, hpp, source_import_row_id, changed_by)
      values (new.product_id, new.outlet_id, new.hpp, source_id, actor_id);
    end if;
  elsif tg_table_name = 'product_inventory' then
    if tg_op = 'INSERT' or new.quantity is distinct from old.quantity
      or new.minimum_quantity is distinct from old.minimum_quantity then
      insert into public.product_inventory_history
        (product_id, outlet_id, quantity, minimum_quantity, source_import_row_id, changed_by)
      values (new.product_id, new.outlet_id, new.quantity, new.minimum_quantity, source_id, actor_id);
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.capture_ipos_value_history() from public, anon, authenticated;

create or replace function public.reject_ipos_history_mutation()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  raise exception 'iPos history is append-only';
end;
$$;
revoke all on function public.reject_ipos_history_mutation() from public, anon, authenticated;

create trigger product_prices_capture_history after insert or update on public.product_selling_prices
  for each row execute function public.capture_ipos_value_history();
create trigger product_costs_capture_history after insert or update on public.product_costs
  for each row execute function public.capture_ipos_value_history();
create trigger product_inventory_capture_history after insert or update on public.product_inventory
  for each row execute function public.capture_ipos_value_history();
create trigger selling_price_history_immutable before update or delete on public.product_selling_price_history
  for each row execute function public.reject_ipos_history_mutation();
create trigger cost_history_immutable before update or delete on public.product_cost_history
  for each row execute function public.reject_ipos_history_mutation();
create trigger inventory_history_immutable before update or delete on public.product_inventory_history
  for each row execute function public.reject_ipos_history_mutation();

create or replace function public.request_ipos_import(p_outlet_id uuid, p_storage_path text)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  caller_id uuid := auth.uid();
  request_id uuid := gen_random_uuid();
  role_value public.user_role;
begin
  role_value := public.current_active_user_role();
  if caller_id is null or role_value is null
    or role_value not in ('OWNER'::public.user_role, 'ADMIN'::public.user_role, 'GUDANG'::public.user_role) then
    raise exception 'Not authorized to request an iPos import';
  end if;
  if p_storage_path !~ ('^incoming/' || caller_id::text || '/[0-9a-fA-F-]{36}\.xlsx$') then
    raise exception 'Invalid iPos upload path';
  end if;
  if not exists (select 1 from public.outlets where id = p_outlet_id and is_active) then
    raise exception 'Unknown or inactive outlet';
  end if;
  if not exists (
    select 1 from storage.objects
    where bucket_id = 'quena-ipos-imports' and name = p_storage_path
  ) then
    raise exception 'Uploaded iPos workbook not found';
  end if;
  insert into public.ipos_import_requests (id, outlet_id, requested_by, storage_path)
  values (request_id, p_outlet_id, caller_id, p_storage_path);
  return request_id;
end;
$$;
revoke all on function public.request_ipos_import(uuid, text) from public, anon;
grant execute on function public.request_ipos_import(uuid, text) to authenticated;

create trigger outlets_updated_at before update on public.outlets
  for each row execute function public.quena_ipos_set_updated_at();
create trigger batches_updated_at before update on public.ipos_import_batches
  for each row execute function public.quena_ipos_set_updated_at();
create trigger requests_updated_at before update on public.ipos_import_requests
  for each row execute function public.quena_ipos_set_updated_at();
create trigger products_updated_at before update on public.products
  for each row execute function public.quena_ipos_set_updated_at();
create trigger barcodes_updated_at before update on public.product_barcodes
  for each row execute function public.quena_ipos_set_updated_at();
create trigger settings_updated_at before update on public.product_outlet_settings
  for each row execute function public.quena_ipos_set_updated_at();
create trigger inventory_updated_at before update on public.product_inventory
  for each row execute function public.quena_ipos_set_updated_at();
create trigger selling_prices_updated_at before update on public.product_selling_prices
  for each row execute function public.quena_ipos_set_updated_at();
create trigger costs_updated_at before update on public.product_costs
  for each row execute function public.quena_ipos_set_updated_at();
create trigger findings_updated_at before update on public.product_audit_findings
  for each row execute function public.quena_ipos_set_updated_at();
create trigger overrides_updated_at before update on public.product_field_overrides
  for each row execute function public.quena_ipos_set_updated_at();

create trigger products_actor before insert or update on public.products
  for each row execute function public.stamp_product_actor();
create trigger barcodes_actor before insert or update on public.product_barcodes
  for each row execute function public.stamp_product_actor();
create trigger settings_actor before insert or update on public.product_outlet_settings
  for each row execute function public.stamp_product_actor();
create trigger inventory_actor before insert or update on public.product_inventory
  for each row execute function public.stamp_product_actor();
create trigger selling_prices_actor before insert or update on public.product_selling_prices
  for each row execute function public.stamp_product_actor();
create trigger costs_actor before insert or update on public.product_costs
  for each row execute function public.stamp_product_actor();
create trigger batches_uploader before insert on public.ipos_import_batches
  for each row execute function public.stamp_import_uploader();
create trigger requests_lifecycle_guard before update on public.ipos_import_requests
  for each row execute function public.guard_ipos_request_lifecycle();
create trigger findings_resolution_actor before update on public.product_audit_findings
  for each row execute function public.guard_resolution_actor();
create trigger findings_insert_open_only before insert on public.product_audit_findings
  for each row execute function public.guard_new_audit_finding();
create trigger findings_history_guard before update on public.product_audit_findings
  for each row execute function public.guard_audit_finding_history();
create trigger overrides_history_guard before update on public.product_field_overrides
  for each row execute function public.guard_field_override_history();
create trigger overrides_actor before insert or update on public.product_field_overrides
  for each row execute function public.stamp_override_actor();
create trigger products_sku_immutable before update on public.products
  for each row execute function public.guard_product_sku_immutability();
create trigger barcodes_deactivation before update on public.product_barcodes
  for each row execute function public.stamp_barcode_deactivation();

create trigger import_rows_no_delete before delete on public.ipos_import_rows
  for each row execute function public.reject_ipos_history_mutation();
create trigger import_batches_no_delete before delete on public.ipos_import_batches
  for each row execute function public.reject_ipos_history_mutation();
create trigger audit_findings_no_delete before delete on public.product_audit_findings
  for each row execute function public.reject_ipos_history_mutation();
create trigger field_reviews_no_mutation before update or delete on public.product_field_audit_reviews
  for each row execute function public.reject_ipos_history_mutation();
create trigger overrides_no_delete before delete on public.product_field_overrides
  for each row execute function public.reject_ipos_history_mutation();

alter table public.outlets enable row level security;
alter table public.ipos_import_batches enable row level security;
alter table public.ipos_import_requests enable row level security;
alter table public.ipos_import_rows enable row level security;
alter table public.products enable row level security;
alter table public.product_barcodes enable row level security;
alter table public.product_outlet_settings enable row level security;
alter table public.product_inventory enable row level security;
alter table public.product_selling_prices enable row level security;
alter table public.product_costs enable row level security;
alter table public.product_selling_price_history enable row level security;
alter table public.product_cost_history enable row level security;
alter table public.product_inventory_history enable row level security;
alter table public.product_audit_findings enable row level security;
alter table public.product_field_audit_reviews enable row level security;
alter table public.product_field_overrides enable row level security;

revoke all on public.outlets, public.ipos_import_batches, public.ipos_import_requests,
  public.ipos_import_rows, public.products, public.product_barcodes,
  public.product_outlet_settings, public.product_inventory, public.product_selling_prices,
  public.product_costs, public.product_selling_price_history, public.product_cost_history,
  public.product_inventory_history, public.product_audit_findings,
  public.product_field_audit_reviews, public.product_field_overrides
from public, anon, authenticated;
revoke all on type public.ipos_import_batch_status, public.ipos_import_row_status,
  public.product_audit_finding_code, public.product_audit_finding_status,
  public.product_field_audit_status from public, anon;
grant usage on type public.ipos_import_batch_status, public.ipos_import_row_status,
  public.product_audit_finding_code, public.product_audit_finding_status,
  public.product_field_audit_status to authenticated;

grant select on public.outlets, public.products, public.product_barcodes,
  public.product_outlet_settings, public.product_inventory, public.product_selling_prices,
  public.product_selling_price_history, public.product_inventory_history,
  public.product_audit_findings, public.product_field_audit_reviews,
  public.product_field_overrides, public.ipos_import_requests to authenticated;
grant select on public.ipos_import_batches, public.ipos_import_rows,
  public.product_costs, public.product_cost_history to authenticated;

-- The trusted worker receives only the table privileges its import and review
-- lifecycles require. History is written by SECURITY DEFINER capture triggers.
revoke all on public.outlets, public.ipos_import_batches, public.ipos_import_requests,
  public.ipos_import_rows, public.products, public.product_barcodes,
  public.product_outlet_settings, public.product_inventory, public.product_selling_prices,
  public.product_costs, public.product_selling_price_history, public.product_cost_history,
  public.product_inventory_history, public.product_audit_findings,
  public.product_field_audit_reviews, public.product_field_overrides
from service_role;

grant select on public.outlets, public.product_selling_price_history,
  public.product_cost_history, public.product_inventory_history to service_role;
grant select, update on public.ipos_import_requests to service_role;
grant select, insert, update on public.ipos_import_batches, public.ipos_import_rows,
  public.products, public.product_barcodes, public.product_outlet_settings,
  public.product_inventory, public.product_selling_prices, public.product_costs,
  public.product_audit_findings, public.product_field_overrides to service_role;
grant select, insert on public.product_field_audit_reviews to service_role;
grant usage on type public.ipos_import_batch_status, public.ipos_import_row_status,
  public.product_audit_finding_code, public.product_audit_finding_status,
  public.product_field_audit_status to service_role;

create policy outlets_select_active on public.outlets for select to authenticated
  using (public.current_active_user_role() is not null);
create policy products_select_active on public.products for select to authenticated
  using (public.current_active_user_role() is not null);
create policy barcodes_select_active on public.product_barcodes for select to authenticated
  using (public.current_active_user_role() is not null);
create policy settings_select_stock_roles on public.product_outlet_settings for select to authenticated
  using (public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role, 'GUDANG'::public.user_role));
create policy inventory_select_active on public.product_inventory for select to authenticated
  using (public.current_active_user_role() is not null);
create policy selling_prices_select_active on public.product_selling_prices for select to authenticated
  using (public.current_active_user_role() is not null);
create policy selling_price_history_select_active on public.product_selling_price_history for select to authenticated
  using (public.current_active_user_role() is not null);
create policy inventory_history_select_active on public.product_inventory_history for select to authenticated
  using (public.current_active_user_role() is not null);
create policy findings_select_role_safe on public.product_audit_findings for select to authenticated
  using (
    public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role)
    or (public.current_active_user_role() = 'GUDANG'::public.user_role
      and finding_code not in ('ZERO_OR_MISSING_HPP'::public.product_audit_finding_code,
        'SELLING_PRICE_BELOW_HPP'::public.product_audit_finding_code))
  );
create policy field_reviews_select_role_safe on public.product_field_audit_reviews for select to authenticated
  using (public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role)
    or (public.current_active_user_role() = 'GUDANG'::public.user_role and field_key <> 'hpp'));
create policy overrides_select_role_safe on public.product_field_overrides for select to authenticated
  using (public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role)
    or (public.current_active_user_role() = 'GUDANG'::public.user_role and field_key <> 'hpp'));
create policy import_batches_select_managers on public.ipos_import_batches for select to authenticated
  using (public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role));
create policy import_rows_select_managers on public.ipos_import_rows for select to authenticated
  using (public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role));
create policy costs_select_managers on public.product_costs for select to authenticated
  using (public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role));
create policy cost_history_select_managers on public.product_cost_history for select to authenticated
  using (public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role));
create policy import_requests_select_requester_managers on public.ipos_import_requests for select to authenticated
  using (public.current_active_user_role() is not null
    and (requested_by = (select auth.uid())
      or public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role)));

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'quena-ipos-imports', 'quena-ipos-imports', false, 26214400,
  array['application/vnd.openxmlformats-officedocument.spreadsheetml.sheet']::text[]
)
on conflict (id) do nothing;

do $$
begin
  if not exists (
    select 1 from storage.buckets
    where id = 'quena-ipos-imports'
      and public = false
      and file_size_limit = 26214400
      and allowed_mime_types = array['application/vnd.openxmlformats-officedocument.spreadsheetml.sheet']::text[]
  ) then
    raise exception 'quena-ipos-imports bucket exists with unexpected security settings';
  end if;
end;
$$;

create policy quena_ipos_upload_managers on storage.objects for insert to authenticated
  with check (
    bucket_id = 'quena-ipos-imports'
    and public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role)
    and name ~ '^incoming/[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}\.xlsx$'
  );
create policy quena_ipos_upload_gudang on storage.objects for insert to authenticated
  with check (
    bucket_id = 'quena-ipos-imports'
    and public.current_active_user_role() = 'GUDANG'::public.user_role
    and name ~ ('^incoming/' || (select auth.uid())::text || '/[0-9a-fA-F-]{36}\.xlsx$')
  );
create policy quena_ipos_read_managers on storage.objects for select to authenticated
  using (bucket_id = 'quena-ipos-imports'
    and public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role));

-- Restrictive policies cover both anon and authenticated so unrelated
-- permissive Storage policies cannot widen access to this private bucket.
create policy quena_ipos_select_anon_restrict on storage.objects as restrictive
  for select to anon using (bucket_id <> 'quena-ipos-imports');
create policy quena_ipos_select_authenticated_restrict on storage.objects as restrictive
  for select to authenticated using (bucket_id <> 'quena-ipos-imports'
    or public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role));
create policy quena_ipos_insert_anon_restrict on storage.objects as restrictive
  for insert to anon with check (bucket_id <> 'quena-ipos-imports');
create policy quena_ipos_insert_authenticated_restrict on storage.objects as restrictive
  for insert to authenticated with check (
    bucket_id <> 'quena-ipos-imports'
    or public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role)
    or (public.current_active_user_role() = 'GUDANG'::public.user_role
      and name ~ ('^incoming/' || (select auth.uid())::text || '/[0-9a-fA-F-]{36}\.xlsx$'))
  );
create policy quena_ipos_update_anon_restrict on storage.objects as restrictive
  for update to anon using (bucket_id <> 'quena-ipos-imports')
  with check (bucket_id <> 'quena-ipos-imports');
create policy quena_ipos_update_authenticated_restrict on storage.objects as restrictive
  for update to authenticated using (bucket_id <> 'quena-ipos-imports')
  with check (bucket_id <> 'quena-ipos-imports');
create policy quena_ipos_delete_anon_restrict on storage.objects as restrictive
  for delete to anon using (bucket_id <> 'quena-ipos-imports');
create policy quena_ipos_delete_authenticated_restrict on storage.objects as restrictive
  for delete to authenticated using (bucket_id <> 'quena-ipos-imports');

commit;
