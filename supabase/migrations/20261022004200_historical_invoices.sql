-- ALKASU 0042 — Logo İşbaşı geçmiş satış/alış faturaları (gelir-gider referansı)
-- Kural: BUSINESS_RULES GG-04..GG-06 · Karar: D-102 (kullanıcı 22.10: "geçmiş dönem kârlılık oranlarımızı referans alabilelim")
--  * İşbaşı'ndan alınan fatura listeleri historical_invoices tablosuna işlenir (fatura no + tür ile tekil; tekrar yükleme güncellenir).
--  * Kişisel/ticari veri: dosyalar kod deposuna konmaz; yükleme yalnızca canlı veritabanında yapılır.
--  * Gelir-gider raporu bu kayıtları app_settings.history_until tarihine kadar sayar (çakışmayı önlemek için ALKASU'nun canlı
--    kullanımından önceki gün). Satış faturası = faturalı gelir (yeşil), alış faturası = mal alımı, iade faturası eksi.
--  * Tutarlar KDV dahil (Logo "Toplam (TL)"); KDV ve matrah ayrıca saklanır.

create table if not exists public.historical_invoices (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id),
  source       text not null default 'logo_isbasi',
  direction    text not null check (direction in ('satis', 'alis')),
  doc_type     text not null,                 -- Perakende Satış Faturası, Toptan Satış Faturası, Satınalma Faturası, Satınalma İade Faturası ...
  doc_no       text not null,
  doc_date     timestamptz not null,
  party_name   text,
  party_code   text,
  tax_no       text,
  total        numeric(14,2) not null,        -- KDV dahil; iade faturalarında eksi
  vat          numeric(14,2),
  net          numeric(14,2),
  cancelled    boolean not null default false,
  imported_at  timestamptz not null default now(),
  unique (business_id, direction, doc_type, doc_no)
);
create index if not exists historical_invoices_date on public.historical_invoices(business_id, doc_date);
alter table public.historical_invoices enable row level security;
drop policy if exists historical_invoices_select on public.historical_invoices;
create policy historical_invoices_select on public.historical_invoices for select to authenticated using (app.is_admin(business_id));

alter table public.app_settings add column if not exists history_until date;   -- geçmiş faturaların rapora dahil olduğu son gün

