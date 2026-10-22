-- ALKASU 0040 — Faturalama yöntemi: aylık toplu fatura / sevkiyat başına fatura
-- Kural: BUSINESS_RULES F-30..F-36 · Karar: D-100 (kullanıcı isteği 22.10)
--  * Müşteri kartında fatura yöntemi: 'teslimat' (sevkiyat başına, varsayılan) | 'aylik' (aylık toplu).
--  * Bir fatura birden çok teslimatı (satışı) kapsayabilir: invoice_sales. Bir teslimat yalnızca bir geçerli faturada olur
--    (tekil kısmi indeks); fatura iptal edilince teslimat serbest kalır.
--  * Fatura satırları teslim edilen miktardan iade edilen düşülerek hesaplanır; aylık faturada aynı ürün/birim/fiyat/KDV birleşir.
--  * İsteğe bağlı eşik: aylık müşteride eşiği aşan teslimat toplu faturaya otomatik seçilmez (ayrı faturalanır).
--  * Hiçbir veri dışarı gönderilmez (F-26 geçerli). Canlıda fatura kaydı yokken kuruldu; eski kayıtlar invoice_sales'e taşınır.

-- ---------------------------------------------------------------- ayarlar
alter table public.customers add column if not exists billing_mode text not null default 'teslimat';
alter table public.customers drop constraint if exists customers_billing_mode_check;
alter table public.customers add constraint customers_billing_mode_check check (billing_mode in ('teslimat', 'aylik'));
alter table public.app_settings add column if not exists invoice_split_qty integer;
alter table public.app_settings drop constraint if exists app_settings_invoice_split_qty_check;
alter table public.app_settings add constraint app_settings_invoice_split_qty_check check (invoice_split_qty is null or invoice_split_qty between 1 and 100000);

-- ---------------------------------------------------------------- fatura ↔ teslimat
alter table public.invoices alter column sale_id drop not null;
alter table public.invoices add column if not exists kind text not null default 'teslimat';
alter table public.invoices drop constraint if exists invoices_kind_check;
alter table public.invoices add constraint invoices_kind_check check (kind in ('teslimat', 'aylik'));
alter table public.invoices add column if not exists customer_id uuid references public.customers(id);
alter table public.invoices add column if not exists period_start date;
alter table public.invoices add column if not exists period_end date;
create index if not exists invoices_customer on public.invoices(customer_id, created_at desc);

create table if not exists public.invoice_sales (
  invoice_id  uuid not null references public.invoices(id),
  sale_id     uuid not null references public.sales(id),
  business_id uuid not null references public.businesses(id),
  active      boolean not null default true,      -- fatura iptal edilince false; kayıt silinmez
  created_at  timestamptz not null default now(),
  primary key (invoice_id, sale_id)
);
-- Mükerrer fatura engeli: bir teslimat yalnızca bir geçerli faturada
create unique index if not exists invoice_sales_one_active on public.invoice_sales(sale_id) where active;
create index if not exists invoice_sales_sale on public.invoice_sales(sale_id);
alter table public.invoice_sales enable row level security;
drop policy if exists invoice_sales_select on public.invoice_sales;
create policy invoice_sales_select on public.invoice_sales for select to authenticated using (app.has_role(business_id, 'yonetici'));

-- Yalnızca active true → false değişebilir; silinemez
create or replace function app.tg_invoice_sales_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'Fatura teslimat kaydı silinemez' using errcode = '42501'; end if;
  if new.invoice_id <> old.invoice_id or new.sale_id <> old.sale_id or new.business_id <> old.business_id
     or (new.active and not old.active) then
    raise exception 'Fatura teslimat kaydı değiştirilemez' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists invoice_sales_guard on public.invoice_sales;
create trigger invoice_sales_guard before update or delete on public.invoice_sales for each row execute function app.tg_invoice_sales_guard();

-- Eski (tek satışlı) kayıtları taşı
insert into public.invoice_sales(invoice_id, sale_id, business_id, active, created_at)
select i.id, i.sale_id, i.business_id, i.status <> 'iptal', i.created_at
  from public.invoices i
 where i.sale_id is not null and not exists (select 1 from public.invoice_sales x where x.invoice_id = i.id);
