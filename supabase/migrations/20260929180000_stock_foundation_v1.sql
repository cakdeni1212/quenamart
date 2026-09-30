-- Phase 3C.1A: stock balance, movement, and opname database foundation.
-- Additive only. product_inventory remains the normalized iPos snapshot.
-- All operational changes are separate, immutable movements.
begin;

create type public.stock_authority_mode as enum (
  'IPOS_SNAPSHOT_PLUS_QUENA_MOVEMENTS',
  'QUENA_MOVEMENT_LEDGER'
);

create type public.stock_movement_type as enum (
  'OPENING', 'PURCHASE_RECEIPT', 'SALE', 'SALE_RETURN', 'SUPPLIER_RETURN',
  'MANUAL_IN', 'MANUAL_OUT', 'OPNAME_ADJUSTMENT', 'TRANSFER_IN',
  'TRANSFER_OUT', 'REVERSAL'
);

create type public.stock_movement_source as enum (
  'IPOS_IMPORT', 'QUENA_POS', 'PURCHASING', 'STOCK_OPNAME', 'MANUAL', 'TRANSFER'
);

create type public.stock_opname_scope as enum ('FULL', 'PARTIAL');
create type public.stock_opname_status as enum ('COUNTING', 'REVIEW', 'POSTED', 'CANCELLED');
create type public.stock_count_event_type as enum (
  'COUNTED', 'RECOUNTED', 'BASELINE_REFRESHED', 'STALE_BASELINE', 'EXCEPTION_REVIEWED'
);
create type public.stock_opname_event_type as enum (
  'CREATED', 'SUBMITTED_FOR_REVIEW', 'RETURNED_TO_COUNTING', 'POSTED', 'CANCELLED', 'BASELINE_STALE'
);
create type public.stock_request_state as enum ('PENDING', 'COMPLETED', 'STALE', 'SUPERSEDED');

create table public.stock_authority_periods (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references public.outlets(id) on delete restrict,
  mode public.stock_authority_mode not null,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  created_by uuid references auth.users(id) on delete restrict,
  created_reason text not null,
  created_at timestamptz not null default now(),
  constraint stock_authority_period_reason_nonblank check (btrim(created_reason) <> ''),
  constraint stock_authority_period_time_valid check (ended_at is null or ended_at > started_at),
  constraint stock_authority_period_id_outlet_unique unique (id, outlet_id)
);
create unique index stock_authority_one_current_period_per_outlet
  on public.stock_authority_periods(outlet_id) where ended_at is null;

-- V1 product rule: the accepted baseline and Quena effective quantity cannot
-- be negative. Supporting negative imported stock is explicitly out of scope.
-- Baseline values are separate from the immutable import snapshot and from
-- operational movement deltas. effective_quantity is only a projection.
create table public.stock_balance_projection (
  product_id uuid not null references public.products(id) on delete restrict,
  outlet_id uuid not null references public.outlets(id) on delete restrict,
  authority_period_id uuid not null,
  baseline_quantity numeric,
  baseline_source_import_row_id uuid,
  baseline_batch_id uuid,
  baseline_commit_id uuid references public.ipos_normalization_commits(id) on delete restrict,
  unreconciled_movement_delta numeric not null default 0,
  effective_quantity numeric generated always as
    (baseline_quantity + unreconciled_movement_delta) stored,
  balance_version bigint not null default 1,
  last_observation_source_import_row_id uuid,
  last_observation_status text not null default 'BOOTSTRAPPED',
  updated_at timestamptz not null default now(),
  primary key (product_id, outlet_id),
  constraint stock_balance_authority_period_fk
    foreign key (authority_period_id, outlet_id)
    references public.stock_authority_periods(id, outlet_id) on delete restrict,
  constraint stock_balance_baseline_source_fk
    foreign key (baseline_source_import_row_id, baseline_batch_id, outlet_id, product_id)
    references public.ipos_import_rows(id, batch_id, outlet_id, product_id) on delete restrict,
  constraint stock_balance_observation_source_fk
    foreign key (last_observation_source_import_row_id, product_id, outlet_id)
    references public.ipos_import_rows(id, product_id, outlet_id) on delete restrict,
  constraint stock_balance_baseline_identity_consistent check (
    (baseline_quantity is null and baseline_source_import_row_id is null
      and baseline_batch_id is null and baseline_commit_id is null)
    or (baseline_quantity is not null and baseline_source_import_row_id is not null
      and baseline_batch_id is not null and baseline_commit_id is not null)
  ),
  constraint stock_balance_quantity_precision check (
    (baseline_quantity is null or
      (baseline_quantity >= 0 and baseline_quantity < 100000000000
        and baseline_quantity = trunc(baseline_quantity, 3)))
    and unreconciled_movement_delta > -100000000000
    and unreconciled_movement_delta < 100000000000
    and unreconciled_movement_delta = trunc(unreconciled_movement_delta, 3)
    and (effective_quantity is null or
      (effective_quantity >= 0 and effective_quantity < 100000000000
        and effective_quantity = trunc(effective_quantity, 3)))
  ),
  constraint stock_balance_version_positive check (balance_version > 0),
  constraint stock_balance_observation_status_valid check (
    last_observation_status in ('BOOTSTRAPPED', 'INVALID_STOCK_VALUE',
      'ACTIVE_OVERRIDE_BLOCKED', 'SOURCE_CHRONOLOGY_UNVERIFIED',
      'QUENA_AUTHORITY_OBSERVATION')
  )
);
create index stock_balance_outlet_product_idx
  on public.stock_balance_projection(outlet_id, product_id);

-- The per-inventory-row refresh trigger resolves its normalized proposal by
-- raw source row. Keep that lookup indexed as batches grow.
create index ipos_normalization_rows_stock_source_lookup_idx
  on public.ipos_normalization_commit_rows(source_row_id, batch_id, product_id)
  where action in ('CREATE', 'UPDATE');

create table public.stock_balance_baseline_events (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete restrict,
  outlet_id uuid not null references public.outlets(id) on delete restrict,
  source_import_row_id uuid not null,
  batch_id uuid not null,
  normalization_commit_id uuid references public.ipos_normalization_commits(id) on delete restrict,
  event_type text not null check (event_type in (
    'BOOTSTRAP', 'INVALID_STOCK_VALUE',
    'ACTIVE_OVERRIDE_BLOCKED', 'SOURCE_CHRONOLOGY_UNVERIFIED',
    'QUENA_AUTHORITY_OBSERVATION'
  )),
  recorded_at timestamptz not null default now(),
  constraint stock_balance_baseline_event_source_fk
    foreign key (source_import_row_id, batch_id, outlet_id, product_id)
    references public.ipos_import_rows(id, batch_id, outlet_id, product_id) on delete restrict,
  constraint stock_balance_baseline_event_once unique (source_import_row_id, event_type)
);
create index stock_balance_baseline_events_product_time_idx
  on public.stock_balance_baseline_events(product_id, outlet_id, recorded_at desc);

create table public.stock_operation_requests (
  request_id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references auth.users(id) on delete restrict,
  operation_key text not null,
  target_key text not null,
  request_payload jsonb not null check (jsonb_typeof(request_payload) = 'object'),
  payload_hash text not null,
  state public.stock_request_state not null default 'PENDING',
  result jsonb,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint stock_operation_request_hash_valid check (payload_hash ~ '^[0-9a-f]{32}$'),
  constraint stock_operation_request_state_consistent check (
    (state = 'PENDING' and result is null and completed_at is null)
    or (state <> 'PENDING' and result is not null and completed_at is not null)
  )
);
create unique index stock_operation_one_pending_intent_per_target
  on public.stock_operation_requests(actor_id, operation_key, target_key)
  where state = 'PENDING';
create index stock_operation_request_actor_recent_idx
  on public.stock_operation_requests(actor_id, created_at desc);

create table public.stock_opname_sessions (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references public.outlets(id) on delete restrict,
  scope_type public.stock_opname_scope not null,
  status public.stock_opname_status not null default 'COUNTING',
  note text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  started_at timestamptz not null default now(),
  submitted_by uuid references auth.users(id) on delete restrict,
  submitted_at timestamptz,
  approved_by uuid references auth.users(id) on delete restrict,
  approved_at timestamptz,
  posted_at timestamptz,
  cancelled_by uuid references auth.users(id) on delete restrict,
  cancelled_at timestamptz,
  constraint stock_opname_note_nonblank check (note is null or btrim(note) <> ''),
  constraint stock_opname_lifecycle_valid check (
    (status = 'COUNTING' and submitted_at is null and approved_at is null and posted_at is null and cancelled_at is null)
    or (status = 'REVIEW' and submitted_at is not null and approved_at is null and posted_at is null and cancelled_at is null)
    or (status = 'POSTED' and submitted_at is not null and approved_at is not null and posted_at is not null and cancelled_at is null)
    or (status = 'CANCELLED' and posted_at is null and cancelled_at is not null and cancelled_by is not null)
  ),
  constraint stock_opname_id_outlet_unique unique (id, outlet_id)
);
create index stock_opname_outlet_status_created_idx
  on public.stock_opname_sessions(outlet_id, status, created_at desc);

create table public.stock_opname_items (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null,
  outlet_id uuid not null,
  product_id uuid not null references public.products(id) on delete restrict,
  baseline_quantity numeric,
  baseline_source_import_row_id uuid,
  baseline_balance_version bigint,
  physical_quantity numeric,
  quantity_variance numeric generated always as
    (physical_quantity - baseline_quantity) stored,
  scanned_barcode_id uuid,
  revision_no integer not null default 0,
  requires_recount boolean not null default false,
  exception_reason text,
  exception_reviewed_by uuid references auth.users(id) on delete restrict,
  exception_reviewed_at timestamptz,
  last_counted_by uuid references auth.users(id) on delete restrict,
  last_counted_at timestamptz,
  active_scope boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint stock_opname_item_session_outlet_fk
    foreign key (session_id, outlet_id)
    references public.stock_opname_sessions(id, outlet_id) on delete restrict,
  constraint stock_opname_item_baseline_fk
    foreign key (baseline_source_import_row_id, product_id, outlet_id)
    references public.ipos_import_rows(id, product_id, outlet_id) on delete restrict,
  constraint stock_opname_item_barcode_product_fk
    foreign key (scanned_barcode_id, product_id)
    references public.product_barcodes(id, product_id) on delete restrict,
  constraint stock_opname_item_unique_product unique (session_id, product_id),
  constraint stock_opname_item_id_product_outlet_unique unique (id, product_id, outlet_id),
  constraint stock_opname_item_quantity_valid check (
    (baseline_quantity is null or
      (baseline_quantity >= 0 and baseline_quantity < 100000000000
        and baseline_quantity = trunc(baseline_quantity, 3)))
    and (physical_quantity is null or
      (physical_quantity >= 0 and physical_quantity < 100000000000
        and physical_quantity = trunc(physical_quantity, 3)))
    and (quantity_variance is null or
      (quantity_variance > -100000000000 and quantity_variance < 100000000000
        and quantity_variance = trunc(quantity_variance, 3)))
  ),
  constraint stock_opname_item_baseline_pair check (
    (baseline_quantity is null and baseline_source_import_row_id is null and baseline_balance_version is null)
    or (baseline_quantity is not null and baseline_source_import_row_id is not null and baseline_balance_version is not null)
  ),
  constraint stock_opname_item_exception_consistent check (
    (exception_reason is null and exception_reviewed_by is null and exception_reviewed_at is null)
    or (exception_reason is not null and btrim(exception_reason) <> ''
      and exception_reviewed_by is not null and exception_reviewed_at is not null)
  ),
  constraint stock_opname_item_count_actor_consistent check (
    (physical_quantity is null and last_counted_by is null and last_counted_at is null)
    or (physical_quantity is not null and last_counted_by is not null and last_counted_at is not null)
  ),
  constraint stock_opname_item_revision_nonnegative check (revision_no >= 0)
);
create unique index stock_opname_no_active_overlap
  on public.stock_opname_items(outlet_id, product_id) where active_scope;
