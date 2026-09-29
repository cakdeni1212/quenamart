begin;

-- Bind review request replay identity to the same trimmed/blank-normalized
-- evidence note persisted by the original RPC. Exact retries replay; changed
-- notes under a reused request ID are rejected.
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
      or prior_request.status is distinct from p_status
      or prior_request.evidence_notes is distinct from nullif(btrim(p_evidence_notes), '') then
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

commit;
