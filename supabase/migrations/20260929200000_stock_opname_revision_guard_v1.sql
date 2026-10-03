-- Phase 3C.2: bind rebase/exception intents to the revision observed by the caller.
-- Existing public RPC signatures and unrelated operation branches are preserved.
BEGIN;

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
  v_expected_revision integer;
  v_expected_revision_numeric numeric;
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
      if jsonb_typeof(p_payload->'expected_revision') is distinct from 'number' then
        raise exception using errcode = '22023', message = 'Expected item revision is required';
      end if;
      v_expected_revision_numeric := (p_payload->>'expected_revision')::numeric;
      if v_expected_revision_numeric < 0
        or v_expected_revision_numeric > 2147483647
        or v_expected_revision_numeric <> trunc(v_expected_revision_numeric) then
        raise exception using errcode = '22023', message = 'Expected item revision must be a nonnegative integer';
      end if;
      v_expected_revision := v_expected_revision_numeric::integer;
      v_qty := (p_payload->>'physical_quantity')::numeric;
      if v_qty < 0 or v_qty >= 100000000000 or v_qty <> trunc(v_qty, 3) then
        raise exception using errcode = '22023', message = 'Physical quantity is outside the allowed range or precision';
      end if;
      v_payload := jsonb_build_object('session_id', v_session, 'product_id', v_product,
        'physical_quantity', to_jsonb(trim_scale(v_qty)), 'barcode_id', nullif(p_payload->>'barcode_id', '')::uuid,
        'expected_revision', v_expected_revision);
    elsif p_operation_key in ('REBASE_ITEM', 'REVIEW_EXCEPTION') then
      if jsonb_typeof(p_payload->'expected_revision') is distinct from 'number' then
        raise exception using errcode = '22023', message = 'Expected item revision is required';
      end if;
      v_expected_revision_numeric := (p_payload->>'expected_revision')::numeric;
      if v_expected_revision_numeric < 0
        or v_expected_revision_numeric > 2147483647
        or v_expected_revision_numeric <> trunc(v_expected_revision_numeric) then
        raise exception using errcode = '22023', message = 'Expected item revision must be a nonnegative integer';
      end if;
      v_expected_revision := v_expected_revision_numeric::integer;
      if p_operation_key = 'REVIEW_EXCEPTION' then
        v_note := nullif(btrim(p_payload->>'reason'), '');
        if v_note is null then raise exception using errcode = '22023', message = 'Exception reason is required'; end if;
        v_payload := jsonb_build_object('session_id', v_session, 'product_id', v_product,
          'expected_revision', v_expected_revision, 'reason', v_note);
      else
        v_payload := jsonb_build_object('session_id', v_session, 'product_id', v_product,
          'expected_revision', v_expected_revision);
      end if;
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
  v_expected_revision integer;
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
    v_expected_revision := (v_payload->>'expected_revision')::integer;
    if v_item.revision_no <> v_expected_revision then
      v_result := jsonb_build_object('ok', false, 'code', 'STALE_BASELINE',
        'reason', 'ITEM_REVISION_MISMATCH', 'expectedRevision', v_expected_revision,
        'currentRevision', v_item.revision_no, 'recountRequired', true);
      update public.stock_operation_requests set state = 'STALE', result = v_result, completed_at = now()
      where request_id = v_request;
      return v_result;
    end if;
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
      v_result := jsonb_build_object('ok', false, 'code', 'STALE_BASELINE',
        'reason', 'PROJECTION_BASELINE_CHANGED', 'recountRequired', true);
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
    if not found then raise exception using errcode = '22023', message = 'Product is outside this opname scope'; end if;
    if jsonb_typeof(v_payload->'expected_revision') is distinct from 'number' then
      v_result := jsonb_build_object('ok', false, 'code', 'STALE_BASELINE',
        'reason', 'EXPECTED_REVISION_REQUIRED', 'refreshRequired', true);
      update public.stock_operation_requests set state = 'STALE'::public.stock_request_state,
        result = v_result, completed_at = now() where request_id = v_request;
      return v_result;
    end if;
    v_expected_revision := (v_payload->>'expected_revision')::integer;
    if v_item.revision_no <> v_expected_revision then
      v_result := jsonb_build_object('ok', false, 'code', 'STALE_BASELINE',
        'reason', 'ITEM_REVISION_MISMATCH', 'expectedRevision', v_expected_revision,
        'currentRevision', v_item.revision_no, 'refreshRequired', true);
      update public.stock_operation_requests set state = 'STALE'::public.stock_request_state,
        result = v_result, completed_at = now() where request_id = v_request;
      return v_result;
    end if;
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
    if jsonb_typeof(v_payload->'expected_revision') is distinct from 'number' then
      v_result := jsonb_build_object('ok', false, 'code', 'STALE_BASELINE',
        'reason', 'EXPECTED_REVISION_REQUIRED', 'refreshRequired', true);
      update public.stock_operation_requests set state = 'STALE'::public.stock_request_state,
        result = v_result, completed_at = now() where request_id = v_request;
      return v_result;
    end if;
    v_expected_revision := (v_payload->>'expected_revision')::integer;
    if v_item.revision_no <> v_expected_revision then
      v_result := jsonb_build_object('ok', false, 'code', 'STALE_BASELINE',
        'reason', 'ITEM_REVISION_MISMATCH', 'expectedRevision', v_expected_revision,
        'currentRevision', v_item.revision_no, 'refreshRequired', true);
      update public.stock_operation_requests set state = 'STALE'::public.stock_request_state,
        result = v_result, completed_at = now() where request_id = v_request;
      return v_result;
    end if;
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

-- One-snapshot, RLS-respecting progress counts for the bounded opname reader.
create or replace function public.stock_opname_progress_counts(p_session_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = pg_catalog
as $$
  select pg_catalog.jsonb_build_object(
    'total', counts.total,
    'counted', counts.counted,
    'exception', counts.exception_count,
    'accounted', counts.counted + counts.exception_count,
    'remaining', counts.total - counts.counted - counts.exception_count,
    'recount_required', counts.recount_required
  )
  from (
    select
      pg_catalog.count(*)::bigint as total,
      pg_catalog.count(*) filter (
        where i.physical_quantity is not null and not i.requires_recount
      )::bigint as counted,
      pg_catalog.count(*) filter (
        where i.physical_quantity is null
          and i.exception_reason is not null and pg_catalog.btrim(i.exception_reason) <> ''
          and i.exception_reviewed_by is not null and i.exception_reviewed_at is not null
          and not i.requires_recount
      )::bigint as exception_count,
      pg_catalog.count(*) filter (where i.requires_recount)::bigint as recount_required
    from public.stock_opname_items i
    where i.session_id = p_session_id
  ) counts
$$;
alter function public.stock_opname_progress_counts(uuid) owner to postgres;
revoke all on function public.stock_opname_progress_counts(uuid) from public, anon, service_role;
grant execute on function public.stock_opname_progress_counts(uuid) to authenticated;


COMMIT;