create index stock_opname_items_session_idx
  on public.stock_opname_items(session_id, product_id);

create table public.stock_opname_count_events (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.stock_opname_items(id) on delete restrict,
  request_id uuid references public.stock_operation_requests(request_id) on delete restrict,
  event_type public.stock_count_event_type not null,
  revision_no integer not null,
  baseline_quantity numeric,
  baseline_balance_version bigint,
  physical_quantity numeric,
  barcode_id uuid,
  actor_id uuid not null references auth.users(id) on delete restrict,
  note text,
  created_at timestamptz not null default now(),
  constraint stock_opname_count_event_revision_positive check (revision_no > 0),
  constraint stock_opname_count_event_quantity_valid check (
    (baseline_quantity is null or
      (baseline_quantity >= 0 and baseline_quantity < 100000000000
        and baseline_quantity = trunc(baseline_quantity, 3)))
    and (physical_quantity is null or
      (physical_quantity >= 0 and physical_quantity < 100000000000
        and physical_quantity = trunc(physical_quantity, 3)))
  ),
  constraint stock_opname_count_event_barcode_fk
    foreign key (barcode_id) references public.product_barcodes(id) on delete restrict,
  constraint stock_opname_count_event_request_unique unique (request_id)
);
create index stock_opname_count_events_item_time_idx
  on public.stock_opname_count_events(item_id, created_at desc, id desc);

create table public.stock_opname_session_events (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.stock_opname_sessions(id) on delete restrict,
  event_type public.stock_opname_event_type not null,
  previous_status public.stock_opname_status,
  next_status public.stock_opname_status not null,
  actor_id uuid not null references auth.users(id) on delete restrict,
  request_id uuid references public.stock_operation_requests(request_id) on delete restrict,
  note text,
  created_at timestamptz not null default now(),
  constraint stock_opname_session_event_request_unique unique (request_id)
);
create index stock_opname_session_events_session_time_idx
  on public.stock_opname_session_events(session_id, created_at desc, id desc);

create table public.stock_movement_batches (
  id uuid primary key default gen_random_uuid(),
  authority_period_id uuid not null references public.stock_authority_periods(id) on delete restrict,
  outlet_id uuid not null references public.outlets(id) on delete restrict,
  source_system public.stock_movement_source not null,
  operation_request_id uuid not null unique references public.stock_operation_requests(request_id) on delete restrict,
  created_by uuid not null references auth.users(id) on delete restrict,
  posted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint stock_movement_batch_period_outlet_fk
    foreign key (authority_period_id, outlet_id)
    references public.stock_authority_periods(id, outlet_id) on delete restrict,
  constraint stock_movement_batch_id_outlet_unique unique (id, outlet_id, authority_period_id),
  constraint stock_movement_batch_source_context_unique unique (id, outlet_id, authority_period_id, source_system)
);

create table public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null,
  authority_period_id uuid not null,
  outlet_id uuid not null,
  product_id uuid not null references public.products(id) on delete restrict,
  movement_type public.stock_movement_type not null,
  source_system public.stock_movement_source not null,
  quantity_delta numeric not null,
  balance_before numeric not null,
  balance_after numeric not null,
  source_import_row_id uuid,
  opname_item_id uuid,
  source_reference text,
  source_event_key text,
  reverses_movement_id uuid references public.stock_movements(id) on delete restrict,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint stock_movement_batch_fk
    foreign key (batch_id, outlet_id, authority_period_id, source_system)
    references public.stock_movement_batches(id, outlet_id, authority_period_id, source_system) on delete restrict,
  constraint stock_movement_opname_item_fk
    foreign key (opname_item_id, product_id, outlet_id)
    references public.stock_opname_items(id, product_id, outlet_id) on delete restrict,
  constraint stock_movement_source_row_fk
    foreign key (source_import_row_id, product_id, outlet_id)
    references public.ipos_import_rows(id, product_id, outlet_id) on delete restrict,
  constraint stock_movement_id_product_outlet_unique unique (id, product_id, outlet_id),
  constraint stock_movement_delta_signed_nonzero check (
    quantity_delta <> 0 and quantity_delta > -100000000000
    and quantity_delta < 100000000000 and quantity_delta = trunc(quantity_delta, 3)
  ),
  constraint stock_movement_balance_valid check (
    balance_before >= 0 and balance_before < 100000000000
    and balance_after >= 0 and balance_after < 100000000000
    and balance_before = trunc(balance_before, 3)
    and balance_after = trunc(balance_after, 3)
    and balance_after = balance_before + quantity_delta
  ),
  constraint stock_movement_source_event_nonblank check (
    source_event_key is null or btrim(source_event_key) <> ''
  ),
  constraint stock_movement_source_reference_nonblank check (
    source_reference is null or btrim(source_reference) <> ''
  ),
  constraint stock_movement_identity_present check (
    (movement_type = 'OPENING' and source_import_row_id is not null)
    or (movement_type <> 'OPENING' and source_event_key is not null)
  ),
  constraint stock_movement_manual_reason_required check (
    movement_type not in ('MANUAL_IN', 'MANUAL_OUT', 'REVERSAL')
    or source_reference is not null
  ),
  constraint stock_movement_reason_source_valid check (
    (movement_type = 'OPENING' and source_system = 'IPOS_IMPORT' and source_import_row_id is not null)
    or (movement_type = 'PURCHASE_RECEIPT' and source_system = 'PURCHASING')
    or (movement_type = 'SALE' and source_system = 'QUENA_POS')
    or (movement_type = 'SALE_RETURN' and source_system = 'QUENA_POS')
    or (movement_type = 'SUPPLIER_RETURN' and source_system = 'PURCHASING')
    or (movement_type in ('MANUAL_IN', 'MANUAL_OUT') and source_system = 'MANUAL')
    or (movement_type = 'OPNAME_ADJUSTMENT' and source_system = 'STOCK_OPNAME' and opname_item_id is not null)
    or (movement_type in ('TRANSFER_IN', 'TRANSFER_OUT') and source_system = 'TRANSFER')
    or (movement_type = 'REVERSAL' and reverses_movement_id is not null)
  ),
  constraint stock_movement_sign_valid check (
    (movement_type in ('OPENING', 'PURCHASE_RECEIPT', 'SALE_RETURN', 'MANUAL_IN', 'TRANSFER_IN')
      and quantity_delta > 0)
    or (movement_type in ('SALE', 'SUPPLIER_RETURN', 'MANUAL_OUT', 'TRANSFER_OUT')
      and quantity_delta < 0)
    or movement_type in ('OPNAME_ADJUSTMENT', 'REVERSAL')
  ),
  constraint stock_movement_reversal_shape check (
    (movement_type = 'REVERSAL' and reverses_movement_id is not null)
    or (movement_type <> 'REVERSAL' and reverses_movement_id is null)
  ),
  constraint stock_movement_opname_shape check (
    (movement_type = 'OPNAME_ADJUSTMENT' and opname_item_id is not null)
    or (movement_type <> 'OPNAME_ADJUSTMENT' and opname_item_id is null)
  )
);
create unique index stock_movement_one_reversal_per_original
  on public.stock_movements(reverses_movement_id) where reverses_movement_id is not null;
create unique index stock_movement_source_event_once
  on public.stock_movements(source_system, source_event_key) where source_event_key is not null;
create index stock_movements_product_time_idx
  on public.stock_movements(outlet_id, product_id, created_at desc, id desc);
create index stock_movements_batch_idx on public.stock_movements(batch_id);

create or replace function public.validate_stock_movement_reversal()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare v_original_delta numeric; v_original_type public.stock_movement_type;
begin
  if new.movement_type = 'REVERSAL'::public.stock_movement_type then
    select m.quantity_delta, m.movement_type into v_original_delta, v_original_type
    from public.stock_movements m
    where m.id = new.reverses_movement_id
      and m.product_id = new.product_id and m.outlet_id = new.outlet_id;
    if not found or v_original_type = 'REVERSAL'::public.stock_movement_type
      or new.quantity_delta <> -v_original_delta
      or new.source_system <> 'MANUAL'::public.stock_movement_source
      or new.source_reference is null or btrim(new.source_reference) = '' then
      raise exception using errcode = '22023', message = 'Reversal must exactly negate its original movement and include a reason';
    end if;
  end if;
  return new;
end;
$$;
alter function public.validate_stock_movement_reversal() owner to postgres;
revoke all on function public.validate_stock_movement_reversal() from public, anon, authenticated, service_role;
create trigger stock_movement_validate_reversal before insert on public.stock_movements
  for each row execute function public.validate_stock_movement_reversal();