-- Yükleme çekirdeği (SQL düzenleyiciden / ileride Logo bağlantısından). p_rows: [{direction, doc_type, doc_no, doc_date, party_name,
--   party_code, tax_no, total, vat, net, cancelled}] — iade türleri otomatik eksiye çevrilir.
create or replace function app.import_historical_invoices(p_business uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_ins int := 0; v_upd int := 0; x jsonb; v_total numeric; v_new boolean;
begin
  for x in select * from jsonb_array_elements(p_rows) loop
    if coalesce(x->>'direction', '') not in ('satis', 'alis') then raise exception 'Yön geçersiz: %', x->>'direction' using errcode = '22023'; end if;
    if coalesce(trim(x->>'doc_no'), '') = '' then raise exception 'Fatura numarası eksik' using errcode = '22023'; end if;
    v_total := abs(round((x->>'total')::numeric, 2));
    if x->>'doc_type' ilike '%iade%' then v_total := -v_total; end if;
    insert into public.historical_invoices(business_id, direction, doc_type, doc_no, doc_date, party_name, party_code, tax_no, total, vat, net, cancelled)
    values (p_business, x->>'direction', trim(x->>'doc_type'), trim(x->>'doc_no'), (x->>'doc_date')::timestamptz,
            nullif(trim(x->>'party_name'), ''), nullif(trim(x->>'party_code'), ''), nullif(trim(x->>'tax_no'), ''),
            v_total, nullif(x->>'vat', '')::numeric, nullif(x->>'net', '')::numeric, coalesce((x->>'cancelled')::boolean, false))
    on conflict (business_id, direction, doc_type, doc_no) do update
       set doc_date = excluded.doc_date, party_name = excluded.party_name, party_code = excluded.party_code, tax_no = excluded.tax_no,
           total = excluded.total, vat = excluded.vat, net = excluded.net, cancelled = excluded.cancelled, imported_at = now()
    returning (xmax = 0) into v_new;
    if v_new then v_ins := v_ins + 1; else v_upd := v_upd + 1; end if;
  end loop;
  return jsonb_build_object('inserted', v_ins, 'updated', v_upd);
end $$;

-- Yönetici: geçmişin rapora dahil olduğu son günü ayarlar (boş = geçmiş kapalı)
create or replace function public.set_history_until(p_business uuid, p_date date) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app.require_role(p_business, 'yonetici');
  insert into public.app_settings(business_id, history_until) values (p_business, p_date)
  on conflict (business_id) do update set history_until = excluded.history_until, updated_at = now();
  perform app.audit(p_business, 'gecmis_fatura_siniri', 'app_settings', p_business::text, null, jsonb_build_object('history_until', p_date));
end $$;

-- Gelir-gider raporu: geçmiş faturalar dahil
create or replace function public.profit_report(p_business uuid, p_from date, p_to date, p_grain text default 'ay')
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v jsonb;
begin
  perform app.require_role(p_business, 'yonetici');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Tarih aralığı geçersiz' using errcode = '22023'; end if;
  if p_to - p_from > 800 then raise exception 'En fazla 2 yıllık aralık seçilebilir' using errcode = '22023'; end if;
  if p_grain not in ('ay', 'hafta') then raise exception 'Dönem türü geçersiz' using errcode = '22023'; end if;

  with days as (
    select d::date as day,
           greatest(p_from, case when p_grain = 'ay' then date_trunc('month', d) else date_trunc('week', d) end::date) as ps
      from generate_series(p_from, p_to, interval '1 day') d),
  periods as (select ps, max(day) as pe from days group by ps),
  sl as (   -- satışlar: ürün tutarı (depozito hariç), fatura durumu
    select dd.ps,
           sum(sa.goods_net) filter (where inv.ok) as invoiced,
           sum(sa.goods_net) filter (where not inv.ok) as uninvoiced,
           count(*) as n,
           sum((select coalesce(sum(c.total_cost), 0) from public.sale_items i join public.sale_item_costs c on c.sale_item_id = i.id
                 where i.sale_id = sa.id)) as cost
      from public.sales sa
      join days dd on dd.day = app.local_date(sa.sold_at)
      cross join lateral (select exists (select 1 from public.invoice_sales xs join public.invoices x on x.id = xs.invoice_id
                                          where xs.sale_id = sa.id and xs.active
                                            and x.status in ('gonderildi', 'resmilesti')) as ok) inv
     where sa.business_id = p_business and sa.status = 'tamamlandi'
       and sa.sold_at >= (p_from::timestamp at time zone 'Europe/Istanbul')
       and sa.sold_at < ((p_to + 1)::timestamp at time zone 'Europe/Istanbul')
     group by dd.ps),
  rt as (   -- iadeler (iade tarihinde düşülür)
    select dd.ps, sum(ri.refund_amount) as refund, sum(rc.total_cost) as rcost
      from public.returns re
      join days dd on dd.day = app.local_date(re.created_at)
      join public.return_items ri on ri.return_id = re.id
      left join public.return_item_costs rc on rc.return_item_id = ri.id
     where re.business_id = p_business
     group by dd.ps),
  pu as (   -- mal kabul (onaylı) — alış fiyatı × miktar, belge tarihinde
    select dd.ps, sum(pc.line_total) as amount, count(distinct p.id) as n
      from public.purchases p
      join days dd on dd.day = p.doc_date
      join public.purchase_items pi on pi.purchase_id = p.id
      join public.purchase_item_costs pc on pc.purchase_item_id = pi.id
     where p.business_id = p_business and p.status = 'onaylandi'
     group by dd.ps),
  ex as (
    select dd.ps, sum(e.amount) as amount
      from public.expenses e join days dd on dd.day = e.expense_date
     where e.business_id = p_business and e.status = 'gecerli'
     group by dd.ps),
  exc as (
    select x.ps, jsonb_object_agg(x.name, x.amount order by x.sort) as cats
      from (select dd.ps, c.name, min(c.sort) as sort, sum(e.amount) as amount
              from public.expenses e join days dd on dd.day = e.expense_date
              join public.expense_categories c on c.id = e.category_id
             where e.business_id = p_business and e.status = 'gecerli'
             group by dd.ps, c.name) x
     group by x.ps),
  hi as (   -- GG-04: Logo İşbaşı geçmiş faturaları (history_until tarihine kadar; iptaller hariç, iade eksi)
    select dd.ps,
           sum(h.total) filter (where h.direction = 'satis') as income, count(*) filter (where h.direction = 'satis') as ns,
           sum(h.total) filter (where h.direction = 'alis') as purchases, count(*) filter (where h.direction = 'alis') as np
      from public.historical_invoices h
      join days dd on dd.day = app.local_date(h.doc_date)
     where h.business_id = p_business and not h.cancelled
       and app.local_date(h.doc_date) <= coalesce((select s.history_until from public.app_settings s where s.business_id = p_business), date '1900-01-01')
     group by dd.ps),
  res as (
    select pr.ps, pr.pe,
           coalesce(hi.income, 0) as hinc, coalesce(hi.purchases, 0) as hpur, coalesce(hi.ns, 0) as hns, coalesce(hi.np, 0) as hnp,
           coalesce(sl.invoiced, 0) as inv, coalesce(sl.uninvoiced, 0) as uninv, coalesce(sl.n, 0) as n,
           coalesce(rt.refund, 0) as refund,
           coalesce(pu.amount, 0) as purchases, coalesce(pu.n, 0) as pn,
           coalesce(ex.amount, 0) as expenses, coalesce(exc.cats, '{}'::jsonb) as cats,
           coalesce(sl.cost, 0) - coalesce(rt.rcost, 0) as cogs
      from periods pr
      left join sl on sl.ps = pr.ps left join rt on rt.ps = pr.ps left join pu on pu.ps = pr.ps
      left join ex on ex.ps = pr.ps left join exc on exc.ps = pr.ps left join hi on hi.ps = pr.ps)
  select jsonb_build_object(
    'periods', coalesce(jsonb_agg(jsonb_build_object(
        'start', r.ps, 'end', r.pe, 'sales_count', r.n + r.hns,
        'income_invoiced', r.inv + r.hinc, 'income_uninvoiced', r.uninv, 'returns', r.refund,
        'income', r.inv + r.hinc + r.uninv - r.refund,
        'purchases', r.purchases + r.hpur, 'purchase_count', r.pn + r.hnp,
        'expenses', r.expenses, 'expense_categories', r.cats,
        'total_cost', r.purchases + r.hpur + r.expenses,
        'gross_profit', r.inv + r.hinc + r.uninv - r.refund - r.purchases - r.hpur,
        'net_profit', r.inv + r.hinc + r.uninv - r.refund - r.purchases - r.hpur - r.expenses,
        'history_income', r.hinc, 'history_purchases', r.hpur, 'history_sales_count', r.hns, 'history_purchase_count', r.hnp,
        'cogs', r.cogs) order by r.ps), '[]'::jsonb),
    'history_until', (select s.history_until from public.app_settings s where s.business_id = p_business),
    'pending_purchases', (select count(*) from public.purchases p where p.business_id = p_business and p.status = 'onay_bekliyor'
                            and p.doc_date between p_from and p_to))
    into v
    from res r;
  return v;
end $$;

select app.apply_grants();
