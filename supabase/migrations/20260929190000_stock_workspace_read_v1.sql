-- Phase 3C.1B: bounded, read-only Stock workspace query.
-- Effective stock is sourced only from stock_balance_projection.
begin;

create or replace function public.stock_workspace_read_page(
  p_outlet_id uuid,
  p_q text default null,
  p_stock_status text default 'ALL',
  p_rack_empty boolean default false,
  p_category text default null,
  p_page integer default 1,
  p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, public
as $$
declare
  v_role public.user_role;
  v_q text := nullif(btrim(p_q), '');
  v_category text := nullif(btrim(p_category), '');
  v_stock_status text := p_stock_status;
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := least(greatest(coalesce(p_page_size, 50), 1), 50);
begin
  v_role := public.current_active_user_role();
  if v_role is null or v_role not in (
    'OWNER'::public.user_role,
    'ADMIN'::public.user_role,
    'GUDANG'::public.user_role
  ) then
    raise exception using errcode = '42501', message = 'Stock access denied';
  end if;

  if p_outlet_id is null or not exists (
    select 1
    from public.stock_authority_periods as ap
    join public.outlets as o on o.id = ap.outlet_id
    where ap.outlet_id = p_outlet_id
      and ap.ended_at is null
      and o.is_active
  ) then
    raise exception using errcode = '42501', message = 'Active stock outlet access denied';
  end if;

  if v_stock_status is null or v_stock_status not in ('ALL', 'HABIS', 'MENIPIS', 'AMAN') then
    raise exception using errcode = '22023', message = 'Invalid stock status filter';
  end if;

  return (
    with membership as materialized (
      select
        i.product_id,
        p.name,
        p.sku,
        p.category_label as category,
        os.rack_label as rack,
        i.minimum_quantity as minimum_stock,
        bp.effective_quantity,
        (bp.product_id is not null and bp.effective_quantity is not null) as projection_usable,
        (
          select b.barcode
          from public.product_barcodes as b
          where b.product_id = i.product_id
            and b.is_active
          order by b.created_at, b.id
          limit 1
        ) as barcode
      from public.product_inventory as i
      join public.products as p on p.id = i.product_id
      left join public.stock_balance_projection as bp
        on bp.product_id = i.product_id and bp.outlet_id = i.outlet_id
      left join public.product_outlet_settings as os
        on os.product_id = i.product_id and os.outlet_id = i.outlet_id
      where i.outlet_id = p_outlet_id
    ), matching as materialized (
      select m.*
      from membership as m
      where (v_q is null
        or m.name ilike '%' || v_q || '%'
        or m.sku ilike '%' || v_q || '%'
        or exists (
          select 1
          from public.product_barcodes as search_barcode
          where search_barcode.product_id = m.product_id
            and search_barcode.is_active
            and search_barcode.barcode ilike '%' || v_q || '%'
        ))
        and (v_category is null or m.category = v_category)
        and (not coalesce(p_rack_empty, false) or nullif(btrim(m.rack), '') is null)
    ), classified as materialized (
      select
        m.product_id,
        m.name,
        m.sku,
        m.barcode,
        m.category,
        m.rack,
        m.effective_quantity,
        m.minimum_stock,
        case
          when m.effective_quantity = 0 then 'HABIS'
          when coalesce(m.minimum_stock, 0) > 0
            and m.effective_quantity <= m.minimum_stock then 'MENIPIS'
          else 'AMAN'
        end as stock_status
      from matching as m
      where m.projection_usable
    ), summary as (
      select
        count(*) as total,
        count(*) filter (where c.stock_status = 'HABIS') as empty,
        count(*) filter (where c.stock_status = 'MENIPIS') as low,
        count(*) filter (where c.stock_status = 'AMAN') as safe
      from classified as c
    ), integrity as (
      select count(*) filter (where not m.projection_usable) as missing_projection_count
      from matching as m
    ), filtered as materialized (
      select c.*
      from classified as c
      where v_stock_status = 'ALL' or c.stock_status = v_stock_status
    ), page_totals as (
      select count(*) as filtered_total
      from filtered
    ), page_info as (
      select
        t.filtered_total,
        case when t.filtered_total = 0 then 0
          else ceil(t.filtered_total::numeric / v_page_size)::integer end as page_count,
        case
          when t.filtered_total = 0 then 1
          else least(v_page, ceil(t.filtered_total::numeric / v_page_size)::integer)
        end as page
      from page_totals as t
    ), page_rows as (
      select f.*
      from filtered as f
      order by f.name collate "C", f.sku collate "C", f.product_id
      limit v_page_size
      offset ((select pi.page from page_info as pi) - 1) * v_page_size
    )
    select jsonb_build_object(
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
          'product_id', r.product_id,
          'name', r.name,
          'sku', r.sku,
          'barcode', r.barcode,
          'category', r.category,
          'rack', r.rack,
          'effective_quantity', r.effective_quantity,
          'minimum_stock', r.minimum_stock,
          'stock_status', r.stock_status
        ) order by r.name collate "C", r.sku collate "C", r.product_id)
        from page_rows as r
      ), '[]'::jsonb),
      'summary', (select to_jsonb(s) from summary as s),
      'pagination', (select to_jsonb(pi) || jsonb_build_object('page_size', v_page_size)
        from page_info as pi),
      'integrity', (select to_jsonb(i) from integrity as i)
    )
  );
end;
$$;

alter function public.stock_workspace_read_page(uuid,text,text,boolean,text,integer,integer) owner to postgres;
revoke all on function public.stock_workspace_read_page(uuid,text,text,boolean,text,integer,integer)
  from public, anon, service_role;
grant execute on function public.stock_workspace_read_page(uuid,text,text,boolean,text,integer,integer)
  to authenticated;

commit;