create table public.stock_movement_source_reconciliations (
  id uuid primary key default gen_random_uuid(),
  movement_id uuid not null,
  reconciliation_group_id uuid not null references public.stock_movements(id) on delete restrict,
  product_id uuid not null,
  outlet_id uuid not null,
  source_import_row_id uuid not null,
  batch_id uuid not null,
  confirmed_by uuid not null references auth.users(id) on delete restrict,
  reason text not null,
  request_id uuid not null references public.stock_operation_requests(request_id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint stock_movement_reconciliation_movement_fk
    foreign key (movement_id, product_id, outlet_id)
    references public.stock_movements(id, product_id, outlet_id) on delete restrict,
  constraint stock_movement_reconciliation_source_fk
    foreign key (source_import_row_id, batch_id, outlet_id, product_id)
    references public.ipos_import_rows(id, batch_id, outlet_id, product_id) on delete restrict,
  constraint stock_movement_reconciliation_reason_nonblank check (btrim(reason) <> ''),
  constraint stock_movement_reconciled_once unique (movement_id),
  constraint stock_movement_reconciliation_request_member_unique unique (request_id, movement_id),
  constraint stock_movement_reconciliation_group_member_unique unique (reconciliation_group_id, movement_id)
);
create index stock_movement_reconciliation_snapshot_idx
  on public.stock_movement_source_reconciliations(source_import_row_id, created_at desc);

-- Initial import baseline is inserted only when every existing normalized
-- inventory row has a valid, completed normalization source and no legacy
-- stock overrides. The compatibility check is repeated at migration time.
do $$
begin
  if exists (
    select 1 from public.product_field_overrides o
    where o.is_active and o.field_key = 'quantity'
  ) then
    raise exception 'Stock foundation backfill blocked: active quantity overrides require manual review';
  end if;
  if exists (
    select 1 from public.product_inventory i
    where i.quantity is null or i.source_import_row_id is null
      or not exists (
        select 1
        from public.ipos_import_rows r
        join public.ipos_import_batches b
          on b.id = r.batch_id and b.outlet_id = r.outlet_id and b.status = 'COMPLETED'
        join public.ipos_normalization_commit_rows cr
          on cr.source_row_id = r.id and cr.batch_id = r.batch_id
         and cr.product_id = i.product_id and cr.action in ('CREATE', 'UPDATE')
         and case jsonb_typeof(cr.normalized_data->'quantity')
           when 'number' then (cr.normalized_data->>'quantity')::numeric = i.quantity
           when 'string' then case
             when cr.normalized_data->>'quantity' ~ '^-?[0-9]+([.][0-9]+)?$'
               then (cr.normalized_data->>'quantity')::numeric = i.quantity
             else false
           end
           else false
         end
         and not exists (
           select 1 from pg_catalog.jsonb_array_elements(cr.validation_errors) e(value)
           where e.value->>'code' = 'INVALID_NUMERIC_VALUE' and e.value->>'field' = 'STOK'
         )
        join public.ipos_normalization_commits nc
          on nc.id = cr.commit_id and nc.batch_id = r.batch_id
         and nc.outlet_id = r.outlet_id and nc.status = 'COMPLETED'
        where r.id = i.source_import_row_id and r.product_id = i.product_id
          and r.outlet_id = i.outlet_id and r.status = 'VALID'
      )
  ) then
    raise exception 'Stock foundation backfill blocked: inventory row lacks a valid completed source baseline';
  end if;
end;
$$;

insert into public.stock_authority_periods (outlet_id, mode, created_reason)
select o.id, 'IPOS_SNAPSHOT_PLUS_QUENA_MOVEMENTS'::public.stock_authority_mode,
  'Phase 3C.1A initial transitional stock authority period'
from public.outlets o
where exists (select 1 from public.product_inventory i where i.outlet_id = o.id);

insert into public.stock_balance_projection (
  product_id, outlet_id, authority_period_id, baseline_quantity,
  baseline_source_import_row_id, baseline_batch_id, baseline_commit_id,
  unreconciled_movement_delta, balance_version,
  last_observation_source_import_row_id, last_observation_status
)
select i.product_id, i.outlet_id, ap.id, i.quantity, r.id, r.batch_id,
  nc.id, 0, 1, r.id, 'BOOTSTRAPPED'
from public.product_inventory i
join public.stock_authority_periods ap on ap.outlet_id = i.outlet_id and ap.ended_at is null
join public.ipos_import_rows r
  on r.id = i.source_import_row_id and r.product_id = i.product_id and r.outlet_id = i.outlet_id
join public.ipos_import_batches b
  on b.id = r.batch_id and b.outlet_id = r.outlet_id and b.status = 'COMPLETED'
join public.ipos_normalization_commit_rows cr
  on cr.source_row_id = r.id and cr.batch_id = r.batch_id
 and cr.product_id = i.product_id and cr.action in ('CREATE', 'UPDATE')
 and case jsonb_typeof(cr.normalized_data->'quantity')
   when 'number' then (cr.normalized_data->>'quantity')::numeric = i.quantity
   when 'string' then case
     when cr.normalized_data->>'quantity' ~ '^-?[0-9]+([.][0-9]+)?$'
       then (cr.normalized_data->>'quantity')::numeric = i.quantity
     else false
   end
   else false
 end
 and not exists (
   select 1 from pg_catalog.jsonb_array_elements(cr.validation_errors) e(value)
   where e.value->>'code' = 'INVALID_NUMERIC_VALUE' and e.value->>'field' = 'STOK'
 )
join public.ipos_normalization_commits nc
  on nc.id = cr.commit_id and nc.batch_id = r.batch_id
 and nc.outlet_id = r.outlet_id and nc.status = 'COMPLETED'
where i.quantity is not null
on conflict (product_id, outlet_id) do nothing;

insert into public.stock_balance_baseline_events (
  product_id, outlet_id, source_import_row_id, batch_id,
  normalization_commit_id, event_type
)
select p.product_id, p.outlet_id, p.baseline_source_import_row_id,
  p.baseline_batch_id, p.baseline_commit_id, 'BOOTSTRAP'
from public.stock_balance_projection p
on conflict (source_import_row_id, event_type) do nothing;

create table public.stock_balance_projection_events (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null,
  outlet_id uuid not null,
  authority_period_id uuid not null,
  event_type text not null check (event_type in (
    'MOVEMENT_POSTED', 'MOVEMENT_RECONCILED', 'AUTHORITY_BASELINE_ACCEPTED'
  )),
  request_id uuid references public.stock_operation_requests(request_id) on delete restrict,
  quantity_delta numeric not null,
  balance_before numeric not null,
  balance_after numeric not null,
  balance_version bigint not null,
  actor_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint stock_balance_projection_event_product_fk
    foreign key (product_id, outlet_id)
    references public.stock_balance_projection(product_id, outlet_id) on delete restrict,
  constraint stock_balance_projection_event_period_fk
    foreign key (authority_period_id, outlet_id)
    references public.stock_authority_periods(id, outlet_id) on delete restrict,
  constraint stock_balance_projection_event_quantity_valid check (
    quantity_delta > -100000000000 and quantity_delta < 100000000000
    and quantity_delta = trunc(quantity_delta, 3)
    and balance_before >= 0 and balance_after >= 0
    and balance_before < 100000000000 and balance_after < 100000000000
    and balance_before = trunc(balance_before, 3)
    and balance_after = trunc(balance_after, 3)
  )
);
create unique index stock_balance_projection_request_event_once
  on public.stock_balance_projection_events(request_id, event_type, product_id)
  where request_id is not null;
create index stock_balance_projection_events_product_time_idx
  on public.stock_balance_projection_events(outlet_id, product_id, created_at desc);

-- Record import observations without accepting them as stock baselines.
-- Neither upload time nor batch identity establishes workbook chronology.
-- Phase 2B links the raw row before its product_inventory upsert; the proposal
-- exists while the normalization commit is PROCESSING.
create or replace function public.refresh_stock_balance_from_ipos_inventory()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_batch_id uuid;
  v_commit_id uuid;
  v_normalized_data jsonb;
  v_validation_errors jsonb;
  v_projection public.stock_balance_projection%rowtype;
  v_period_id uuid;
  v_period_mode public.stock_authority_mode;
  v_event_type text;
begin
  if new.source_import_row_id is null then
    raise exception 'Stock baseline refresh requires an iPos source row';
  end if;

  select r.batch_id, nc.id, cr.normalized_data, cr.validation_errors
    into v_batch_id, v_commit_id, v_normalized_data, v_validation_errors
  from public.ipos_import_rows r
  join public.ipos_import_batches b
    on b.id = r.batch_id and b.outlet_id = r.outlet_id and b.status = 'COMPLETED'
  join public.ipos_normalization_commit_rows cr
    on cr.source_row_id = r.id and cr.batch_id = r.batch_id
   and cr.product_id = new.product_id and cr.action in ('CREATE', 'UPDATE')
  join public.ipos_normalization_commits nc
    on nc.id = cr.commit_id and nc.batch_id = r.batch_id
   and nc.outlet_id = r.outlet_id and nc.status in ('PROCESSING', 'COMPLETED')
  where r.id = new.source_import_row_id and r.product_id = new.product_id
    and r.outlet_id = new.outlet_id and r.status = 'VALID'
  order by nc.started_at desc, nc.id desc
  limit 1
  ;
  if not found then
    raise exception 'Stock baseline refresh has no valid normalization proposal';
  end if;

  select ap.id, ap.mode into v_period_id, v_period_mode
  from public.stock_authority_periods ap
  where ap.outlet_id = new.outlet_id and ap.ended_at is null
  ;
  if not found then
    insert into public.stock_authority_periods(outlet_id, mode, created_reason)
    values (new.outlet_id, 'IPOS_SNAPSHOT_PLUS_QUENA_MOVEMENTS'::public.stock_authority_mode,
      'Initial transitional period created by trusted iPos normalization')
    on conflict do nothing;
    select ap.id, ap.mode into v_period_id, v_period_mode
    from public.stock_authority_periods ap
    where ap.outlet_id = new.outlet_id and ap.ended_at is null
    ;
    if not found then raise exception 'Stock authority period is missing'; end if;
  end if;

  select * into v_projection
  from public.stock_balance_projection p
  where p.product_id = new.product_id and p.outlet_id = new.outlet_id
  for update;

  if exists (
    select 1 from public.product_field_overrides o
    where o.product_id = new.product_id and o.outlet_id = new.outlet_id
      and o.field_key = 'quantity' and o.is_active
  ) then
    v_event_type := 'ACTIVE_OVERRIDE_BLOCKED';
  elsif exists (
    select 1 from pg_catalog.jsonb_array_elements(coalesce(v_validation_errors, '[]'::jsonb)) as x(value)
    where x.value->>'code' = 'INVALID_NUMERIC_VALUE' and x.value->>'field' = 'STOK'
  ) or (
    (jsonb_typeof(v_normalized_data->'quantity') is distinct from 'number'
      and jsonb_typeof(v_normalized_data->'quantity') is distinct from 'string')
    or (jsonb_typeof(v_normalized_data->'quantity') = 'string'
      and coalesce(v_normalized_data->>'quantity' !~ '^-?[0-9]+([.][0-9]+)?$', true))
  ) then
    v_event_type := 'INVALID_STOCK_VALUE';
  elsif v_period_mode = 'QUENA_MOVEMENT_LEDGER'::public.stock_authority_mode then
    v_event_type := 'QUENA_AUTHORITY_OBSERVATION';
  else
    v_event_type := 'SOURCE_CHRONOLOGY_UNVERIFIED';
  end if;

  insert into public.stock_balance_baseline_events (
    product_id, outlet_id, source_import_row_id, batch_id,
    normalization_commit_id, event_type
  ) values (
    new.product_id, new.outlet_id, new.source_import_row_id, v_batch_id,
    v_commit_id, v_event_type
  ) on conflict (source_import_row_id, event_type) do nothing;

  if v_projection.product_id is null then
    insert into public.stock_balance_projection (
      product_id, outlet_id, authority_period_id, unreconciled_movement_delta,
      balance_version, last_observation_source_import_row_id, last_observation_status
    ) values (
      new.product_id, new.outlet_id, v_period_id, 0, 1,
      new.source_import_row_id, v_event_type
    );
  else
    update public.stock_balance_projection p
    set last_observation_source_import_row_id = new.source_import_row_id,
        last_observation_status = v_event_type,
        updated_at = now()
    where p.product_id = new.product_id and p.outlet_id = new.outlet_id;
  end if;
  return new;
end;
$$;
alter function public.refresh_stock_balance_from_ipos_inventory() owner to postgres;
revoke all on function public.refresh_stock_balance_from_ipos_inventory()
  from public, anon, authenticated, service_role;
create trigger product_inventory_refresh_stock_projection_insert
  after insert on public.product_inventory
  for each row execute function public.refresh_stock_balance_from_ipos_inventory();
create trigger product_inventory_refresh_stock_projection_source_update
  after update of source_import_row_id on public.product_inventory
  for each row execute function public.refresh_stock_balance_from_ipos_inventory();

create or replace function public.reject_stock_ledger_mutation()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  raise exception 'Final stock history is append-only; use a reversal movement';
end;
$$;
alter function public.reject_stock_ledger_mutation() owner to postgres;
revoke all on function public.reject_stock_ledger_mutation() from public, anon, authenticated, service_role;

create trigger stock_movement_batches_immutable before update or delete on public.stock_movement_batches
  for each row execute function public.reject_stock_ledger_mutation();
create trigger stock_movements_immutable before update or delete on public.stock_movements
  for each row execute function public.reject_stock_ledger_mutation();
create trigger stock_reconciliations_immutable before update or delete on public.stock_movement_source_reconciliations
  for each row execute function public.reject_stock_ledger_mutation();
create trigger stock_baseline_events_immutable before update or delete on public.stock_balance_baseline_events
  for each row execute function public.reject_stock_ledger_mutation();
create trigger stock_projection_events_immutable before update or delete on public.stock_balance_projection_events
  for each row execute function public.reject_stock_ledger_mutation();
create trigger stock_count_events_immutable before update or delete on public.stock_opname_count_events
  for each row execute function public.reject_stock_ledger_mutation();
create trigger stock_session_events_immutable before update or delete on public.stock_opname_session_events
  for each row execute function public.reject_stock_ledger_mutation();

create or replace function public.guard_posted_stock_opname()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  if old.status in ('POSTED'::public.stock_opname_status, 'CANCELLED'::public.stock_opname_status)
    and (to_jsonb(new) - 'updated_at') is distinct from (to_jsonb(old) - 'updated_at') then
    raise exception 'Posted or cancelled stock-opname sessions are immutable';
  end if;
  if new.id is distinct from old.id or new.outlet_id is distinct from old.outlet_id
    or new.scope_type is distinct from old.scope_type
    or new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at then
    raise exception 'Stock-opname session identity is immutable';
  end if;
  return new;
end;
$$;
alter function public.guard_posted_stock_opname() owner to postgres;
revoke all on function public.guard_posted_stock_opname() from public, anon, authenticated, service_role;
create trigger stock_opname_session_guard before update on public.stock_opname_sessions
  for each row execute function public.guard_posted_stock_opname();

create or replace function public.guard_posted_stock_opname_item()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  if exists (
    select 1 from public.stock_opname_sessions s
    where s.id = old.session_id and s.status in ('POSTED'::public.stock_opname_status, 'CANCELLED'::public.stock_opname_status)
  ) then
    raise exception 'Items in posted or cancelled stock-opname sessions are immutable';
  end if;
  if tg_op = 'DELETE' then
    raise exception 'Stock-opname item history cannot be deleted';
  end if;
  if new.id is distinct from old.id or new.session_id is distinct from old.session_id
    or new.outlet_id is distinct from old.outlet_id or new.product_id is distinct from old.product_id
    or new.created_at is distinct from old.created_at then
    raise exception 'Stock-opname item identity is immutable';
  end if;
  return new;
end;
$$;
alter function public.guard_posted_stock_opname_item() owner to postgres;
revoke all on function public.guard_posted_stock_opname_item() from public, anon, authenticated, service_role;
create trigger stock_opname_item_guard before update or delete on public.stock_opname_items
  for each row execute function public.guard_posted_stock_opname_item();

-- One internal primitive for all future stock writers. It changes only the
-- derived projection; its caller inserts the immutable movement in the same
-- transaction. Row locks, not the global iPos lock, serialize product/outlet writes.
create or replace function public.stock_apply_balance_delta(
  p_product_id uuid, p_outlet_id uuid, p_delta numeric
)
returns table (balance_before numeric, balance_after numeric, new_balance_version bigint)
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare v_projection public.stock_balance_projection%rowtype;
begin
  if p_delta is null or p_delta = 0 or p_delta <> trunc(p_delta, 3)
    or p_delta <= -100000000000 or p_delta >= 100000000000 then
    raise exception using errcode = '22023', message = 'Invalid stock movement quantity';
  end if;
  select * into v_projection
  from public.stock_balance_projection p
  where p.product_id = p_product_id and p.outlet_id = p_outlet_id
  for update;
  if not found or v_projection.effective_quantity is null then
    raise exception using errcode = '22023', message = 'Stock baseline is unavailable';
  end if;
  if v_projection.effective_quantity + p_delta < 0 then
    raise exception using errcode = '22023', message = 'Stock movement would make effective stock negative';
  end if;
  if v_projection.effective_quantity + p_delta >= 100000000000 then
    raise exception using errcode = '22023', message = 'Stock movement exceeds the supported range';
  end if;
  update public.stock_balance_projection p
  set unreconciled_movement_delta = p.unreconciled_movement_delta + p_delta,
      balance_version = p.balance_version + 1,
      updated_at = now()
  where p.product_id = p_product_id and p.outlet_id = p_outlet_id;
  return query select v_projection.effective_quantity,
    v_projection.effective_quantity + p_delta, v_projection.balance_version + 1;
end;
$$;
alter function public.stock_apply_balance_delta(uuid,uuid,numeric) owner to postgres;
revoke all on function public.stock_apply_balance_delta(uuid,uuid,numeric)
  from public, anon, authenticated, service_role;

create or replace function public.stock_opname_content_hash(p_session_id uuid)
returns text
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select md5(coalesce(string_agg(
    i.product_id::text || ':' || coalesce(i.baseline_balance_version::text, 'NULL') || ':'
    || coalesce(trim_scale(i.baseline_quantity)::text, 'NULL') || ':'
    || coalesce(trim_scale(i.physical_quantity)::text, 'NULL') || ':'
    || i.revision_no::text || ':' || i.requires_recount::text || ':'
    || coalesce(i.exception_reason, ''), '|'
    order by i.product_id
  ), ''))
  from public.stock_opname_items i
  where i.session_id = p_session_id
$$;
alter function public.stock_opname_content_hash(uuid) owner to postgres;
revoke all on function public.stock_opname_content_hash(uuid) from public, anon, authenticated, service_role;

-- Database-generated durable operation IDs. One pending request per actor,
-- operation, and semantic target; changed payload supersedes the old pending ID.
create or replace function public.issue_stock_operation_intent(
  p_operation_key text,
  p_payload jsonb
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor uuid := auth.uid();
  v_role public.user_role;
  v_payload jsonb;
  v_target text;
  v_hash text;
  v_existing public.stock_operation_requests%rowtype;
  v_request_id uuid;
  v_session uuid;
  v_product uuid;
  v_outlet uuid;
  v_qty numeric;
  v_note text;
  v_products uuid[];
begin
  if v_actor is null then raise exception using errcode = '42501', message = 'Authentication required'; end if;
  v_role := public.current_active_user_role();
  if v_role is null or v_role = 'KASIR'::public.user_role then
    raise exception using errcode = '42501', message = 'Stock access denied';
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception using errcode = '22023', message = 'Stock operation payload must be an object';
  end if;

  if p_operation_key = 'CREATE_SESSION' then
    v_outlet := (p_payload->>'outlet_id')::uuid;
    if v_outlet is null or p_payload->>'scope_type' is null
      or p_payload->>'scope_type' not in ('FULL', 'PARTIAL') then
      raise exception using errcode = '22023', message = 'Invalid stock-opname scope';
    end if;
    if coalesce(jsonb_typeof(p_payload->'product_ids'), 'array') <> 'array' then
      raise exception using errcode = '22023', message = 'Product list must be an array';
    end if;
    select coalesce(array_agg(distinct x.value::uuid order by x.value::uuid), '{}'::uuid[])
      into v_products
    from jsonb_array_elements_text(coalesce(p_payload->'product_ids', '[]'::jsonb)) x(value);
    if p_payload->>'scope_type' = 'FULL' and cardinality(v_products) <> 0 then
      raise exception using errcode = '22023', message = 'FULL scope is selected by the database';
    end if;
    if p_payload->>'scope_type' = 'PARTIAL' and cardinality(v_products) = 0 then
      raise exception using errcode = '22023', message = 'PARTIAL scope requires products';
    end if;
    v_note := nullif(btrim(p_payload->>'note'), '');
    v_payload := jsonb_build_object('outlet_id', v_outlet,
      'scope_type', p_payload->>'scope_type', 'product_ids', to_jsonb(v_products), 'note', v_note);
    v_target := v_outlet::text;
  elsif p_operation_key in ('SUBMIT_REVIEW', 'RETURN_TO_COUNTING', 'CANCEL_SESSION', 'POST_SESSION') then
    v_session := (p_payload->>'session_id')::uuid;
    if v_session is null then raise exception using errcode = '22023', message = 'Session is required'; end if;
    if p_operation_key = 'POST_SESSION' and v_role = 'GUDANG'::public.user_role then
      raise exception using errcode = '42501', message = 'Stock approval permission denied';
    end if;
    if p_operation_key = 'POST_SESSION' then
      v_payload := jsonb_build_object('session_id', v_session,
        'content_hash', public.stock_opname_content_hash(v_session));
    else
      v_payload := jsonb_build_object('session_id', v_session);
    end if;
    v_target := v_session::text;
  elsif p_operation_key in ('RECORD_COUNT', 'REBASE_ITEM', 'REVIEW_EXCEPTION') then
    v_session := (p_payload->>'session_id')::uuid;
    v_product := (p_payload->>'product_id')::uuid;
    if v_session is null or v_product is null then
      raise exception using errcode = '22023', message = 'Session and product are required';
    end if;
    if p_operation_key = 'RECORD_COUNT' then
      if jsonb_typeof(p_payload->'physical_quantity') is distinct from 'number' then
        raise exception using errcode = '22023', message = 'Physical quantity must be numeric';
      end if;
      v_qty := (p_payload->>'physical_quantity')::numeric;
      if v_qty < 0 or v_qty >= 100000000000 or v_qty <> trunc(v_qty, 3) then
        raise exception using errcode = '22023', message = 'Physical quantity is outside the allowed range or precision';
      end if;
      v_payload := jsonb_build_object('session_id', v_session, 'product_id', v_product,
        'physical_quantity', to_jsonb(trim_scale(v_qty)), 'barcode_id', nullif(p_payload->>'barcode_id', '')::uuid);
    elsif p_operation_key = 'REVIEW_EXCEPTION' then
      v_note := nullif(btrim(p_payload->>'reason'), '');
      if v_note is null then raise exception using errcode = '22023', message = 'Exception reason is required'; end if;
      v_payload := jsonb_build_object('session_id', v_session, 'product_id', v_product, 'reason', v_note);
    else
      v_payload := jsonb_build_object('session_id', v_session, 'product_id', v_product);
    end if;
    v_target := v_session::text || ':' || v_product::text;
  elsif p_operation_key = 'RECONCILE_MOVEMENT' then
    if v_role = 'GUDANG'::public.user_role then
      raise exception using errcode = '42501', message = 'Source reconciliation requires OWNER or ADMIN';
    end if;
    v_product := (p_payload->>'movement_id')::uuid;
    v_session := (p_payload->>'source_import_row_id')::uuid;
    v_note := nullif(btrim(p_payload->>'reason'), '');
    if v_product is null or v_session is null or v_note is null then
      raise exception using errcode = '22023', message = 'Movement, source row, and reconciliation reason are required';
    end if;
    v_payload := jsonb_build_object('movement_id', v_product,
      'source_import_row_id', v_session, 'reason', v_note);
    v_target := v_product::text;
  elsif p_operation_key = 'REVERSE_MOVEMENT' then
    if v_role = 'GUDANG'::public.user_role then
      raise exception using errcode = '42501', message = 'Movement reversal requires OWNER or ADMIN';
    end if;
    v_product := (p_payload->>'movement_id')::uuid;
    v_note := nullif(btrim(p_payload->>'reason'), '');
    if v_product is null or v_note is null then
      raise exception using errcode = '22023', message = 'Movement and reversal reason are required';
    end if;
    v_payload := jsonb_build_object('movement_id', v_product, 'reason', v_note);
    v_target := v_product::text;
  else
    raise exception using errcode = '22023', message = 'Unsupported stock operation';
  end if;

  if p_operation_key not in ('CREATE_SESSION', 'RECORD_COUNT', 'REBASE_ITEM',
      'SUBMIT_REVIEW', 'RETURN_TO_COUNTING', 'REVIEW_EXCEPTION', 'CANCEL_SESSION',
      'POST_SESSION', 'RECONCILE_MOVEMENT', 'REVERSE_MOVEMENT') then
    raise exception using errcode = '22023', message = 'Unsupported stock operation';
  end if;
  v_hash := md5(v_payload::text);
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_actor::text || ':' || p_operation_key || ':' || v_target, 73190411)
  );
  select * into v_existing
  from public.stock_operation_requests r
  where r.actor_id = v_actor and r.operation_key = p_operation_key
    and r.target_key = v_target and r.state = 'PENDING'::public.stock_request_state
  for update;
  if found then
    if v_existing.payload_hash = v_hash and v_existing.request_payload = v_payload then
      return v_existing.request_id;
    end if;
    update public.stock_operation_requests
    set state = 'SUPERSEDED'::public.stock_request_state,
        result = jsonb_build_object('ok', false, 'code', 'INTENT_SUPERSEDED'),
        completed_at = now()
    where request_id = v_existing.request_id;
  end if;
  insert into public.stock_operation_requests (
    actor_id, operation_key, target_key, request_payload, payload_hash
  ) values (v_actor, p_operation_key, v_target, v_payload, v_hash)
  returning request_id into v_request_id;
  return v_request_id;
