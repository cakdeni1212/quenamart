begin;

-- Forward-only fix for PL/pgSQL name resolution in correction-intent issuance.
-- Local variables use v_ names so ON CONFLICT inference resolves only table
-- columns. The partial unique index and advisory-lock behavior are unchanged.
create or replace function public.issue_product_field_correction_intent(
  p_product_id uuid,
  p_outlet_id uuid,
  p_field_key text,
  p_source_import_row_id uuid,
  p_corrected_value jsonb,
  p_reason text,
  p_barcode_operation text default null
)
returns uuid
language plpgsql security definer
set search_path = pg_catalog
as $$
<<issue_correction_intent_block>>
declare
  v_actor_id uuid := auth.uid();
  role_value public.user_role;
  source_outlet uuid;
  current_source uuid;
  latest_review public.product_field_audit_reviews%rowtype;
  value_text text;
  value_num numeric;
  normalized_value jsonb;
  value_reason text;
  normalized_operation text := p_barcode_operation;
  v_request_payload jsonb;
  request_value uuid;
begin
  if v_actor_id is null then raise exception using errcode='42501', message='Authentication required'; end if;
  role_value := public.current_active_user_role();
  if role_value is null or role_value='KASIR'::public.user_role then
    raise exception using errcode='42501', message='Field correction permission denied';
  end if;
  if p_field_key is null or p_field_key not in ('barcode','rack_label','hpp','selling_price') then
    raise exception using errcode='22023', message='Field is not editable in Phase 3B.1';
  end if;
  if p_field_key='barcode' then
    if normalized_operation is null or normalized_operation not in ('ADD_ALIAS','REPLACE_SOURCE') then
      raise exception using errcode='22023', message='Barcode operation must be ADD_ALIAS or REPLACE_SOURCE';
    end if;
    if p_outlet_id is not null then raise exception using errcode='22023', message='Barcode correction is not outlet-scoped'; end if;
  elsif normalized_operation is not null then
    raise exception using errcode='22023', message='Barcode operation is only valid for BARCODE';
  end if;
  if role_value='GUDANG'::public.user_role and p_field_key not in ('barcode','rack_label') then
    raise exception using errcode='42501', message='Field correction permission denied';
  end if;
  if p_source_import_row_id is null or p_product_id is null then
    raise exception using errcode='22023', message='Product and source row are required';
  end if;
  if p_field_key in ('rack_label','hpp','selling_price') and p_outlet_id is null then
    raise exception using errcode='22023', message='Outlet is required for this field';
  end if;

  value_reason := regexp_replace(coalesce(p_reason,''), '^[[:space:]]+|[[:space:]]+$', '', 'g');
  if value_reason='' then raise exception using errcode='22023', message='Correction reason is required'; end if;
  if p_field_key in ('barcode','rack_label') then
    if p_corrected_value is null or jsonb_typeof(p_corrected_value)<>'string' then
      raise exception using errcode='22023', message='Text value required';
    end if;
    value_text := regexp_replace(p_corrected_value #>> '{}', '^[[:space:]]+|[[:space:]]+$', '', 'g');
    if value_text='' or value_text ~ '[[:cntrl:]]' then
      raise exception using errcode='22023', message='Blank/control-character value is not allowed';
    end if;
    if p_field_key='barcode' and char_length(value_text)>256 then
      raise exception using errcode='22023', message='Barcode is too long';
    end if;
    normalized_value := to_jsonb(value_text);
  else
    if p_corrected_value is null or jsonb_typeof(p_corrected_value)<>'number' then
      raise exception using errcode='22023', message='Numeric value required';
    end if;
    value_num := (p_corrected_value #>> '{}')::numeric;
    if value_num<0 or value_num>=1000000000000::numeric or value_num<>trunc(value_num,2) then
      raise exception using errcode='22023', message='Price/HPP value is outside the allowed range or scale';
    end if;
    normalized_value := to_jsonb(value_num);
  end if;

  perform pg_catalog.pg_advisory_xact_lock(734921,2);
  perform 1 from public.products p where p.id=p_product_id for update;
  if not found then raise exception using errcode='22023', message='Product not found'; end if;
  select r.outlet_id into source_outlet
  from public.ipos_import_rows r
  join public.ipos_import_batches b on b.id=r.batch_id and b.outlet_id=r.outlet_id and b.status='COMPLETED'
  join public.ipos_normalization_commit_rows c on c.source_row_id=r.id and c.batch_id=r.batch_id
  join public.ipos_normalization_commits n on n.id=c.commit_id and n.status='COMPLETED'
  where r.id=p_source_import_row_id and r.product_id=p_product_id and r.status='VALID'
    and c.action in ('CREATE','UPDATE') limit 1;
  if not found or (p_outlet_id is not null and source_outlet is distinct from p_outlet_id) then
    raise exception using errcode='22023', message='Source row does not belong to this product/outlet';
  end if;
  if p_field_key='barcode' then
    select p.last_import_row_id into current_source from public.products p where p.id=p_product_id;
  elsif p_field_key='rack_label' then
    select s.source_import_row_id into current_source from public.product_outlet_settings s where s.product_id=p_product_id and s.outlet_id=p_outlet_id;
  elsif p_field_key='hpp' then
    select c.source_import_row_id into current_source from public.product_costs c where c.product_id=p_product_id and c.outlet_id=p_outlet_id;
  else
    select s.source_import_row_id into current_source from public.product_selling_prices s where s.product_id=p_product_id and s.outlet_id=p_outlet_id;
  end if;
  if current_source is distinct from p_source_import_row_id then
    raise exception using errcode='40001', message='Source changed; reload before preparing correction';
  end if;
  select r.* into latest_review
  from public.product_field_audit_reviews r
  where r.product_id=p_product_id and r.field_key=p_field_key
    and r.outlet_id is not distinct from case when p_field_key='barcode' then null::uuid else p_outlet_id end
  order by r.reviewed_at desc,r.created_at desc,r.id desc limit 1;
  if not found or latest_review.status<>'SEDANG_DICEK'::public.product_field_audit_status
    or latest_review.source_import_row_id is distinct from p_source_import_row_id then
    raise exception using errcode='22023', message='Begin review for the current source row before preparing a correction';
  end if;

  v_request_payload := jsonb_build_object(
    'actor_id',v_actor_id,'product_id',p_product_id,
    'outlet_id',case when p_field_key='barcode' then null else p_outlet_id end,
    'field_key',p_field_key,'source_import_row_id',p_source_import_row_id,
    'operation_type',normalized_operation,'corrected_value',normalized_value,'reason',value_reason
  );
  insert into public.product_field_correction_intents(actor_id,request_payload)
  values(v_actor_id,v_request_payload)
  on conflict (actor_id,request_payload) where completed_at is null do nothing
  returning request_id into request_value;
  if request_value is null then
    select i.request_id into request_value from public.product_field_correction_intents i
    where i.actor_id=issue_correction_intent_block.v_actor_id
      and i.request_payload=issue_correction_intent_block.v_request_payload and i.completed_at is null;
  end if;
  return request_value;
end;
$$;


-- Shared mutation logic: the completion UPDATE predicates explicitly
-- qualify columns to avoid PL/pgSQL variable/column name resolution conflicts.
create or replace function public.apply_product_field_correction_payload(
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
<<apply_correction_payload_block>>
declare actor_id uuid := auth.uid(); role_value public.user_role;
  prior_correction_request public.product_field_correction_requests%rowtype;
  source_batch uuid; source_outlet uuid; source_raw jsonb; source_norm jsonb; source_errors jsonb;
  source_field jsonb; source_valid boolean := false; normalized_value jsonb;
  value_text text; value_reason text; value_num numeric; same_as_source boolean := false;
  request_payload jsonb; result_value jsonb;
  active_override public.product_field_overrides%rowtype; has_override boolean := false;
  intent_row public.product_field_correction_intents%rowtype;
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

  select * into intent_row
  from public.product_field_correction_intents i
  where i.request_id=p_request_id and i.actor_id=apply_correction_payload_block.actor_id
  for update;
  if not found or intent_row.request_payload is distinct from request_payload then
    raise exception using errcode='22023', message='IDEMPOTENCY_KEY_REUSED';
  end if;
  if intent_row.completed_at is not null then
    raise exception using errcode='22023', message='Correction intent is already completed without a matching correction request';
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
      -- Qualify predicate columns because actor_id is also a PL/pgSQL variable.
      update public.product_field_correction_intents as pci
      set completed_at=pg_catalog.now(), correction_request_id=p_request_id
      where pci.request_id=p_request_id
        and pci.actor_id=apply_correction_payload_block.actor_id
        and pci.completed_at is null;
      if not found then raise exception 'Correction intent completion failed'; end if;
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
  -- Qualify predicate columns because actor_id is also a PL/pgSQL variable.
  update public.product_field_correction_intents as pci
  set completed_at=pg_catalog.now(), correction_request_id=p_request_id
  where pci.request_id=p_request_id
    and pci.actor_id=apply_correction_payload_block.actor_id
    and pci.completed_at is null;
  if not found then raise exception 'Correction intent completion failed'; end if;
  return result_value;

end;
$$;

alter function public.issue_product_field_correction_intent(uuid,uuid,text,uuid,jsonb,text,text) owner to postgres;
revoke all on function public.issue_product_field_correction_intent(uuid,uuid,text,uuid,jsonb,text,text) from public, anon, authenticated, service_role;
grant execute on function public.issue_product_field_correction_intent(uuid,uuid,text,uuid,jsonb,text,text) to authenticated;
alter function public.apply_product_field_correction_payload(uuid,uuid,uuid,text,jsonb,text,uuid,text) owner to postgres;
revoke all on function public.apply_product_field_correction_payload(uuid,uuid,uuid,text,jsonb,text,uuid,text) from public, anon, authenticated, service_role;

commit;
