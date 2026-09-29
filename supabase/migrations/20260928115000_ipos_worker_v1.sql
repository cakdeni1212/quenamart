-- Phase 2A worker lifecycle support. Apply only after review; do not rerun the
-- already deployed 20260928 schema migration.
begin;

alter table public.ipos_import_requests
  add column original_filename text,
  add constraint ipos_requests_original_filename_valid check (
    original_filename is null or (
      btrim(original_filename) <> ''
      and length(original_filename) <= 255
      and original_filename !~ '[[:cntrl:]]'
      and lower(original_filename) like '%.xlsx'
    )
  );

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
    or new.original_filename is distinct from old.original_filename
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
revoke all on function public.guard_ipos_request_lifecycle() from public, anon, authenticated, service_role;

-- The checksum is filled once after download while the batch is PROCESSING;
-- all other source metadata remains immutable.
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
    or new.source_sheet is distinct from old.source_sheet
    or new.header_row_number is distinct from old.header_row_number
    or new.first_data_row_number is distinct from old.first_data_row_number
    or new.imported_by is distinct from old.imported_by
    or (new.file_sha256 is distinct from old.file_sha256 and not (
      old.status = 'PROCESSING' and old.file_sha256 is null
      and new.file_sha256 ~ '^[0-9a-fA-F]{64}$'
    ))
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
revoke all on function public.guard_ipos_batch_source_immutability() from public, anon, authenticated, service_role;

create or replace function public.request_ipos_import(
  p_outlet_id uuid,
  p_storage_path text,
  p_original_filename text
)
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
  if p_original_filename is null or btrim(p_original_filename) = ''
    or length(p_original_filename) > 255
    or p_original_filename ~ '[[:cntrl:]]'
    or lower(p_original_filename) not like '%.xlsx' then
    raise exception 'Invalid iPos workbook filename';
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
  insert into public.ipos_import_requests (id, outlet_id, requested_by, storage_path, original_filename)
  values (request_id, p_outlet_id, caller_id, p_storage_path, p_original_filename);
  return request_id;
end;
$$;
revoke all on function public.request_ipos_import(uuid, text, text) from public, anon;
grant execute on function public.request_ipos_import(uuid, text, text) to authenticated;

-- Keep the deployed two-argument RPC compatible for older callers.
create or replace function public.request_ipos_import(p_outlet_id uuid, p_storage_path text)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  return public.request_ipos_import(
    p_outlet_id,
    p_storage_path,
    regexp_replace(p_storage_path, '^.*/', '')
  );
end;
$$;
revoke all on function public.request_ipos_import(uuid, text) from public, anon;
grant execute on function public.request_ipos_import(uuid, text) to authenticated;

-- Claim and batch creation commit or roll back together. A second worker cannot
-- pass the conditional QUEUED update for the same request.
create or replace function public.claim_ipos_import_request(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  claimed public.ipos_import_requests%rowtype;
  batch public.ipos_import_batches%rowtype;
begin
  update public.ipos_import_requests
  set state = 'PROCESSING'
  where id = p_request_id and state = 'QUEUED'
  returning * into claimed;
  if not found then
    return null;
  end if;

  insert into public.ipos_import_batches (
    outlet_id, request_id, original_filename, storage_bucket, storage_path
  ) values (
    claimed.outlet_id,
    claimed.id,
    coalesce(claimed.original_filename, regexp_replace(claimed.storage_path, '^.*/', '')),
    'quena-ipos-imports',
    claimed.storage_path
  ) returning * into batch;
  update public.ipos_import_batches set status = 'PROCESSING'
  where id = batch.id returning * into batch;

  return jsonb_build_object(
    'request_id', claimed.id,
    'batch_id', batch.id,
    'outlet_id', claimed.outlet_id,
    'storage_bucket', batch.storage_bucket,
    'storage_path', claimed.storage_path,
    'original_filename', batch.original_filename,
    'requested_by', claimed.requested_by,
    'started_at', batch.started_at
  );
end;
$$;
revoke all on function public.claim_ipos_import_request(uuid) from public, anon, authenticated;
grant execute on function public.claim_ipos_import_request(uuid) to service_role;

create or replace function public.complete_ipos_import_request(
  p_request_id uuid,
  p_batch_id uuid,
  p_expected_row_count integer
)
returns integer
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  request_row public.ipos_import_requests%rowtype;
  batch_row public.ipos_import_batches%rowtype;
  row_count integer;
  first_row integer;
  last_row integer;
begin
  if p_expected_row_count is null or p_expected_row_count < 0 then
    raise exception 'Expected row count must be nonnegative';
  end if;
  select * into request_row from public.ipos_import_requests where id = p_request_id for update;
  select * into batch_row from public.ipos_import_batches
  where id = p_batch_id and request_id = p_request_id for update;
  if request_row.id is null or batch_row.id is null
    or request_row.state <> 'PROCESSING' or batch_row.status <> 'PROCESSING' then
    raise exception 'iPos request and batch must both be processing';
  end if;

  select count(*)::integer, min(source_row_number), max(source_row_number)
  into row_count, first_row, last_row from public.ipos_import_rows where batch_id = p_batch_id;
  if row_count <> p_expected_row_count
    or (row_count > 0 and (first_row <> 3 or last_row <> 2 + row_count))
    or exists (
      select 1 from public.ipos_import_rows
      where batch_id = p_batch_id and (status <> 'RAW_ONLY' or product_id is not null)
    ) then
    raise exception 'Raw snapshot row count, sequence, or phase status validation failed';
  end if;

  update public.ipos_import_batches
  set expected_data_row_count = p_expected_row_count,
      actual_data_row_count = row_count,
      status = 'COMPLETED'
  where id = p_batch_id;
  update public.ipos_import_requests set state = 'COMPLETED' where id = p_request_id;
  return row_count;
end;
$$;
revoke all on function public.complete_ipos_import_request(uuid, uuid, integer) from public, anon, authenticated;
grant execute on function public.complete_ipos_import_request(uuid, uuid, integer) to service_role;

create or replace function public.fail_ipos_import_request(
  p_request_id uuid,
  p_batch_id uuid,
  p_error_code text,
  p_error_message text
)
returns integer
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  request_row public.ipos_import_requests%rowtype;
  batch_row public.ipos_import_batches%rowtype;
  row_count integer;
  safe_code text := left(coalesce(nullif(p_error_code, ''), 'IMPORT_FAILED'), 80);
  safe_message text := left(coalesce(nullif(p_error_message, ''), 'iPos raw snapshot failed'), 500);
begin
  select * into request_row from public.ipos_import_requests where id = p_request_id for update;
  select * into batch_row from public.ipos_import_batches
  where id = p_batch_id and request_id = p_request_id for update;
  if request_row.id is null or batch_row.id is null
    or request_row.state <> 'PROCESSING' or batch_row.status <> 'PROCESSING' then
    raise exception 'iPos request and batch must both be processing';
  end if;

  select count(*)::integer into row_count
  from public.ipos_import_rows where batch_id = p_batch_id;
  update public.ipos_import_batches
  set actual_data_row_count = row_count,
      validation_errors = jsonb_build_array(jsonb_build_object('code', safe_code, 'message', safe_message)),
      status = 'FAILED'
  where id = p_batch_id;
  update public.ipos_import_requests set state = 'FAILED' where id = p_request_id;
  return row_count;
end;
$$;
revoke all on function public.fail_ipos_import_request(uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function public.fail_ipos_import_request(uuid, uuid, text, text) to service_role;

commit;