end;
$$;
alter function public.issue_stock_operation_intent(text,jsonb) owner to postgres;
revoke all on function public.issue_stock_operation_intent(text,jsonb) from public, anon, service_role;
grant execute on function public.issue_stock_operation_intent(text,jsonb) to authenticated;

create or replace function public.read_stock_operation_intent(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare v_actor uuid := auth.uid(); v_role public.user_role; v_request public.stock_operation_requests%rowtype;
begin
  if v_actor is null then raise exception using errcode = '42501', message = 'Authentication required'; end if;
  v_role := public.current_active_user_role();
  if v_role is null or v_role = 'KASIR'::public.user_role then
    raise exception using errcode = '42501', message = 'Stock access denied';
  end if;
  select * into v_request from public.stock_operation_requests r
  where r.request_id = p_request_id and r.actor_id = v_actor;
  if not found or (v_role = 'GUDANG'::public.user_role
      and v_request.operation_key in ('POST_SESSION', 'RECONCILE_MOVEMENT', 'REVERSE_MOVEMENT')) then
    return jsonb_build_object('available', false);
  end if;
  return jsonb_build_object('available', true, 'requestId', v_request.request_id,
    'operation', v_request.operation_key, 'state', v_request.state);
end;
$$;
alter function public.read_stock_operation_intent(uuid) owner to postgres;
revoke all on function public.read_stock_operation_intent(uuid) from public, anon, service_role;
grant execute on function public.read_stock_operation_intent(uuid) to authenticated;

create or replace function public.resolve_stock_barcode(p_outlet_id uuid, p_barcode text)
returns table (
  resolution text,
  product_id uuid,
  sku text,
  product_name text,
  rack_label text,
  system_quantity numeric,
  barcode_id uuid
)
language plpgsql
stable
security invoker
set search_path = pg_catalog, public
as $$
declare v_role public.user_role;
begin
  v_role := public.current_active_user_role();
  if v_role is null or v_role not in ('OWNER'::public.user_role, 'ADMIN'::public.user_role, 'GUDANG'::public.user_role) then
    raise exception using errcode = '42501', message = 'Stock access denied';
  end if;
  if p_outlet_id is null or nullif(btrim(p_barcode), '') is null or p_barcode ~ '[[:cntrl:]]' then
    return query select 'BARCODE_NOT_FOUND', null::uuid, null::text, null::text, null::text, null::numeric, null::uuid;
    return;
  end if;
  return query
  with matches as (
    select p.id as product_id, p.sku, p.name as product_name, os.rack_label,
      (array_agg(b.id order by b.id))[1] as barcode_id, bp.effective_quantity
    from public.product_barcodes b
    join public.products p on p.id = b.product_id
    left join public.product_outlet_settings os
      on os.product_id = p.id and os.outlet_id = p_outlet_id
    left join public.stock_balance_projection bp
      on bp.product_id = p.id and bp.outlet_id = p_outlet_id
    where b.is_active and b.barcode = btrim(p_barcode) collate "C"
      and exists (select 1 from public.outlets o where o.id = p_outlet_id and o.is_active)
    group by p.id, p.sku, p.name, os.rack_label, bp.effective_quantity
  ), summary as (
    select count(*)::integer as match_count,
      (array_agg(m.product_id order by m.product_id))[1] as product_id,
      (array_agg(m.sku order by m.product_id))[1] as sku,
      (array_agg(m.product_name order by m.product_id))[1] as product_name,
      (array_agg(m.rack_label order by m.product_id))[1] as rack_label,
      (array_agg(m.effective_quantity order by m.product_id))[1] as system_quantity,
      (array_agg(m.barcode_id order by m.product_id))[1] as barcode_id
    from matches m
  )
  select case when s.match_count = 0 then 'BARCODE_NOT_FOUND'
              when s.match_count = 1 then 'BARCODE_MATCH'
              else 'BARCODE_AMBIGUOUS' end,
    case when s.match_count = 1 then s.product_id end,
    case when s.match_count = 1 then s.sku end,
    case when s.match_count = 1 then s.product_name end,
    case when s.match_count = 1 then s.rack_label end,
    case when s.match_count = 1 then s.system_quantity end,
    case when s.match_count = 1 then s.barcode_id end
  from summary s;
end;
$$;
alter function public.resolve_stock_barcode(uuid,text) owner to postgres;
revoke all on function public.resolve_stock_barcode(uuid,text) from public, anon, service_role;
grant execute on function public.resolve_stock_barcode(uuid,text) to authenticated;

-- Request application performs all writes transactionally. Completed requests
-- replay before current baseline checks; stale requests are terminal and require
-- a newly issued intent after recount/rebase.
create or replace function public.apply_stock_operation_intent(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor uuid := auth.uid();
  v_role public.user_role;
  v_req public.stock_operation_requests%rowtype;
  v_payload jsonb;
  v_session public.stock_opname_sessions%rowtype;
  v_item public.stock_opname_items%rowtype;
  v_projection public.stock_balance_projection%rowtype;
  v_period public.stock_authority_periods%rowtype;
  v_movement public.stock_movements%rowtype;
  v_group_original public.stock_movements%rowtype;
  v_group_reversal public.stock_movements%rowtype;
  v_row record;
  v_session_id uuid;
  v_product_id uuid;
  v_outlet_id uuid;
  v_request uuid;
  v_item_id uuid;
  v_batch_id uuid;
  v_event_id uuid;
  v_group_id uuid;
  v_qty numeric;
  v_delta numeric;
  v_group_delta numeric;
  v_before numeric;
  v_after numeric;
  v_new_version bigint;
  v_hash text;
  v_result jsonb;
  v_stale_count integer;
  v_movement_count integer;
  v_group_count integer;
  v_inserted_count integer;
  v_has_reversal boolean;
  v_revision_no integer;
begin
  if v_actor is null then raise exception using errcode = '42501', message = 'Authentication required'; end if;
  v_role := public.current_active_user_role();
  if v_role is null or v_role = 'KASIR'::public.user_role then
    raise exception using errcode = '42501', message = 'Stock access denied';
  end if;
  select * into v_req from public.stock_operation_requests r
  where r.request_id = p_request_id and r.actor_id = v_actor for update;
  if not found then raise exception using errcode = '42501', message = 'Stock operation unavailable'; end if;
  if v_req.state in ('COMPLETED'::public.stock_request_state, 'STALE'::public.stock_request_state,
      'SUPERSEDED'::public.stock_request_state) then
    if v_role = 'GUDANG'::public.user_role and v_req.operation_key in
      ('POST_SESSION', 'RECONCILE_MOVEMENT', 'REVERSE_MOVEMENT') then
      raise exception using errcode = '42501', message = 'Stock operation unavailable';
    end if;
    return v_req.result;
  end if;
  if v_role = 'GUDANG'::public.user_role and v_req.operation_key in
      ('POST_SESSION', 'RECONCILE_MOVEMENT', 'REVERSE_MOVEMENT') then
    raise exception using errcode = '42501', message = 'Stock operation unavailable';
  end if;
  v_payload := v_req.request_payload;
  v_request := v_req.request_id;

  if v_req.operation_key = 'CREATE_SESSION' then
    v_outlet_id := (v_payload->>'outlet_id')::uuid;
    if not exists (select 1 from public.outlets o where o.id = v_outlet_id and o.is_active) then
      raise exception using errcode = '22023', message = 'Outlet is unavailable';
    end if;
    insert into public.stock_opname_sessions(outlet_id, scope_type, status, note, created_by)
    values (v_outlet_id, (v_payload->>'scope_type')::public.stock_opname_scope,
      'COUNTING'::public.stock_opname_status, v_payload->>'note', v_actor)
    returning id into v_session_id;
    if v_payload->>'scope_type' = 'FULL' then
      -- FULL means all products in the stock projection at the moment the
      -- session is created. Products introduced afterward are outside it.
      if not exists (select 1 from public.stock_balance_projection p where p.outlet_id = v_outlet_id)
        or exists (select 1 from public.stock_balance_projection p
          where p.outlet_id = v_outlet_id and p.effective_quantity is null) then
        raise exception using errcode = '22023', message = 'Full opname requires an available stock baseline for every in-scope product';
      end if;
      insert into public.stock_opname_items(
        session_id, outlet_id, product_id, baseline_quantity,
        baseline_source_import_row_id, baseline_balance_version
      )
      select v_session_id, p.outlet_id, p.product_id, p.effective_quantity,
        p.baseline_source_import_row_id, p.balance_version
      from public.stock_balance_projection p
      where p.outlet_id = v_outlet_id
      order by p.product_id;
    else
      for v_product_id in
        select x.value::uuid from jsonb_array_elements_text(v_payload->'product_ids') x(value)
        order by x.value::uuid
      loop
        select * into v_projection from public.stock_balance_projection p
        where p.product_id = v_product_id and p.outlet_id = v_outlet_id for update;
        if not found or v_projection.effective_quantity is null
          or v_projection.baseline_source_import_row_id is null then
          raise exception using errcode = '22023', message = 'Partial scope contains a product without an available stock baseline';
        end if;
        insert into public.stock_opname_items(
          session_id, outlet_id, product_id, baseline_quantity,
          baseline_source_import_row_id, baseline_balance_version
        ) values (v_session_id, v_outlet_id, v_product_id, v_projection.effective_quantity,
          v_projection.baseline_source_import_row_id, v_projection.balance_version);
      end loop;
    end if;
    insert into public.stock_opname_session_events(
      session_id, event_type, previous_status, next_status, actor_id, request_id, note
    ) values (v_session_id, 'CREATED', null, 'COUNTING', v_actor, v_request, v_payload->>'note');
    v_result := jsonb_build_object('ok', true, 'sessionId', v_session_id, 'status', 'COUNTING');

  elsif v_req.operation_key = 'RECORD_COUNT' then
    v_session_id := (v_payload->>'session_id')::uuid;
    v_product_id := (v_payload->>'product_id')::uuid;
    v_qty := (v_payload->>'physical_quantity')::numeric;
    select * into v_session from public.stock_opname_sessions s where s.id = v_session_id for update;
    if not found or v_session.status <> 'COUNTING'::public.stock_opname_status then
      raise exception using errcode = '22023', message = 'Stock-opname session is not editable';
    end if;
    select * into v_item from public.stock_opname_items i
    where i.session_id = v_session_id and i.product_id = v_product_id for update;
    if not found then raise exception using errcode = '22023', message = 'Product is outside this opname scope'; end if;
    select * into v_projection from public.stock_balance_projection p
    where p.product_id = v_product_id and p.outlet_id = v_item.outlet_id for update;
    if not found or v_item.baseline_balance_version is null
      or v_projection.balance_version <> v_item.baseline_balance_version
      or v_projection.effective_quantity is distinct from v_item.baseline_quantity then
      update public.stock_opname_items set requires_recount = true,
        revision_no = revision_no + 1, updated_at = now()
      where id = v_item.id returning revision_no into v_revision_no;
      insert into public.stock_opname_count_events(
        item_id, request_id, event_type, revision_no, baseline_quantity,
        baseline_balance_version, physical_quantity, barcode_id, actor_id, note
      ) values (v_item.id, v_request, 'STALE_BASELINE', v_revision_no,
        v_item.baseline_quantity, v_item.baseline_balance_version, v_qty,
        nullif(v_payload->>'barcode_id', '')::uuid, v_actor, 'Baseline changed; recount required');
      v_result := jsonb_build_object('ok', false, 'code', 'STALE_BASELINE', 'recountRequired', true);
      update public.stock_operation_requests set state = 'STALE', result = v_result, completed_at = now()
      where request_id = v_request;
      return v_result;
    end if;
    if nullif(v_payload->>'barcode_id', '') is not null and not exists (
      select 1 from public.product_barcodes b where b.id = (v_payload->>'barcode_id')::uuid
        and b.product_id = v_product_id and b.is_active
    ) then raise exception using errcode = '22023', message = 'Scanned barcode is no longer active for this product'; end if;
    v_event_id := gen_random_uuid();
    insert into public.stock_opname_count_events(
      id, item_id, request_id, event_type, revision_no, baseline_quantity,
      baseline_balance_version, physical_quantity, barcode_id, actor_id
    ) values (v_event_id, v_item.id, v_request,
      case when v_item.revision_no = 0 then 'COUNTED'::public.stock_count_event_type
        else 'RECOUNTED'::public.stock_count_event_type end,
      v_item.revision_no + 1, v_item.baseline_quantity, v_item.baseline_balance_version,
      v_qty, nullif(v_payload->>'barcode_id', '')::uuid, v_actor);
    update public.stock_opname_items set physical_quantity = v_qty,
      scanned_barcode_id = nullif(v_payload->>'barcode_id', '')::uuid,
      last_counted_by = v_actor, last_counted_at = now(),
      revision_no = revision_no + 1, requires_recount = false,
      exception_reason = null, exception_reviewed_by = null, exception_reviewed_at = null,
      updated_at = now()
    where id = v_item.id;
    v_result := jsonb_build_object('ok', true, 'itemId', v_item.id,
      'physicalQuantity', v_qty, 'variance', v_qty - v_item.baseline_quantity,
      'revision', v_item.revision_no + 1);

  elsif v_req.operation_key = 'REBASE_ITEM' then
    v_session_id := (v_payload->>'session_id')::uuid;
    v_product_id := (v_payload->>'product_id')::uuid;
    select * into v_session from public.stock_opname_sessions s where s.id = v_session_id for update;
    if not found or v_session.status <> 'COUNTING'::public.stock_opname_status then
      raise exception using errcode = '22023', message = 'Stock-opname session is not editable';
    end if;
    select * into v_item from public.stock_opname_items i
    where i.session_id = v_session_id and i.product_id = v_product_id for update;
    select * into v_projection from public.stock_balance_projection p
    where p.product_id = v_product_id and p.outlet_id = v_item.outlet_id for update;
    if not found or v_projection.effective_quantity is null then
      raise exception using errcode = '22023', message = 'Current stock baseline is unavailable';
    end if;
    update public.stock_opname_items set baseline_quantity = v_projection.effective_quantity,
      baseline_source_import_row_id = v_projection.baseline_source_import_row_id,
      baseline_balance_version = v_projection.balance_version,
      physical_quantity = null, scanned_barcode_id = null, last_counted_by = null,
      last_counted_at = null, requires_recount = false, exception_reason = null,
      exception_reviewed_by = null, exception_reviewed_at = null,
      revision_no = revision_no + 1, updated_at = now()
    where id = v_item.id;
    insert into public.stock_opname_count_events(
      item_id, request_id, event_type, revision_no, baseline_quantity,
      baseline_balance_version, actor_id, note
    ) values (v_item.id, v_request, 'BASELINE_REFRESHED', v_item.revision_no + 1,
      v_projection.effective_quantity, v_projection.balance_version, v_actor,
      'Baseline refreshed; physical recount required');
    v_result := jsonb_build_object('ok', true, 'itemId', v_item.id,
      'recountRequired', true, 'balanceVersion', v_projection.balance_version);

  elsif v_req.operation_key = 'REVIEW_EXCEPTION' then
    v_session_id := (v_payload->>'session_id')::uuid;
    v_product_id := (v_payload->>'product_id')::uuid;
    select * into v_session from public.stock_opname_sessions s where s.id = v_session_id for update;
    if not found or v_session.status <> 'COUNTING'::public.stock_opname_status then
      raise exception using errcode = '22023', message = 'Exception can only be reviewed during counting';
    end if;
    select * into v_item from public.stock_opname_items i
    where i.session_id = v_session_id and i.product_id = v_product_id for update;
    if not found then raise exception using errcode = '22023', message = 'Product is outside this opname scope'; end if;
    select * into v_projection from public.stock_balance_projection p
    where p.product_id = v_product_id and p.outlet_id = v_item.outlet_id for update;
    if not found or v_projection.balance_version <> v_item.baseline_balance_version
      or v_projection.effective_quantity is distinct from v_item.baseline_quantity then
      update public.stock_opname_items set requires_recount = true,
        revision_no = revision_no + 1, updated_at = now() where id = v_item.id;
      insert into public.stock_opname_count_events(
        item_id, request_id, event_type, revision_no, baseline_quantity,
        baseline_balance_version, actor_id, note
      ) values (v_item.id, v_request, 'STALE_BASELINE', v_item.revision_no + 1,
        v_projection.effective_quantity, v_projection.balance_version, v_actor,
        'Baseline berubah; barang harus dihitung ulang sebelum pengecualian ditinjau');
      v_result := jsonb_build_object('ok', false, 'code', 'STALE_BASELINE', 'recountRequired', true);
      update public.stock_operation_requests set state = 'STALE', result = v_result, completed_at = now()
      where request_id = v_request;
      return v_result;
    end if;
    update public.stock_opname_items set exception_reason = v_payload->>'reason',
      exception_reviewed_by = v_actor, exception_reviewed_at = now(),
      physical_quantity = null, last_counted_by = null, last_counted_at = null,
      requires_recount = false, revision_no = revision_no + 1, updated_at = now()
    where id = v_item.id;
    insert into public.stock_opname_count_events(
      item_id, request_id, event_type, revision_no, baseline_quantity,
      baseline_balance_version, actor_id, note
    ) values (v_item.id, v_request, 'EXCEPTION_REVIEWED', v_item.revision_no + 1,
      v_item.baseline_quantity, v_item.baseline_balance_version, v_actor, v_payload->>'reason');
    v_result := jsonb_build_object('ok', true, 'itemId', v_item.id, 'exceptionReviewed', true);

  elsif v_req.operation_key = 'SUBMIT_REVIEW' then
    v_session_id := (v_payload->>'session_id')::uuid;
    select * into v_session from public.stock_opname_sessions s where s.id = v_session_id for update;
    if not found or v_session.status <> 'COUNTING'::public.stock_opname_status then
      raise exception using errcode = '22023', message = 'Stock-opname session is not ready for review';
    end if;
    if exists (
      select 1 from public.stock_opname_items i where i.session_id = v_session_id
        and (i.requires_recount or (i.physical_quantity is null and i.exception_reviewed_at is null))
    ) then raise exception using errcode = '22023', message = 'Every item needs a count or reviewed exception'; end if;
    update public.stock_opname_sessions set status = 'REVIEW', submitted_by = v_actor,
      submitted_at = now() where id = v_session_id;
    insert into public.stock_opname_session_events(
      session_id, event_type, previous_status, next_status, actor_id, request_id
    ) values (v_session_id, 'SUBMITTED_FOR_REVIEW', 'COUNTING', 'REVIEW', v_actor, v_request);
    v_result := jsonb_build_object('ok', true, 'sessionId', v_session_id, 'status', 'REVIEW');

  elsif v_req.operation_key = 'RETURN_TO_COUNTING' then
    v_session_id := (v_payload->>'session_id')::uuid;
    select * into v_session from public.stock_opname_sessions s where s.id = v_session_id for update;
    if not found or v_session.status <> 'REVIEW'::public.stock_opname_status then
      raise exception using errcode = '22023', message = 'Session is not under review';
    end if;
    update public.stock_opname_sessions set status = 'COUNTING', submitted_by = null,
      submitted_at = null where id = v_session_id;
    insert into public.stock_opname_session_events(
      session_id, event_type, previous_status, next_status, actor_id, request_id
    ) values (v_session_id, 'RETURNED_TO_COUNTING', 'REVIEW', 'COUNTING', v_actor, v_request);
    v_result := jsonb_build_object('ok', true, 'sessionId', v_session_id, 'status', 'COUNTING');

  elsif v_req.operation_key = 'CANCEL_SESSION' then
    v_session_id := (v_payload->>'session_id')::uuid;
    select * into v_session from public.stock_opname_sessions s where s.id = v_session_id for update;
    if not found or v_session.status not in ('COUNTING'::public.stock_opname_status, 'REVIEW'::public.stock_opname_status) then
      raise exception using errcode = '22023', message = 'Session cannot be cancelled';
    end if;
    update public.stock_opname_items set active_scope = false, updated_at = now()
    where session_id = v_session_id;
    update public.stock_opname_sessions set status = 'CANCELLED', cancelled_by = v_actor,
      cancelled_at = now() where id = v_session_id;
    insert into public.stock_opname_session_events(
      session_id, event_type, previous_status, next_status, actor_id, request_id
    ) values (v_session_id, 'CANCELLED', v_session.status, 'CANCELLED', v_actor, v_request);
    v_result := jsonb_build_object('ok', true, 'sessionId', v_session_id, 'status', 'CANCELLED');

  elsif v_req.operation_key = 'POST_SESSION' then
    if v_role not in ('OWNER'::public.user_role, 'ADMIN'::public.user_role) then
      raise exception using errcode = '42501', message = 'Stock approval permission denied';
    end if;
    v_session_id := (v_payload->>'session_id')::uuid;
    select * into v_session from public.stock_opname_sessions s where s.id = v_session_id for update;
    if not found or v_session.status <> 'REVIEW'::public.stock_opname_status then
      raise exception using errcode = '22023', message = 'Session is not ready to post';
    end if;
    if public.stock_opname_content_hash(v_session_id) is distinct from v_payload->>'content_hash' then
      v_result := jsonb_build_object('ok', false, 'code', 'SESSION_CHANGED', 'recountRequired', true);
      update public.stock_operation_requests set state = 'STALE', result = v_result, completed_at = now()
      where request_id = v_request;
      return v_result;
    end if;
    v_stale_count := 0;
    for v_row in
      select i.id, i.product_id, i.outlet_id, i.baseline_balance_version,
        i.baseline_quantity, p.effective_quantity, p.balance_version,
        p.authority_period_id
      from public.stock_opname_items i
      left join public.stock_balance_projection p
        on p.product_id = i.product_id and p.outlet_id = i.outlet_id
      where i.session_id = v_session_id
      order by i.product_id
    loop
      select * into v_projection from public.stock_balance_projection p
      where p.product_id = v_row.product_id and p.outlet_id = v_row.outlet_id for update;
      if not found or v_projection.balance_version <> v_row.baseline_balance_version
        or v_projection.effective_quantity is distinct from v_row.baseline_quantity then
        v_stale_count := v_stale_count + 1;
        update public.stock_opname_items set requires_recount = true,
          revision_no = revision_no + 1, updated_at = now()
        where id = v_row.id returning revision_no into v_revision_no;
        insert into public.stock_opname_count_events(
          item_id, event_type, revision_no, baseline_quantity,
          baseline_balance_version, actor_id, note
        ) values (v_row.id, 'STALE_BASELINE', v_revision_no,
          v_row.effective_quantity, v_row.balance_version, v_actor,
          'Stock berubah sejak hitung; hitung ulang diperlukan');
      end if;
    end loop;
    if v_stale_count > 0 then
      update public.stock_opname_sessions set status = 'COUNTING', submitted_by = null,
        submitted_at = null where id = v_session_id;
      insert into public.stock_opname_session_events(
        session_id, event_type, previous_status, next_status, actor_id, request_id,
        note
      ) values (v_session_id, 'BASELINE_STALE', 'REVIEW', 'COUNTING', v_actor,
        v_request, 'Sebagian barang memerlukan hitung ulang');
      v_result := jsonb_build_object('ok', false, 'code', 'STALE_BASELINE',
        'recountRequired', true, 'staleItemCount', v_stale_count);
      update public.stock_operation_requests set state = 'STALE', result = v_result, completed_at = now()
      where request_id = v_request;
      return v_result;
    end if;
    select * into v_period from public.stock_authority_periods ap
    where ap.outlet_id = v_session.outlet_id and ap.ended_at is null for update;
    if not found then raise exception using errcode = '22023', message = 'Stock authority period is unavailable'; end if;
    if exists (
      select 1 from public.stock_opname_items i
      where i.session_id = v_session_id and i.physical_quantity is not null
        and i.physical_quantity <> i.baseline_quantity
    ) then
      insert into public.stock_movement_batches(
        authority_period_id, outlet_id, source_system, operation_request_id, created_by
      ) values (v_period.id, v_session.outlet_id, 'STOCK_OPNAME', v_request, v_actor)
      returning id into v_batch_id;
    end if;
    v_movement_count := 0;
    for v_row in
      select i.id, i.product_id, i.outlet_id, i.baseline_quantity,
        i.physical_quantity, i.exception_reviewed_at
      from public.stock_opname_items i
      where i.session_id = v_session_id
      order by i.product_id
    loop
      if v_row.physical_quantity is null then continue; end if;
      v_delta := v_row.physical_quantity - v_row.baseline_quantity;
      if v_delta = 0 then continue; end if;
      select * into v_projection from public.stock_balance_projection p
      where p.product_id = v_row.product_id and p.outlet_id = v_row.outlet_id for update;
      select d.balance_before, d.balance_after, d.new_balance_version
        into v_before, v_after, v_new_version
      from public.stock_apply_balance_delta(v_row.product_id, v_row.outlet_id, v_delta) d;
      insert into public.stock_movements(
        batch_id, authority_period_id, outlet_id, product_id, movement_type,
        source_system, quantity_delta, balance_before, balance_after,
        opname_item_id, source_reference, source_event_key, created_by
      ) values (v_batch_id, v_period.id, v_row.outlet_id, v_row.product_id,
        'OPNAME_ADJUSTMENT', 'STOCK_OPNAME', v_delta, v_before, v_after,
        v_row.id, v_session_id::text, v_session_id::text || ':' || v_row.id::text, v_actor);
      insert into public.stock_balance_projection_events(
        product_id, outlet_id, authority_period_id, event_type, request_id,
        quantity_delta, balance_before, balance_after, balance_version, actor_id
      ) values (v_row.product_id, v_row.outlet_id, v_period.id, 'MOVEMENT_POSTED',
        v_request, v_delta, v_before, v_after, v_new_version, v_actor);
      v_movement_count := v_movement_count + 1;
    end loop;
    update public.stock_opname_items set active_scope = false, updated_at = now()
    where session_id = v_session_id;
    update public.stock_opname_sessions set status = 'POSTED', approved_by = v_actor,
      approved_at = now(), posted_at = now() where id = v_session_id;
    insert into public.stock_opname_session_events(
      session_id, event_type, previous_status, next_status, actor_id, request_id
    ) values (v_session_id, 'POSTED', 'REVIEW', 'POSTED', v_actor, v_request);
    v_result := jsonb_build_object('ok', true, 'sessionId', v_session_id,
      'movementBatchId', v_batch_id, 'movementCount', v_movement_count, 'status', 'POSTED');

  elsif v_req.operation_key = 'RECONCILE_MOVEMENT' then
    if v_role not in ('OWNER'::public.user_role, 'ADMIN'::public.user_role) then
      raise exception using errcode = '42501', message = 'Source reconciliation requires OWNER or ADMIN';
    end if;
    select * into v_movement from public.stock_movements m
    where m.id = (v_payload->>'movement_id')::uuid;
    if not found then
      raise exception using errcode = '22023', message = 'Movement is unavailable for source reconciliation';
    end if;
    v_group_id := coalesce(v_movement.reverses_movement_id, v_movement.id);
    -- Lock original first, then its optional reversal. Reversal creation also
    -- locks the original first, so a concurrent reversal cannot escape grouping.
    select * into v_group_original from public.stock_movements m
    where m.id = v_group_id for update;
    if not found or v_group_original.movement_type in ('OPENING'::public.stock_movement_type,
        'REVERSAL'::public.stock_movement_type) then
      raise exception using errcode = '22023', message = 'Movement group is unavailable for source reconciliation';
    end if;
    select * into v_group_reversal from public.stock_movements m
    where m.reverses_movement_id = v_group_id for update;
    v_has_reversal := found;
    v_group_count := case when v_has_reversal then 2 else 1 end;
    v_group_delta := v_group_original.quantity_delta
      + case when v_has_reversal then v_group_reversal.quantity_delta else 0 end;
    select * into v_projection from public.stock_balance_projection p
    where p.product_id = v_group_original.product_id and p.outlet_id = v_group_original.outlet_id for update;
    select * into v_period from public.stock_authority_periods ap
    where ap.id = v_projection.authority_period_id and ap.outlet_id = v_group_original.outlet_id for share;
    if not found or v_period.mode <> 'IPOS_SNAPSHOT_PLUS_QUENA_MOVEMENTS'::public.stock_authority_mode then
      raise exception using errcode = '22023', message = 'iPos reflection reconciliation is unavailable in the current stock authority period';
    end if;
    if v_projection.product_id is null or v_projection.baseline_source_import_row_id is distinct from
      (v_payload->>'source_import_row_id')::uuid then
      v_result := jsonb_build_object('ok', false, 'code', 'STALE_BASELINE');
      update public.stock_operation_requests set state = 'STALE', result = v_result, completed_at = now()
      where request_id = v_request;
      return v_result;
    end if;
    if exists (
      select 1 from public.stock_movement_source_reconciliations r
      where r.reconciliation_group_id = v_group_id
    ) then
      raise exception using errcode = '22023', message = 'Movement group is already or partially reconciled';
    end if;
    if v_projection.unreconciled_movement_delta - v_group_delta <= -100000000000
      or v_projection.unreconciled_movement_delta - v_group_delta >= 100000000000 then
      raise exception using errcode = '22023', message = 'Reconciliation quantity is outside the supported range';
    end if;
    select r.batch_id into v_batch_id
    from public.ipos_import_rows r
    join public.ipos_import_batches b on b.id = r.batch_id and b.outlet_id = r.outlet_id and b.status = 'COMPLETED'
    join public.ipos_normalization_commit_rows cr
      on cr.source_row_id = r.id and cr.batch_id = r.batch_id
     and cr.product_id = r.product_id and cr.action in ('CREATE', 'UPDATE')
    join public.ipos_normalization_commits nc
      on nc.id = cr.commit_id and nc.batch_id = r.batch_id
     and nc.outlet_id = r.outlet_id and nc.status = 'COMPLETED'
    where r.id = (v_payload->>'source_import_row_id')::uuid
      and r.product_id = v_group_original.product_id
      and r.outlet_id = v_group_original.outlet_id and r.status = 'VALID';
    if not found then raise exception using errcode = '22023', message = 'Accepted iPos source row is unavailable'; end if;
    insert into public.stock_movement_source_reconciliations(
      movement_id, reconciliation_group_id, product_id, outlet_id,
      source_import_row_id, batch_id, confirmed_by, reason, request_id
    )
    select m.id, v_group_id, m.product_id, m.outlet_id,
      (v_payload->>'source_import_row_id')::uuid, v_batch_id,
      v_actor, v_payload->>'reason', v_request
    from public.stock_movements m
    where m.id = v_group_id or m.reverses_movement_id = v_group_id;
    get diagnostics v_inserted_count = row_count;
    if v_inserted_count <> v_group_count then
      raise exception using errcode = '22023', message = 'Movement reconciliation group changed; retry after refresh';
    end if;
    v_before := v_projection.effective_quantity;
    update public.stock_balance_projection p
    set unreconciled_movement_delta = p.unreconciled_movement_delta - v_group_delta,
        balance_version = p.balance_version + 1, updated_at = now()
    where p.product_id = v_group_original.product_id and p.outlet_id = v_group_original.outlet_id
    returning p.effective_quantity, p.balance_version into v_after, v_new_version;
    insert into public.stock_balance_projection_events(
      product_id, outlet_id, authority_period_id, event_type, request_id,
      quantity_delta, balance_before, balance_after, balance_version, actor_id
    ) values (v_group_original.product_id, v_group_original.outlet_id, v_projection.authority_period_id,
      'MOVEMENT_RECONCILED', v_request, -v_group_delta,
      v_before, v_after, v_new_version, v_actor);
    v_result := jsonb_build_object('ok', true, 'reconciliationGroupId', v_group_id,
      'movementCount', v_group_count, 'netDeltaRemoved', -v_group_delta,
      'sourceImportRowId', v_payload->>'source_import_row_id', 'reconciled', true);

  elsif v_req.operation_key = 'REVERSE_MOVEMENT' then
    if v_role not in ('OWNER'::public.user_role, 'ADMIN'::public.user_role) then
      raise exception using errcode = '42501', message = 'Movement reversal requires OWNER or ADMIN';
    end if;
    select * into v_movement from public.stock_movements m
    where m.id = (v_payload->>'movement_id')::uuid for update;
    if not found then raise exception using errcode = '22023', message = 'Movement is unavailable'; end if;
    if v_movement.movement_type = 'REVERSAL'::public.stock_movement_type then
      raise exception using errcode = '22023', message = 'A reversal cannot itself be reversed; post a compensating manual movement';
    end if;
    if exists (select 1 from public.stock_movement_source_reconciliations r where r.movement_id = v_movement.id) then
      raise exception using errcode = '22023', message = 'A reconciled movement cannot be reversed; post a compensating manual movement';
    end if;
    if exists (select 1 from public.stock_movements m where m.reverses_movement_id = v_movement.id) then
      raise exception using errcode = '22023', message = 'Movement has already been reversed';
    end if;
    select * into v_projection from public.stock_balance_projection p
    where p.product_id = v_movement.product_id and p.outlet_id = v_movement.outlet_id for update;
    select * into v_period from public.stock_authority_periods ap
    where ap.outlet_id = v_movement.outlet_id and ap.ended_at is null for update;
    insert into public.stock_movement_batches(
      authority_period_id, outlet_id, source_system, operation_request_id, created_by
    ) values (v_period.id, v_movement.outlet_id, 'MANUAL', v_request, v_actor)
    returning id into v_batch_id;
    select d.balance_before, d.balance_after, d.new_balance_version
      into v_before, v_after, v_new_version
    from public.stock_apply_balance_delta(
      v_movement.product_id, v_movement.outlet_id, -v_movement.quantity_delta
    ) d;
    insert into public.stock_movements(
      batch_id, authority_period_id, outlet_id, product_id, movement_type,
      source_system, quantity_delta, balance_before, balance_after,
      source_reference, source_event_key, reverses_movement_id, created_by
    ) values (v_batch_id, v_period.id, v_movement.outlet_id, v_movement.product_id,
      'REVERSAL', 'MANUAL', -v_movement.quantity_delta, v_before, v_after,
      v_payload->>'reason', 'REVERSAL:' || v_movement.id::text, v_movement.id, v_actor);
    insert into public.stock_balance_projection_events(
      product_id, outlet_id, authority_period_id, event_type, request_id,
      quantity_delta, balance_before, balance_after, balance_version, actor_id
    ) values (v_movement.product_id, v_movement.outlet_id, v_period.id,
      'MOVEMENT_POSTED', v_request, -v_movement.quantity_delta,
      v_before, v_after, v_new_version, v_actor);
    v_result := jsonb_build_object('ok', true, 'movementBatchId', v_batch_id,
      'reversesMovementId', v_movement.id, 'balanceAfter', v_after);
  else
    raise exception using errcode = '22023', message = 'Unsupported stock operation';
  end if;

  update public.stock_operation_requests set state = 'COMPLETED', result = v_result,
    completed_at = now() where request_id = v_request;
  return v_result;
end;
$$;
alter function public.apply_stock_operation_intent(uuid) owner to postgres;
revoke all on function public.apply_stock_operation_intent(uuid) from public, anon, service_role;
grant execute on function public.apply_stock_operation_intent(uuid) to authenticated;

-- RLS and least-privilege grants. The request payload ledger is private.
alter table public.stock_authority_periods enable row level security;
alter table public.stock_balance_projection enable row level security;
alter table public.stock_balance_baseline_events enable row level security;
alter table public.stock_balance_projection_events enable row level security;
alter table public.stock_operation_requests enable row level security;
alter table public.stock_opname_sessions enable row level security;
alter table public.stock_opname_items enable row level security;
alter table public.stock_opname_count_events enable row level security;
alter table public.stock_opname_session_events enable row level security;
alter table public.stock_movement_batches enable row level security;
alter table public.stock_movements enable row level security;
alter table public.stock_movement_source_reconciliations enable row level security;

revoke all on public.stock_authority_periods, public.stock_balance_projection,
  public.stock_balance_baseline_events, public.stock_balance_projection_events,
  public.stock_operation_requests, public.stock_opname_sessions, public.stock_opname_items,
  public.stock_opname_count_events, public.stock_opname_session_events,
  public.stock_movement_batches, public.stock_movements,
  public.stock_movement_source_reconciliations
from public, anon, authenticated, service_role;
grant select on public.stock_authority_periods, public.stock_balance_projection,
  public.stock_balance_baseline_events, public.stock_balance_projection_events,
  public.stock_opname_sessions, public.stock_opname_items, public.stock_opname_count_events,
  public.stock_opname_session_events, public.stock_movement_batches, public.stock_movements
to authenticated;
grant select on public.stock_movement_source_reconciliations to authenticated;

create policy stock_authority_periods_select_roles on public.stock_authority_periods
  for select to authenticated using (
    public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role, 'GUDANG'::public.user_role)
  );
create policy stock_balance_projection_select_roles on public.stock_balance_projection
  for select to authenticated using (
    public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role, 'GUDANG'::public.user_role)
  );
