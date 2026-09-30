-- ALKASU 0007 — Raporlar ve ana sayfa özeti
-- Kurallar: M-06, T-05, T-06, V-06, PRODUCT_SPEC §4.11 · Maliyet/kâr alanları yalnızca yöneticiye dolu döner (Y-02)

-- Günlük satış özeti (tarih aralığı, İstanbul günü)
create or replace function public.report_daily_sales(p_business uuid, p_from date, p_to date)
returns table(day date, sales_count bigint, goods_gross numeric, discount numeric, goods_net numeric, returns_total numeric,
              net_revenue numeric, deposit numeric, cash numeric, pos numeric, credit numeric, cost numeric, gross_profit numeric)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare v_admin boolean;
begin
  perform app.require_role(p_business, 'yonetici', 'izleyici');
  v_admin := app.is_admin(p_business);
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
end $$;

-- Ürün / marka / kategori bazında satış (M-06)
create or replace function public.report_product_sales(p_business uuid, p_from date, p_to date, p_group text default 'urun')
returns table(key_id uuid, key_name text, brand_name text, qty_base bigint, revenue numeric, cost numeric, gross_profit numeric,
              margin_pct numeric, missing_cost boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare v_admin boolean;
begin
  perform app.require_role(p_business, 'yonetici', 'izleyici');
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
end $$;

-- Stok durumu: kritik, negatif, hızlı/yavaş, öneri (T-05, T-06)
create or replace function public.report_stock(p_business uuid, p_days integer default 30)
returns table(product_id uuid, code text, name text, brand_name text, category_name text, base_unit_name text, is_container boolean,
              qty integer, critical_level integer, suggested_critical integer, sold_qty bigint, avg_daily numeric, days_of_stock numeric,
              status text, speed text, avg_cost numeric, stock_value numeric)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare v_admin boolean; v_cdays int;
begin
  perform app.require_role(p_business, 'yonetici', 'satis', 'depo', 'izleyici');
  v_admin := app.is_admin(p_business);
  select critical_stock_days into v_cdays from public.app_settings where business_id = p_business;
  return query
  with sold as (
    select i.product_id, sum(i.base_qty) as q
      from public.sales sa join public.sale_items i on i.sale_id = sa.id
     where sa.business_id = p_business and sa.status = 'tamamlandi' and sa.sold_at >= now() - make_interval(days => p_days)
     group by 1),
  base as (
    select pr.id, pr.code, pr.name, b.name as bn, ca.name as cn, pr.base_unit_name as bu, pr.is_container as ic,
           coalesce(l.qty, 0) as q, pr.critical_level as cl, coalesce(s.q, 0)::bigint as sq,
           round(coalesce(s.q, 0)::numeric / p_days, 2) as ad, pc.avg_cost as ac
      from public.products pr
      left join public.stock_levels l on l.product_id = pr.id
      left join sold s on s.product_id = pr.id
      left join public.brands b on b.id = pr.brand_id left join public.categories ca on ca.id = pr.category_id
      left join public.product_costs pc on pc.product_id = pr.id
     where pr.business_id = p_business and pr.active),
  ranked as (
    select base.*, percent_rank() over (order by sq) as pr_rank,
           count(*) filter (where not ic) over () as n
      from base)
  select r.id, r.code, r.name, r.bn, r.cn, r.bu, r.ic, r.q, r.cl,
         case when r.ad > 0 then ceil(r.ad * v_cdays)::int end,
         r.sq, r.ad,
         case when r.ad > 0 then round(r.q / r.ad, 1) end,
         case when r.q < 0 then 'negatif' when r.cl is not null and r.q <= r.cl then 'kritik' else 'normal' end,
         case when r.ic then null
              when r.sq > 0 and r.pr_rank >= 0.8 then 'hizli'
              when r.q > 0 and (r.sq = 0 or r.pr_rank <= 0.2) then 'yavas'
              else 'normal' end,
         case when v_admin then r.ac end,
         case when v_admin then round(greatest(r.q, 0) * coalesce(r.ac, 0), 2) end
    from ranked r
   order by case when r.q < 0 then 0 when r.cl is not null and r.q <= r.cl then 1 else 2 end, r.name;
end $$;

-- Veresiye bakiyeleri ve yaşlandırma (V-06, FIFO)
create or replace function public.report_receivables(p_business uuid)
returns table(customer_id uuid, code text, name text, phone text, credit_limit numeric, unlimited_credit boolean, balance numeric,
              d0_30 numeric, d31_60 numeric, d61_90 numeric, d90_plus numeric, last_payment_at timestamptz)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare c record; e record; v_left numeric; v_take numeric; a numeric[];
begin
  perform app.require_role(p_business, 'yonetici');
  for c in select cu.*, (select coalesce(sum(amount), 0) from public.customer_ledger where customer_id = cu.id) as bal
             from public.customers cu where cu.business_id = p_business loop
    continue when c.bal = 0;
    a := array[0, 0, 0, 0]::numeric[];
    v_left := c.bal;
    if v_left > 0 then
      -- Bakiye en yeni borç kayıtlarından oluşur (ödemeler en eskiyi kapatır)
      for e in select amount, created_at from public.customer_ledger where customer_id = c.id and amount > 0 order by created_at desc, id desc loop
        exit when v_left <= 0;
        v_take := least(e.amount, v_left);
        v_left := v_left - v_take;
        if now() - e.created_at <= interval '30 days' then a[1] := a[1] + v_take;
        elsif now() - e.created_at <= interval '60 days' then a[2] := a[2] + v_take;
        elsif now() - e.created_at <= interval '90 days' then a[3] := a[3] + v_take;
        else a[4] := a[4] + v_take;
        end if;
      end loop;
    end if;
    customer_id := c.id; code := c.code; name := c.name; phone := c.phone; credit_limit := c.credit_limit;
    unlimited_credit := c.unlimited_credit; balance := c.bal;
    d0_30 := a[1]; d31_60 := a[2]; d61_90 := a[3]; d90_plus := a[4];
    last_payment_at := (select max(created_at) from public.customer_payments where customer_id = c.id and status = 'gecerli');
    return next;
  end loop;
end $$;

-- Müşteri cari ekstresi
create or replace function public.customer_statement(p_customer uuid, p_from date default null, p_to date default null)
returns table(at timestamptz, type text, description text, debit numeric, credit numeric, balance numeric, ref_type text, ref_id uuid)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare v_bid uuid;
begin
  select business_id into v_bid from public.customers where id = p_customer;
  if v_bid is null then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(v_bid, 'yonetici', 'satis');
  return query
  with l as (
    select cl.*, sum(cl.amount) over (order by cl.created_at, cl.id) as running
      from public.customer_ledger cl where cl.customer_id = p_customer)
  select l.created_at,
         l.type,
         case l.type when 'satis' then 'Satış #' || coalesce((select no::text from public.sales where id = l.ref_id), '')
                     when 'tahsilat' then 'Tahsilat'
                     when 'tahsilat_iptal' then 'Tahsilat iptali'
                     when 'iade' then 'İade #' || coalesce((select no::text from public.returns where id = l.ref_id), '')
                     when 'iptal' then 'Satış iptali #' || coalesce((select no::text from public.sales where id = l.ref_id), '')
                     when 'depozito_mahsup' then 'Depozito iadesi (mahsup)'
                     when 'acilis' then 'Açılış bakiyesi' else l.type end,
         case when l.amount > 0 then l.amount end, case when l.amount < 0 then -l.amount end,
         l.running, l.ref_type, l.ref_id
    from l
   where (p_from is null or app.local_date(l.created_at) >= p_from) and (p_to is null or app.local_date(l.created_at) <= p_to)
   order by l.created_at, l.id;
end $$;

-- Müşterideki kaplar
create or replace function public.report_containers(p_business uuid)
returns table(customer_id uuid, customer_code text, customer_name text, product_id uuid, product_name text, qty integer, amount numeric)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  perform app.require_role(p_business, 'yonetici', 'satis');
  return query
  select b.customer_id, c.code, coalesce(c.name, 'Perakende (kayıtsız)'), b.product_id, pr.name, b.qty, b.amount
    from public.container_balances b join public.products pr on pr.id = b.product_id
    left join public.customers c on c.id = b.customer_id
   where b.business_id = p_business
   order by b.qty desc, c.name;
end $$;

-- Ana sayfa özeti (bugün)
create or replace function public.dashboard(p_business uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_role public.member_role; v_today date := app.local_date(now()); d record; v jsonb;
begin
  v_role := app.require_role(p_business, 'yonetici', 'satis', 'depo', 'izleyici');
  v := jsonb_build_object('role', v_role, 'today', v_today,
    'critical_count', (select count(*) from public.report_stock(p_business) s where s.status = 'kritik' and not s.is_container),
    'negative_count', (select count(*) from public.report_stock(p_business) s where s.status = 'negatif'));
  if v_role in ('yonetici', 'izleyici') then
    select * into d from public.report_daily_sales(p_business, v_today, v_today);
    v := v || jsonb_build_object('sales_count', d.sales_count, 'net_revenue', d.net_revenue, 'cash', d.cash, 'pos', d.pos,
                                 'credit', d.credit, 'deposit', d.deposit, 'gross_profit', d.gross_profit);
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
  if v_role = 'satis' then
    v := v || jsonb_build_object(
      'my_sales_count', (select count(*) from public.sales where business_id = p_business and created_by = auth.uid()
                           and status = 'tamamlandi' and app.local_date(sold_at) = v_today),
      'my_sales_total', (select coalesce(sum(grand_total), 0) from public.sales where business_id = p_business and created_by = auth.uid()
                           and status = 'tamamlandi' and app.local_date(sold_at) = v_today));
  end if;
  return v;
end $$;

select app.apply_grants();