update public.invoices i set customer_id = s.customer_id from public.sales s
 where s.id = i.sale_id and i.customer_id is null and s.customer_id is not null;

-- ---------------------------------------------------------------- alıcı bilgisi ve eksikler (tek çekirdek)
create or replace function app.invoice_party(p_customer uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare c public.customers; v_issues jsonb := '[]'; v_cust jsonb; v_kind text;
begin
  if p_customer is not null then select * into c from public.customers where id = p_customer; end if;
  if c.id is null then
    v_cust := jsonb_build_object('kind', 'nihai', 'name', 'Nihai tüketici');
    v_issues := v_issues || jsonb_build_object('level', 'warning', 'field', 'customer',
                  'message', 'Satışta müşteri seçilmemiş: nihai tüketici adına (e-Arşiv) düzenlenir. Logo dokümanıyla doğrulanacak.');
  else
    v_kind := app.tax_id_kind(c.tax_no);
    v_cust := jsonb_build_object('kind', coalesce(v_kind, 'yok'), 'id', c.id, 'code', c.code, 'name', c.name,
                'legal_title', coalesce(c.legal_title, c.name), 'tax_no', c.tax_no, 'tax_office', c.tax_office,
                'address', c.address, 'district', c.district, 'city', c.city, 'email', c.email, 'phone', c.phone,
                'channel', c.channel, 'billing_mode', c.billing_mode, 'logo_code', c.logo_code);
    if c.tax_no is null then
      v_issues := v_issues || jsonb_build_object('level', case when c.channel = 'kurumsal' then 'error' else 'warning' end, 'field', 'tax_no',
                    'message', case when c.channel = 'kurumsal' then 'Kurumsal müşterinin VKN/TCKN bilgisi yok'
                                    else 'VKN/TCKN yok: bireysel müşteri için e-Arşiv düzenlenebilir; Logo dokümanıyla doğrulanacak' end);
    elsif v_kind is null then
      v_issues := v_issues || jsonb_build_object('level', 'error', 'field', 'tax_no', 'message', 'VKN/TCKN geçersiz');
    end if;
    if v_kind = 'vkn' and c.tax_office is null then
      v_issues := v_issues || jsonb_build_object('level', 'error', 'field', 'tax_office', 'message', 'Vergi dairesi yok');
    end if;
    if v_kind = 'vkn' and c.legal_title is null then
      v_issues := v_issues || jsonb_build_object('level', 'warning', 'field', 'legal_title', 'message', 'Resmî unvan girilmemiş; kart adı kullanılacak');
    end if;
    if c.address is null then
      v_issues := v_issues || jsonb_build_object('level', case when v_kind = 'vkn' then 'error' else 'warning' end, 'field', 'address', 'message', 'Adres yok');
    end if;
    if c.city is null or c.district is null then
      v_issues := v_issues || jsonb_build_object('level', 'warning', 'field', 'city', 'message', 'İl / ilçe girilmemiş');
    end if;
    if c.email is null then
      v_issues := v_issues || jsonb_build_object('level', 'warning', 'field', 'email', 'message', 'E-posta yok: e-Arşiv fatura müşteriye e-postayla iletilemez');
    end if;
  end if;
  return jsonb_build_object('customer', v_cust, 'issues', v_issues, 'kind', v_kind);
end $$;

-- ---------------------------------------------------------------- fatura verisi: bir veya daha çok teslimattan
-- Satırlar: teslim edilen (satıştaki) miktar − iade edilen; aynı ürün + birim + birim fiyat + KDV oranı birleşir.
-- p_exclude: kendi faturası (yenilemede "zaten faturalanmış" sayılmasın)
create or replace function app.invoice_data(p_sales uuid[], p_exclude uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_n int; v_cust_n int; v_customer uuid; v_party jsonb; v_issues jsonb; v_lines jsonb; v_rates jsonb; v_tot jsonb; v_sales jsonb;
  v_dep numeric; v_ret numeric; v_bad jsonb; v_cancel jsonb; v_kind text; v_first public.sales; v_inv uuid;
begin
  if p_sales is null or cardinality(p_sales) = 0 then raise exception 'Faturalanacak teslimat seçilmedi' using errcode = '22023'; end if;
  select count(*), count(distinct coalesce(customer_id, '00000000-0000-0000-0000-000000000000'::uuid)), min(customer_id::text)::uuid
    into v_n, v_cust_n, v_customer
    from public.sales where id = any(p_sales);
  if v_n <> cardinality(array(select distinct unnest(p_sales))) then raise exception 'Satış bulunamadı' using errcode = 'P0002'; end if;
  if v_cust_n > 1 then raise exception 'Bir faturada yalnızca aynı müşterinin teslimatları birleşebilir' using errcode = '22023'; end if;

  v_party := app.invoice_party(v_customer);
  v_issues := v_party->'issues';
  v_kind := v_party->>'kind';

  with ri as (   -- satır bazında iade
    select r.sale_item_id, sum(r.qty) as qty, sum(r.refund_amount) as amount
      from public.return_items r join public.sale_items i on i.id = r.sale_item_id
     where i.sale_id = any(p_sales) group by r.sale_item_id),
  li as (
    select i.product_id, p.code, p.name, i.unit_name, i.unit_price, i.vat_rate, s.sold_at,
           i.qty - coalesce(ri.qty, 0) as qty,
           i.line_discount + i.bill_discount_share as discount,
           i.line_net - coalesce(ri.amount, 0) as gross
      from public.sale_items i
      join public.sales s on s.id = i.sale_id
      join public.products p on p.id = i.product_id
      left join ri on ri.sale_item_id = i.id
     where i.sale_id = any(p_sales) and s.status = 'tamamlandi'),
  g as (
    select product_id, code, name, unit_name, unit_price, vat_rate, min(sold_at) as first_at,
           sum(qty) as qty, sum(discount) as discount, sum(gross) as gross
      from li where qty > 0
     group by product_id, code, name, unit_name, unit_price, vat_rate)
  select coalesce(jsonb_agg(jsonb_build_object(
           'line_no', rn, 'product_code', code, 'name', name, 'unit', unit_name, 'qty', qty,
           'unit_price', unit_price, 'discount', discount, 'vat_rate', vat_rate, 'gross', gross,
           'net', round(gross * 100 / (100 + vat_rate), 2),
           'vat', gross - round(gross * 100 / (100 + vat_rate), 2),
           'unit_price_net', round(unit_price * 100 / (100 + vat_rate), 4)) order by rn), '[]')
    into v_lines
    from (select g.*, row_number() over (order by first_at, code, unit_price) as rn from g) z;

  select coalesce(jsonb_agg(jsonb_build_object('rate', r, 'net', n, 'vat', v, 'gross', gg) order by r), '[]') into v_rates
    from (select (l->>'vat_rate')::int r, sum((l->>'net')::numeric) n, sum((l->>'vat')::numeric) v, sum((l->>'gross')::numeric) gg
            from jsonb_array_elements(v_lines) l group by 1) z;
  select coalesce(sum(deposit_total), 0) into v_dep from public.sales where id = any(p_sales) and status = 'tamamlandi';
  select jsonb_build_object('net', coalesce(sum((l->>'net')::numeric), 0), 'vat', coalesce(sum((l->>'vat')::numeric), 0),
                            'gross', coalesce(sum((l->>'gross')::numeric), 0), 'deposit', v_dep, 'by_rate', v_rates)
    into v_tot from jsonb_array_elements(v_lines) l;

  -- Teslimatlar (izlenebilirlik): satış no, sipariş no, tarih, teslim − iade miktarı ve tutar
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'no', s.no, 'sold_at', s.sold_at, 'status', s.status, 'order_id', o.id, 'order_no', o.no,
           'qty', coalesce(q.qty, 0), 'gross', coalesce(q.gross, 0),
           'invoiced_by', (select x.invoice_id from public.invoice_sales x where x.sale_id = s.id and x.active
                             and x.invoice_id is distinct from p_exclude limit 1)) order by s.sold_at, s.no), '[]')
    into v_sales
    from public.sales s
    left join lateral (select o2.id, o2.no from public.orders o2 where o2.sale_id = s.id limit 1) o on true
    left join lateral (
      select sum(i.qty - coalesce((select sum(r.qty) from public.return_items r where r.sale_item_id = i.id), 0)) as qty,
             sum(i.line_net - coalesce((select sum(r.refund_amount) from public.return_items r where r.sale_item_id = i.id), 0)) as gross
        from public.sale_items i where i.sale_id = s.id) q on true
   where s.id = any(p_sales);

  select jsonb_agg(x->'no') into v_cancel from jsonb_array_elements(v_sales) x where x->>'status' <> 'tamamlandi';
  if v_cancel is not null then
    v_issues := v_issues || jsonb_build_object('level', 'error', 'field', 'sale', 'message', 'İptal edilmiş satış faturalanamaz: #' || (select string_agg(e::text, ', #') from jsonb_array_elements(v_cancel) e));
  end if;
  select jsonb_agg(x->'no') into v_bad from jsonb_array_elements(v_sales) x where x->>'invoiced_by' is not null;
  if v_bad is not null then
    v_issues := v_issues || jsonb_build_object('level', 'error', 'field', 'sale', 'message', 'Zaten faturalanmış teslimat: #' || (select string_agg(e::text, ', #') from jsonb_array_elements(v_bad) e));
  end if;
  if jsonb_array_length(v_lines) = 0 then
    v_issues := v_issues || jsonb_build_object('level', 'error', 'field', 'lines', 'message', 'Faturalanacak ürün yok (tamamı iade edilmiş olabilir)');
  end if;
  if v_dep <> 0 then
    v_issues := v_issues || jsonb_build_object('level', 'warning', 'field', 'deposit',
                  'message', 'Depozito (' || v_dep || ' TL) faturaya eklenmedi: mali müşavir kararı bekleniyor');
  end if;
  select coalesce(sum(r.qty), 0) into v_ret from public.return_items r join public.sale_items i on i.id = r.sale_item_id where i.sale_id = any(p_sales);
  if v_ret > 0 then
    v_issues := v_issues || jsonb_build_object('level', 'warning', 'field', 'returns',
                  'message', 'İade edilen ' || v_ret || ' birim faturadan düşüldü; yalnızca müşteride kalan miktar faturalanır');
  end if;

  select * into v_first from public.sales where id = any(p_sales) order by sold_at, no limit 1;
  if cardinality(p_sales) = 1 then
    select x.invoice_id into v_inv from public.invoice_sales x where x.sale_id = p_sales[1] and x.active limit 1;
  end if;
  return jsonb_build_object(
    'sale', jsonb_build_object('id', v_first.id, 'no', v_first.no, 'sold_at', v_first.sold_at, 'status', v_first.status, 'grand_total', v_first.grand_total),
    'sales', v_sales,
    'period_start', (select min(app.local_date(sold_at)) from public.sales where id = any(p_sales)),
    'period_end', (select max(app.local_date(sold_at)) from public.sales where id = any(p_sales)),
    'customer', v_party->'customer', 'lines', v_lines, 'totals', v_tot, 'issues', v_issues,
    'invoice_id', v_inv,
    'doc_type_hint', case when v_kind = 'vkn' then 'Alıcı e-Fatura mükellefiyse e-Fatura, değilse e-Arşiv (Logo/GİB sorgusuyla belirlenecek)'
                          else 'e-Arşiv (bireysel / nihai tüketici)' end);