create policy stock_balance_baseline_events_select_roles on public.stock_balance_baseline_events
  for select to authenticated using (
    public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role, 'GUDANG'::public.user_role)
  );
create policy stock_balance_projection_events_select_roles on public.stock_balance_projection_events
  for select to authenticated using (
    public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role, 'GUDANG'::public.user_role)
  );
create policy stock_opname_sessions_select_roles on public.stock_opname_sessions
  for select to authenticated using (
    public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role, 'GUDANG'::public.user_role)
  );
create policy stock_opname_items_select_roles on public.stock_opname_items
  for select to authenticated using (
    public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role, 'GUDANG'::public.user_role)
  );
create policy stock_opname_count_events_select_roles on public.stock_opname_count_events
  for select to authenticated using (
    public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role, 'GUDANG'::public.user_role)
  );
create policy stock_opname_session_events_select_roles on public.stock_opname_session_events
  for select to authenticated using (
    public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role, 'GUDANG'::public.user_role)
  );
create policy stock_movement_batches_select_roles on public.stock_movement_batches
  for select to authenticated using (
    public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role, 'GUDANG'::public.user_role)
  );
create policy stock_movements_select_roles on public.stock_movements
  for select to authenticated using (
    public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role, 'GUDANG'::public.user_role)
  );
create policy stock_movement_reconciliations_select_managers
  on public.stock_movement_source_reconciliations for select to authenticated using (
    public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role)
  );

grant usage on type public.stock_authority_mode, public.stock_movement_type,
  public.stock_movement_source, public.stock_opname_scope, public.stock_opname_status,
  public.stock_count_event_type, public.stock_opname_event_type, public.stock_request_state
to authenticated;
revoke all on type public.stock_authority_mode, public.stock_movement_type,
  public.stock_movement_source, public.stock_opname_scope, public.stock_opname_status,
  public.stock_count_event_type, public.stock_opname_event_type, public.stock_request_state
from public, anon;

commit;
