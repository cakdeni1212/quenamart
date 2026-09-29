-- Read-only, paginated product workspace queries. Apply manually after review.
-- SECURITY INVOKER preserves table grants and RLS. Cost is returned only to managers.
begin;

-- Exposes only the current committed snapshot identifiers to authenticated,
-- active profiles; underlying normalization commit metadata stays manager-only.
create or replace function public.product_workspace_latest_snapshot()
returns table (batch_id uuid, outlet_id uuid)
language sql stable security definer
set search_path = pg_catalog
as $$
  select c.batch_id, c.outlet_id
  from public.ipos_normalization_commits c
  where c.status = 'COMPLETED'
    and public.current_active_user_role() is not null
  order by c.completed_at desc
  limit 1
$$;

create or replace function public.product_workspace_list(
  p_search text default null,
  p_category text default null,
  p_rack text default null,
  p_finding public.product_audit_finding_code default null,
  p_no_problems boolean default false,
  p_page integer default 1,
  p_page_size integer default 25
)
returns table (
  product_id uuid, sku text, name text, category_label text,
  barcode text, selling_price numeric, hpp numeric, quantity numeric,
  minimum_quantity numeric, rack_label text,
  finding_codes public.product_audit_finding_code[], total_count bigint
)
language sql stable security invoker
set search_path = pg_catalog, public
as $$
  with latest as (
    select s.batch_id, s.outlet_id from public.product_workspace_latest_snapshot() s
  ), product_rows as (
    select p.id, p.sku, p.name, p.category_label,
      b.barcode, sp.amount as selling_price,
      case when public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role)
        then co.hpp else null end as hpp,
      i.quantity, i.minimum_quantity, s.rack_label,
      coalesce(array_agg(distinct f.finding_code) filter (where f.id is not null), '{}') as finding_codes
    from public.products p
    cross join latest l
    left join lateral (select bx.barcode from public.product_barcodes bx where bx.product_id = p.id and bx.is_active order by bx.created_at, bx.id limit 1) b on true
    left join public.product_selling_prices sp on sp.product_id = p.id and sp.outlet_id = l.outlet_id
    left join public.product_costs co on co.product_id = p.id and co.outlet_id = l.outlet_id
    left join public.product_inventory i on i.product_id = p.id and i.outlet_id = l.outlet_id
    left join public.product_outlet_settings s on s.product_id = p.id and s.outlet_id = l.outlet_id
    left join public.product_audit_findings f on f.product_id = p.id and f.batch_id = l.batch_id and f.status = 'OPEN'
    where (nullif(btrim(p_search), '') is null
      or p.name ilike '%' || p_search || '%'
      or p.sku ilike '%' || p_search || '%'
      or exists (select 1 from public.product_barcodes bx where bx.product_id = p.id and bx.is_active and bx.barcode ilike '%' || p_search || '%'))
      and (nullif(p_category, '') is null or p.category_label = p_category)
      and (nullif(p_rack, '') is null or s.rack_label = p_rack)
    group by p.id, p.sku, p.name, p.category_label, b.barcode, sp.amount, co.hpp, i.quantity, i.minimum_quantity, s.rack_label
  ), filtered as (
    select * from product_rows r
    where (p_finding is null or p_finding = any(r.finding_codes))
      and (not p_no_problems or cardinality(r.finding_codes) = 0)
  )
  select f.id, f.sku, f.name, f.category_label, f.barcode, f.selling_price, f.hpp,
    f.quantity, f.minimum_quantity, f.rack_label, f.finding_codes, count(*) over()
  from filtered f
  order by f.name collate "C", f.sku collate "C"
  offset greatest(p_page - 1, 0) * least(greatest(p_page_size, 1), 100)
  limit least(greatest(p_page_size, 1), 100)
$$;

create or replace function public.product_audit_overview()
returns table (finding_code public.product_audit_finding_code, finding_count bigint)
language sql stable security invoker
set search_path = pg_catalog, public
as $$
  with latest as (
    select s.batch_id from public.product_workspace_latest_snapshot() s
  ), codes(finding_code) as (values
    ('MISSING_BARCODE'::public.product_audit_finding_code),
    ('MALFORMED_BARCODE'::public.product_audit_finding_code),
    ('ZERO_OR_MISSING_HPP'::public.product_audit_finding_code),
    ('SELLING_PRICE_BELOW_HPP'::public.product_audit_finding_code),
    ('ZERO_STOCK'::public.product_audit_finding_code),
    ('STOCK_AT_OR_BELOW_MINIMUM'::public.product_audit_finding_code),
    ('MISSING_RACK'::public.product_audit_finding_code),
    ('DUPLICATE_PRODUCT_NAME'::public.product_audit_finding_code)
  )
  select c.finding_code, count(f.id)
  from codes c cross join latest l
  left join public.product_audit_findings f on f.batch_id = l.batch_id and f.finding_code = c.finding_code and f.status = 'OPEN'
  where (public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role)
    or c.finding_code not in ('ZERO_OR_MISSING_HPP'::public.product_audit_finding_code,'SELLING_PRICE_BELOW_HPP'::public.product_audit_finding_code))
  group by c.finding_code order by c.finding_code
$$;

create or replace function public.product_workspace_detail(p_product_id uuid)
returns table (
  product_id uuid, sku text, name text, category_label text,
  barcode text, selling_price numeric, hpp numeric, quantity numeric,
  minimum_quantity numeric, rack_label text,
  finding_codes public.product_audit_finding_code[]
)
language sql stable security invoker
set search_path = pg_catalog, public
as $$
  with latest as (
    select s.batch_id, s.outlet_id from public.product_workspace_latest_snapshot() s
  )
  select p.id, p.sku, p.name, p.category_label, b.barcode, sp.amount,
    case when public.current_active_user_role() in ('OWNER'::public.user_role, 'ADMIN'::public.user_role)
      then co.hpp else null end,
    i.quantity, i.minimum_quantity, s.rack_label,
    coalesce(array_agg(distinct f.finding_code) filter (where f.id is not null), '{}')
  from public.products p cross join latest l
  left join lateral (select bx.barcode from public.product_barcodes bx where bx.product_id = p.id and bx.is_active order by bx.created_at, bx.id limit 1) b on true
  left join public.product_selling_prices sp on sp.product_id = p.id and sp.outlet_id = l.outlet_id
  left join public.product_costs co on co.product_id = p.id and co.outlet_id = l.outlet_id
  left join public.product_inventory i on i.product_id = p.id and i.outlet_id = l.outlet_id
  left join public.product_outlet_settings s on s.product_id = p.id and s.outlet_id = l.outlet_id
  left join public.product_audit_findings f on f.product_id = p.id and f.batch_id = l.batch_id and f.status = 'OPEN'
  where p.id = p_product_id
  group by p.id, p.sku, p.name, p.category_label, b.barcode, sp.amount, co.hpp, i.quantity, i.minimum_quantity, s.rack_label
$$;

revoke all on function public.product_workspace_list(text,text,text,public.product_audit_finding_code,boolean,integer,integer) from public, anon;
revoke all on function public.product_audit_overview() from public, anon;
revoke all on function public.product_workspace_detail(uuid) from public, anon;
revoke all on function public.product_workspace_latest_snapshot() from public, anon;
grant execute on function public.product_workspace_list(text,text,text,public.product_audit_finding_code,boolean,integer,integer) to authenticated;
grant execute on function public.product_audit_overview() to authenticated;
grant execute on function public.product_workspace_detail(uuid) to authenticated;
grant execute on function public.product_workspace_latest_snapshot() to authenticated;
commit;