end $$;

-- Eski tek satış çekirdeği aynı hesabı kullanır
create or replace function app.sale_invoice_data(p_sale uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select app.invoice_data(array[p_sale])
$$;

-- Çoklu önizleme (kontrol ekranı)
create or replace function public.invoice_preview_multi(p_business uuid, p_sales uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform app.require_role(p_business, 'yonetici');
  if exists (select 1 from public.sales where id = any(p_sales) and business_id <> p_business) then
    raise exception 'Satış bulunamadı' using errcode = 'P0002';
  end if;
  return app.invoice_data(p_sales);
end $$;

-- ---------------------------------------------------------------- fatura kaydı oluşturma
-- p_kind: 'teslimat' (tek teslimat) | 'aylik' (aynı müşteri + aynı ay, müşteri yöntemi aylık olmalı)
create or replace function public.create_invoice(p_business uuid, p_sales uuid[], p_kind text, p_note text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v jsonb; v_id uuid; v_ids uuid[]; v_n int; v_cust uuid; v_mode text; v_months int; v_dup text;
begin
  perform app.require_role(p_business, 'yonetici');
  v_ids := array(select distinct unnest(coalesce(p_sales, '{}')) order by 1);
  if cardinality(v_ids) = 0 then raise exception 'Faturalanacak teslimat seçilmedi' using errcode = '22023'; end if;
  if cardinality(v_ids) > 300 then raise exception 'Bir faturada en fazla 300 teslimat olabilir' using errcode = '22023'; end if;
  if p_kind not in ('teslimat', 'aylik') then raise exception 'Fatura türü geçersiz' using errcode = '22023'; end if;
  -- Satırları sırayla kilitle (aynı anda iki fatura denemesi beklemeye girer)
  perform 1 from public.sales where id = any(v_ids) and business_id = p_business order by id for update;
  select count(*) into v_n from public.sales where id = any(v_ids) and business_id = p_business;
  if v_n <> cardinality(v_ids) then raise exception 'Satış bulunamadı' using errcode = 'P0002'; end if;

  if p_kind = 'teslimat' and cardinality(v_ids) <> 1 then
    raise exception 'Sevkiyat başına faturada her teslimat ayrı faturalanır' using errcode = '22023';
  end if;
  select count(distinct coalesce(customer_id, '00000000-0000-0000-0000-000000000000'::uuid)), min(customer_id::text)::uuid,
         count(distinct date_trunc('month', app.local_date(sold_at)))
    into v_n, v_cust, v_months from public.sales where id = any(v_ids);
  if v_n > 1 then raise exception 'Bir faturada yalnızca aynı müşterinin teslimatları birleşebilir' using errcode = '22023'; end if;
  if p_kind = 'aylik' then
    if v_cust is null then raise exception 'Müşterisiz satış aylık faturaya eklenemez' using errcode = '22023'; end if;
    select billing_mode into v_mode from public.customers where id = v_cust;
    if v_mode <> 'aylik' then
      raise exception 'Bu müşterinin fatura yöntemi "sevkiyat başına"; teslimatlar ayrı faturalanır' using errcode = '22023';
    end if;
    if v_months > 1 then raise exception 'Aylık faturada yalnızca aynı ayın teslimatları birleşir' using errcode = '22023'; end if;
  end if;
  select string_agg('#' || s.no, ', ' order by s.no) into v_dup
    from public.sales s join public.invoice_sales x on x.sale_id = s.id and x.active where s.id = any(v_ids);
  if v_dup is not null then raise exception 'Bu teslimat zaten faturalanmış: %', v_dup using errcode = 'P0001'; end if;
  if exists (select 1 from public.sales where id = any(v_ids) and status <> 'tamamlandi') then
    raise exception 'İptal edilmiş satış faturalanamaz' using errcode = '22023';
  end if;

  v := app.invoice_data(v_ids);
  if jsonb_array_length(v->'lines') = 0 then raise exception 'Faturalanacak ürün yok (tamamı iade edilmiş olabilir)' using errcode = '22023'; end if;
  insert into public.invoices(business_id, sale_id, kind, customer_id, period_start, period_end, no, customer, lines, totals, issues, note, created_by)
  values (p_business, case when p_kind = 'teslimat' then v_ids[1] end, p_kind, v_cust,
          (v->>'period_start')::date, (v->>'period_end')::date,
          app.next_number(p_business, 'fatura'), v->'customer', v->'lines', v->'totals', v->'issues',
          nullif(trim(coalesce(p_note, '')), ''), auth.uid())
  returning id into v_id;
  insert into public.invoice_sales(invoice_id, sale_id, business_id) select v_id, unnest(v_ids), p_business;
  insert into public.invoice_events(invoice_id, business_id, user_id, event, detail)
  values (v_id, p_business, auth.uid(), 'taslak', jsonb_build_object('kind', p_kind, 'teslimat', cardinality(v_ids),
          'issues', jsonb_array_length(v->'issues')));
  return v_id;
exception when unique_violation then
  raise exception 'Bu teslimat zaten faturalanmış' using errcode = '23505';
end $$;

-- Eski tek satış çağrısı (satış detayı) aynı yolu kullanır
create or replace function public.create_invoice_draft(p_business uuid, p_sale uuid, p_note text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if exists (select 1 from public.invoice_sales where sale_id = p_sale and active) then
    raise exception 'Bu satış için fatura kaydı zaten var' using errcode = '23505';
  end if;
  return public.create_invoice(p_business, array[p_sale], 'teslimat', p_note);
end $$;

-- ---------------------------------------------------------------- eylemler (yenile/hazırla/taslağa/iptal/elle kesildi)
create or replace function public.invoice_action(p_business uuid, p_invoice uuid, p_action text, p_note text default null) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare inv public.invoices; v jsonb; v_errors int; v_sales uuid[];
begin
  perform app.require_role(p_business, 'yonetici');
  select * into inv from public.invoices where id = p_invoice and business_id = p_business for update;
  if inv.id is null then raise exception 'Fatura kaydı bulunamadı' using errcode = 'P0002'; end if;
  v_sales := array(select sale_id from public.invoice_sales where invoice_id = inv.id and active order by sale_id);

  if p_action in ('yenile', 'hazirla') then
    if inv.status <> 'taslak' then raise exception 'Yalnızca taslak güncellenebilir / gönderime hazırlanabilir' using errcode = '22023'; end if;
    v := app.invoice_data(v_sales, inv.id);
    select count(*) into v_errors from jsonb_array_elements(v->'issues') x where x->>'level' = 'error';
    if p_action = 'hazirla' and v_errors > 0 then
      raise exception 'Eksik bilgi var (% hata): önce düzeltin', v_errors using errcode = '22023';
    end if;
    update public.invoices set customer = v->'customer', lines = v->'lines', totals = v->'totals', issues = v->'issues',
           status = case when p_action = 'hazirla' then 'hazir' else status end,
           prepared_by = case when p_action = 'hazirla' then auth.uid() else prepared_by end,
           prepared_at = case when p_action = 'hazirla' then now() else prepared_at end
     where id = inv.id;
  elsif p_action = 'taslaga' then
    if inv.status <> 'hazir' then raise exception 'Yalnızca gönderime hazır kayıt taslağa alınabilir' using errcode = '22023'; end if;
    update public.invoices set status = 'taslak', prepared_by = null, prepared_at = null where id = inv.id;
  elsif p_action = 'iptal' then
    if inv.status not in ('taslak', 'hazir', 'hatali') then
      raise exception 'Gönderilmiş fatura buradan iptal edilemez; Logo İşbaşı üzerinden iptal/iade yapılır' using errcode = '22023';
    end if;
    if length(trim(coalesce(p_note, ''))) < 3 then raise exception 'İptal nedeni yazın' using errcode = '22023'; end if;
    update public.invoices set status = 'iptal', cancelled_by = auth.uid(), cancelled_at = now(), cancel_reason = trim(p_note) where id = inv.id;
    update public.invoice_sales set active = false where invoice_id = inv.id and active;   -- teslimatlar yeniden faturalanabilir
  elsif p_action = 'elle_kesildi' then
    -- F-29: Logo bağlantısı yokken fatura İşbaşı ekranından kesildiyse resmî numarasıyla işaretlenir (hiçbir yere gönderim yapılmaz)
    if inv.status not in ('taslak', 'hazir', 'hatali') then
      raise exception 'Bu kayıt zaten kesilmiş veya iptal edilmiş' using errcode = '22023';
    end if;
    if length(trim(coalesce(p_note, ''))) < 3 then raise exception 'İşbaşı''ndaki fatura numarasını yazın' using errcode = '22023'; end if;
    if exists (select 1 from public.invoices where business_id = p_business and logo_invoice_no = trim(p_note)
                and status <> 'iptal' and id <> inv.id) then
      raise exception 'Bu fatura numarası başka bir satışa işlenmiş' using errcode = '23505';
    end if;
    update public.invoices set status = 'resmilesti', logo_invoice_no = trim(p_note), environment = 'canli', sent_at = now(),
           gib_status = 'elle'
     where id = inv.id;
  else
    raise exception 'Geçersiz işlem' using errcode = '22023';
  end if;
  insert into public.invoice_events(invoice_id, business_id, user_id, event, detail)
  values (inv.id, p_business, auth.uid(), p_action, case when p_note is not null then jsonb_build_object('note', left(p_note, 500)) end);
  return (select status from public.invoices where id = inv.id);
end $$;

-- ---------------------------------------------------------------- listeler
drop function if exists public.uninvoiced_sales(uuid, boolean, integer, integer);
create or replace function public.uninvoiced_sales(p_business uuid, p_only_customer boolean default true, p_limit integer default 50, p_offset integer default 0)
returns table(id uuid, no bigint, sold_at timestamptz, customer_id uuid, customer_name text, channel text, tax_kind text, grand_total numeric,
              billing_mode text, order_no bigint, qty bigint, total_count bigint)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  perform app.require_role(p_business, 'yonetici');
  return query
  select s.id, s.no, s.sold_at, s.customer_id, c.name, c.channel, app.tax_id_kind(c.tax_no), s.grand_total,
         c.billing_mode, (select o.no from public.orders o where o.sale_id = s.id limit 1),
         (select coalesce(sum(i.qty), 0) from public.sale_items i where i.sale_id = s.id)::bigint,
         count(*) over ()
    from public.sales s left join public.customers c on c.id = s.customer_id
   where s.business_id = p_business and s.status = 'tamamlandi'
     and (not p_only_customer or s.customer_id is not null)
     and not exists (select 1 from public.invoice_sales x where x.sale_id = s.id and x.active)
   order by s.sold_at desc
   limit least(greatest(coalesce(p_limit, 50), 1), 200) offset greatest(coalesce(p_offset, 0), 0);
end $$;

-- Aylık toplu faturalanacaklar: aylık yöntemli müşterilerin seçilen aydaki faturalanmamış teslimatları
create or replace function public.monthly_billing(p_business uuid, p_month date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_from date := date_trunc('month', p_month)::date; v_to date; v_split int; v_customers jsonb; v_months jsonb;
begin
  perform app.require_role(p_business, 'yonetici');
  v_to := (v_from + interval '1 month')::date;
  select invoice_split_qty into v_split from public.app_settings where business_id = p_business;
  with s as (
    select sa.id, sa.no, sa.sold_at, sa.customer_id,
           (select o.no from public.orders o where o.sale_id = sa.id limit 1) as order_no,
           (select coalesce(sum(i.qty), 0) from public.sale_items i where i.sale_id = sa.id) as qty,
           sa.goods_net as total
      from public.sales sa join public.customers c on c.id = sa.customer_id
     where sa.business_id = p_business and sa.status = 'tamamlandi' and c.billing_mode = 'aylik'
       and sa.sold_at >= (v_from::timestamp at time zone 'Europe/Istanbul')
       and sa.sold_at < (v_to::timestamp at time zone 'Europe/Istanbul')
       and not exists (select 1 from public.invoice_sales x where x.sale_id = sa.id and x.active)),
  g as (
    select customer_id, count(*) as n, sum(total) as total,
           jsonb_agg(jsonb_build_object('id', id, 'no', no, 'sold_at', sold_at, 'order_no', order_no, 'qty', qty, 'total', total,
                     'over', v_split is not null and qty >= v_split) order by sold_at, no) as sales
      from s group by customer_id)
  select coalesce(jsonb_agg(jsonb_build_object('customer_id', c.id, 'code', c.code, 'name', c.name, 'legal_title', c.legal_title,
                     'channel', c.channel, 'tax_kind', app.tax_id_kind(c.tax_no), 'count', g.n, 'total', g.total,
                     'sales', g.sales) order by c.name), '[]'::jsonb)
    into v_customers
    from g join public.customers c on c.id = g.customer_id;

  select coalesce(jsonb_agg(m order by m desc), '[]'::jsonb) into v_months
    from (select distinct date_trunc('month', app.local_date(sa.sold_at))::date as m
            from public.sales sa join public.customers c on c.id = sa.customer_id
           where sa.business_id = p_business and sa.status = 'tamamlandi' and c.billing_mode = 'aylik'
             and not exists (select 1 from public.invoice_sales x where x.sale_id = sa.id and x.active)) mm;

  return jsonb_build_object('month', v_from, 'split_qty', v_split, 'customers', v_customers, 'pending_months', v_months,
    'aylik_customers', (select count(*) from public.customers where business_id = p_business and billing_mode = 'aylik'));
end $$;

-- ---------------------------------------------------------------- ayar RPC'leri
create or replace function public.set_customer_billing_mode(p_business uuid, p_customer uuid, p_mode text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_old text;
begin
  perform app.require_role(p_business, 'yonetici');
  if p_mode not in ('teslimat', 'aylik') then raise exception 'Fatura yöntemi geçersiz' using errcode = '22023'; end if;
  select billing_mode into v_old from public.customers where id = p_customer and business_id = p_business for update;
  if v_old is null then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
  if v_old = p_mode then return; end if;
  update public.customers set billing_mode = p_mode where id = p_customer;
  perform app.audit(p_business, 'fatura_yontemi', 'customers', p_customer::text,
                    jsonb_build_object('billing_mode', v_old), jsonb_build_object('billing_mode', p_mode));
end $$;

create or replace function public.set_invoice_split_qty(p_business uuid, p_qty integer) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app.require_role(p_business, 'yonetici');
  if p_qty is not null and (p_qty < 1 or p_qty > 100000) then raise exception 'Eşik 1 ile 100000 arasında olmalı' using errcode = '22023'; end if;
  insert into public.app_settings(business_id, invoice_split_qty) values (p_business, p_qty)
  on conflict (business_id) do update set invoice_split_qty = excluded.invoice_split_qty, updated_at = now();
  perform app.audit(p_business, 'fatura_esik', 'app_settings', p_business::text, null, jsonb_build_object('invoice_split_qty', p_qty));
end $$;

-- ---------------------------------------------------------------- gelir-gider: faturalı sayılma yeni bağlantıdan
-- (profit_report aşağıda 0039'dakiyle aynı; yalnızca "faturalı" kontrolü invoice_sales üzerinden)
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
  res as (
    select pr.ps, pr.pe,
           coalesce(sl.invoiced, 0) as inv, coalesce(sl.uninvoiced, 0) as uninv, coalesce(sl.n, 0) as n,
           coalesce(rt.refund, 0) as refund,
           coalesce(pu.amount, 0) as purchases, coalesce(pu.n, 0) as pn,
           coalesce(ex.amount, 0) as expenses, coalesce(exc.cats, '{}'::jsonb) as cats,
           coalesce(sl.cost, 0) - coalesce(rt.rcost, 0) as cogs
      from periods pr
      left join sl on sl.ps = pr.ps left join rt on rt.ps = pr.ps left join pu on pu.ps = pr.ps
      left join ex on ex.ps = pr.ps left join exc on exc.ps = pr.ps)
  select jsonb_build_object(
    'periods', coalesce(jsonb_agg(jsonb_build_object(
        'start', r.ps, 'end', r.pe, 'sales_count', r.n,
        'income_invoiced', r.inv, 'income_uninvoiced', r.uninv, 'returns', r.refund,
        'income', r.inv + r.uninv - r.refund,
        'purchases', r.purchases, 'purchase_count', r.pn,
        'expenses', r.expenses, 'expense_categories', r.cats,
        'total_cost', r.purchases + r.expenses,
        'gross_profit', r.inv + r.uninv - r.refund - r.purchases,
        'net_profit', r.inv + r.uninv - r.refund - r.purchases - r.expenses,
        'cogs', r.cogs) order by r.ps), '[]'::jsonb),
    'pending_purchases', (select count(*) from public.purchases p where p.business_id = p_business and p.status = 'onay_bekliyor'
                            and p.doc_date between p_from and p_to))
    into v
    from res r;
  return v;
end $$;

select app.apply_grants();
