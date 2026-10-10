-- 10.10.2026 yayını: rapor gizliliği (0024). Tek işlem, veri değişmez.
begin;
-- ALKASU 0024 — Rapor gizliliği: bugünkü satış herkese, kâr ve dönemsel raporlar yalnızca yöneticiye
-- Kural: BUSINESS_RULES §12 (G-18) · Karar: D-084
-- Bugünkü satış tutarı, fiş sayısı, nakit/POS ve bugünkü veresiye satışı tüm personelin ana sayfasında görünür.
-- Brüt kâr, günlük/haftalık/aylık satış raporu, ürün kârlılığı ve toplam veresiye alacağı yalnızca yöneticiye açıktır.

CREATE OR REPLACE FUNCTION app.daily_sales(p_business uuid, p_from date, p_to date, p_with_cost boolean)
 RETURNS TABLE(day date, sales_count bigint, goods_gross numeric, discount numeric, goods_net numeric, returns_total numeric, net_revenue numeric, deposit numeric, cash numeric, pos numeric, credit numeric, cost numeric, gross_profit numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
declare v_admin boolean := p_with_cost;  -- yetki kontrolü çağıranda
begin
  return query
  with days as (select d::date as day from generate_series(p_from, p_to, interval '1 day') d),
  s as (
    select app.local_date(sa.sold_at) as day, count(*) as n, sum(sa.goods_gross) as gross, sum(sa.discount_total) as disc,
           sum(sa.goods_net) as net, sum(sa.deposit_total) as dep,
           sum((select coalesce(sum(c.total_cost), 0) from public.sale_items i join public.sale_item_costs c on c.sale_item_id = i.id
                 where i.sale_id = sa.id)) as cost
      from public.sales sa
     where sa.business_id = p_business and sa.status = 'tamamlandi'
       and app.local_date(sa.sold_at) between p_from and p_to
     group by 1),
  pay as (
    select app.local_date(sa.sold_at) as day,
           sum(sp.amount) filter (where sp.method = 'nakit') as cash,
           sum(sp.amount) filter (where sp.method = 'pos') as pos,
           sum(sp.amount) filter (where sp.method = 'veresiye') as credit
      from public.sales sa join public.sale_payments sp on sp.sale_id = sa.id
     where sa.business_id = p_business and sa.status = 'tamamlandi'
       and app.local_date(sa.sold_at) between p_from and p_to
     group by 1),
  r as (
    select app.local_date(re.created_at) as day, sum(ri.refund_amount) as refund, sum(rc.total_cost) as rcost
      from public.returns re join public.return_items ri on ri.return_id = re.id
      join public.return_item_costs rc on rc.return_item_id = ri.id
     where re.business_id = p_business and app.local_date(re.created_at) between p_from and p_to
     group by 1)
  select d.day, coalesce(s.n, 0), coalesce(s.gross, 0), coalesce(s.disc, 0), coalesce(s.net, 0), coalesce(r.refund, 0),
         coalesce(s.net, 0) - coalesce(r.refund, 0), coalesce(s.dep, 0),
         coalesce(pay.cash, 0), coalesce(pay.pos, 0), coalesce(pay.credit, 0),
         case when v_admin then coalesce(s.cost, 0) - coalesce(r.rcost, 0) end,
         case when v_admin then (coalesce(s.net, 0) - coalesce(r.refund, 0)) - (coalesce(s.cost, 0) - coalesce(r.rcost, 0)) end
    from days d left join s on s.day = d.day left join pay on pay.day = d.day left join r on r.day = d.day
   order by d.day;
end $function$;

CREATE OR REPLACE FUNCTION public.report_daily_sales(p_business uuid, p_from date, p_to date)
 RETURNS TABLE(day date, sales_count bigint, goods_gross numeric, discount numeric, goods_net numeric, returns_total numeric, net_revenue numeric, deposit numeric, cash numeric, pos numeric, credit numeric, cost numeric, gross_profit numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform app.require_role(p_business, 'yonetici');  -- G-18: günlük/haftalık/aylık rapor ve kâr yalnızca yönetici
  return query select * from app.daily_sales(p_business, p_from, p_to, true);
end $function$;

CREATE OR REPLACE FUNCTION public.report_product_sales(p_business uuid, p_from date, p_to date, p_group text DEFAULT 'urun'::text)
 RETURNS TABLE(key_id uuid, key_name text, brand_name text, qty_base bigint, revenue numeric, cost numeric, gross_profit numeric, margin_pct numeric, missing_cost boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
declare v_admin boolean;
begin
  perform app.require_role(p_business, 'yonetici');  -- G-18: yalnızca yönetici
  if p_group not in ('urun', 'marka', 'kategori') then raise exception 'Gruplama geçersiz' using errcode = '22023'; end if;
  v_admin := app.is_admin(p_business);
  return query
  with lines as (
    select i.product_id, i.base_qty as q, i.line_net as rev, c.total_cost as cost, not c.has_cost as nocost
      from public.sales sa join public.sale_items i on i.sale_id = sa.id join public.sale_item_costs c on c.sale_item_id = i.id
     where sa.business_id = p_business and sa.status = 'tamamlandi' and app.local_date(sa.sold_at) between p_from and p_to
    union all
    select ri.product_id, -ri.base_qty, -ri.refund_amount, -rc.total_cost, false
      from public.returns re join public.return_items ri on ri.return_id = re.id join public.return_item_costs rc on rc.return_item_id = ri.id
     where re.business_id = p_business and app.local_date(re.created_at) between p_from and p_to),
  g as (
    select case p_group when 'urun' then pr.id when 'marka' then pr.brand_id else pr.category_id end as k,
           case p_group when 'urun' then pr.name when 'marka' then coalesce(b.name, '(Markasız)') else coalesce(ca.name, '(Kategorisiz)') end as nm,
           case when p_group = 'urun' then b.name end as bn,
           sum(l.q)::bigint as q, sum(l.rev) as rev, sum(l.cost) as cost, bool_or(l.nocost) as nocost
      from lines l join public.products pr on pr.id = l.product_id
      left join public.brands b on b.id = pr.brand_id left join public.categories ca on ca.id = pr.category_id
     group by 1, 2, 3)
  select g.k, g.nm, g.bn, g.q, g.rev,
         case when v_admin then g.cost end,
         case when v_admin then g.rev - g.cost end,
         case when v_admin and g.rev <> 0 then round((g.rev - g.cost) * 100 / g.rev, 1) end,
         case when v_admin then g.nocost end
    from g order by g.rev desc nulls last;
end $function$;

CREATE OR REPLACE FUNCTION public.dashboard(p_business uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_role public.member_role; v_today date := app.local_date(now()); d record; v jsonb; v_cust uuid;
begin
  v_role := app.require_role(p_business, 'yonetici', 'satis', 'depo', 'izleyici', 'bayi', 'musteri');
  v := jsonb_build_object('role', v_role, 'today', v_today);
  if v_role = 'musteri' then
    v_cust := app.my_customer(p_business);
    return v || jsonb_build_object(
      'open_orders', (select count(*) from public.orders where customer_id = v_cust and status in ('acik', 'onay_bekliyor')),
      'pending_approval', (select count(*) from public.orders where customer_id = v_cust and status = 'onay_bekliyor'));
  end if;
  if v_role = 'bayi' then
    v_cust := app.my_customer(p_business);
    return v || jsonb_build_object(
      'balance', app.customer_balance(v_cust),
      'open_orders', (select count(*) from public.orders where customer_id = v_cust and status in ('acik', 'onay_bekliyor')),
      'dealer_open', (select count(*) from public.orders where dealer_customer_id = v_cust and status = 'acik'),
      'containers', (select coalesce(sum(qty), 0) from public.container_balances where customer_id = v_cust));
  end if;
  v := v || jsonb_build_object(
    'critical_count', (select count(*) from public.report_stock(p_business) s where s.status = 'kritik' and not s.is_container),
    'negative_count', (select count(*) from public.report_stock(p_business) s where s.status = 'negatif'),
    'orders_today', (select count(*) from public.orders where business_id = p_business and status = 'acik' and delivery_date <= v_today
                       and dealer_customer_id is null),
    'my_open_orders', (select count(*) from public.orders where business_id = p_business and status = 'acik' and assignee = auth.uid()));
  -- G-18: bugünkü satış ve veresiye satışı tüm personele; brüt kâr yalnızca yöneticiye
  if v_role in ('yonetici', 'satis', 'depo', 'sevkiyat', 'izleyici') then
    select * into d from app.daily_sales(p_business, v_today, v_today, v_role = 'yonetici');
    v := v || jsonb_build_object('sales_count', d.sales_count, 'net_revenue', d.net_revenue, 'cash', d.cash, 'pos', d.pos,
                                 'credit', d.credit, 'deposit', d.deposit, 'gross_profit', d.gross_profit);
  end if;
  if v_role in ('yonetici', 'satis', 'sevkiyat') then
    v := v || jsonb_build_object(
      'pending_approval', (select count(*) from public.orders where business_id = p_business and status = 'onay_bekliyor'),
      'unassigned_orders', (select count(*) from public.orders where business_id = p_business and status = 'acik'
                              and assignee is null and dealer_customer_id is null));
  end if;
  if v_role = 'yonetici' then
    v := v || jsonb_build_object(
      'receivables_total', (select coalesce(sum(amount), 0) from public.customer_ledger where business_id = p_business),
      'pending_purchases', (select count(*) from public.purchases where business_id = p_business and status = 'onay_bekliyor'),
      'open_return_requests', (select count(*) from public.return_requests where business_id = p_business and status = 'bekliyor'),
      'offline_limit_alerts', (select count(*) from public.sales where business_id = p_business and offline_limit_exceeded
                                 and app.local_date(created_at) >= v_today - 7),
      'cash_session', public.cash_session_summary(p_business, null));
  end if;
  if v_role in ('satis', 'sevkiyat') then
    v := v || jsonb_build_object(
      'my_sales_count', (select count(*) from public.sales where business_id = p_business and created_by = auth.uid()
                           and status = 'tamamlandi' and app.local_date(sold_at) = v_today),
      'my_sales_total', (select coalesce(sum(grand_total), 0) from public.sales where business_id = p_business and created_by = auth.uid()
                           and status = 'tamamlandi' and app.local_date(sold_at) = v_today));
  end if;
  return v;
end $function$;

select app.apply_grants();
insert into supabase_migrations.schema_migrations(version, name) values ('20261010002400', 'report_privacy') on conflict do nothing;
commit;
select 'SONUC: surum=' || (select max(version) from supabase_migrations.schema_migrations) || ' cekirdek=' || (to_regprocedure('app.daily_sales(uuid,date,date,boolean)') is not null) as sonuc;
