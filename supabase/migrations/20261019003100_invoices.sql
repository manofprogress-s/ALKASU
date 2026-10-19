-- ALKASU 0031 — Fatura arayüzü (Logo İşbaşı bağlantısı OLMADAN): müşteri fatura bilgileri, satıştan fatura önizlemesi,
-- taslak / gönderime hazır kayıtları, mükerrer fatura engeli ve olay geçmişi.
-- Kural: BUSINESS_RULES §28 (F-20…F-27) · Karar: D-089
-- Bu sürüm hiçbir dış sisteme veri GÖNDERMEZ. "gonderiliyor / gonderildi / resmilesti / hatali" durumlarına yalnızca ileride
-- Logo entegrasyonunun sunucu kodu geçirebilir; kullanıcı fonksiyonları bu durumlara geçiş yapamaz.

-- ---------------------------------------------------------------------------
-- 1) Müşteri fatura bilgileri
-- ---------------------------------------------------------------------------
alter table public.customers add column if not exists legal_title text check (length(legal_title) <= 250);
alter table public.customers add column if not exists tax_office  text check (length(tax_office) <= 100);
alter table public.customers add column if not exists email       text check (length(email) <= 200);
alter table public.customers add column if not exists city        text check (length(city) <= 60);

-- VKN (10 hane, GİB algoritması) / TCKN (11 hane) doğrulaması: 'vkn' | 'tckn' | null (geçersiz/boş)
create or replace function app.tax_id_kind(p text) returns text
language plpgsql immutable as $$
declare d text := regexp_replace(coalesce(p, ''), '\D', '', 'g'); s int := 0; t int; i int; o int; e int;
begin
  if length(d) = 10 then
    for i in 0..8 loop
      t := (substr(d, i + 1, 1)::int + 9 - i) % 10;
      o := (t * (2 ^ (9 - i))::int) % 9;
      s := s + case when t <> 0 and o = 0 then 9 else o end;
    end loop;
    return case when (10 - s % 10) % 10 = substr(d, 10, 1)::int then 'vkn' end;
  elsif length(d) = 11 then
    if left(d, 1) = '0' then return null; end if;
    o := substr(d,1,1)::int + substr(d,3,1)::int + substr(d,5,1)::int + substr(d,7,1)::int + substr(d,9,1)::int;
    e := substr(d,2,1)::int + substr(d,4,1)::int + substr(d,6,1)::int + substr(d,8,1)::int;
    if ((o * 7 - e) % 10 + 10) % 10 <> substr(d, 10, 1)::int then return null; end if;
    s := 0; for i in 1..10 loop s := s + substr(d, i, 1)::int; end loop;
    return case when s % 10 = substr(d, 11, 1)::int then 'tckn' end;
  end if;
  return null;
end $$;

-- Personel fatura bilgisini girer (bayiye ait kartlar hariç)
create or replace function public.set_customer_billing(p_business uuid, p_customer uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_tax text := nullif(regexp_replace(coalesce(p->>'tax_no', ''), '\D', '', 'g'), ''); v_mail text := nullif(lower(trim(coalesce(p->>'email', ''))), '');
        v_old public.customers;
begin
  perform app.require_role(p_business, 'yonetici', 'satis', 'sevkiyat');
  select * into v_old from public.customers where id = p_customer and business_id = p_business;
  if v_old.id is null then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
  if v_old.owner_dealer_id is not null then raise exception 'Bayiye ait müşterinin bilgisi bayi tarafından değiştirilir' using errcode = '42501'; end if;
  if v_tax is not null and app.tax_id_kind(v_tax) is null then
    raise exception 'Vergi / T.C. kimlik numarası geçersiz (VKN 10, TCKN 11 hane ve doğrulama hanesi tutmalı)' using errcode = '22023';
  end if;
  if v_mail is not null and v_mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'E-posta adresi geçersiz' using errcode = '22023';
  end if;
  update public.customers set
    legal_title = nullif(trim(coalesce(p->>'legal_title', '')), ''),
    tax_no      = v_tax,
    tax_office  = nullif(trim(coalesce(p->>'tax_office', '')), ''),
    email       = v_mail,
    city        = case when p ? 'city' then nullif(trim(coalesce(p->>'city', '')), '') else city end,
    district    = case when p ? 'district' then nullif(trim(coalesce(p->>'district', '')), '') else district end,
    address     = case when p ? 'address' then nullif(trim(coalesce(p->>'address', '')), '') else address end
  where id = p_customer;
  perform app.audit(p_business, 'fatura_bilgisi', 'customers', p_customer::text,
                    jsonb_build_object('tax_no', v_old.tax_no, 'tax_office', v_old.tax_office, 'legal_title', v_old.legal_title),
                    jsonb_build_object('tax_no', v_tax, 'tax_office', p->>'tax_office', 'legal_title', p->>'legal_title'));
  return jsonb_build_object('tax_kind', app.tax_id_kind(v_tax));
end $$;

-- ---------------------------------------------------------------------------
-- 2) Fatura kayıtları
-- ---------------------------------------------------------------------------
create table if not exists public.invoices (
  id              uuid primary key default gen_random_uuid(),
  business_id     uuid not null references public.businesses(id),
  sale_id         uuid not null references public.sales(id),
  no              bigint not null,                       -- ALKASU iç numarası (resmî fatura no değildir)
  status          text not null default 'taslak'
                  check (status in ('taslak', 'hazir', 'gonderiliyor', 'gonderildi', 'resmilesti', 'hatali', 'iptal')),
  doc_type        text check (doc_type in ('e_fatura', 'e_arsiv')),   -- Logo/GİB sorgusuyla belirlenecek
  environment     text check (environment in ('test', 'canli')),
  customer        jsonb not null,
  lines           jsonb not null,
  totals          jsonb not null,
  issues          jsonb not null default '[]',
  note            text check (length(note) <= 500),
  logo_ref        text,          -- Logo tarafındaki kayıt kimliği
  logo_invoice_no text,          -- resmî fatura numarası
  ettn            uuid,          -- e-belge UUID
  gib_status      text,
  last_error      text,
  attempts        integer not null default 0,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  prepared_by     uuid,
  prepared_at     timestamptz,
  sent_at         timestamptz,
  cancelled_by    uuid,
  cancelled_at    timestamptz,
  cancel_reason   text,
  unique (business_id, no)
);
-- Mükerrer fatura engeli: bir satışın iptal edilmemiş tek fatura kaydı olabilir
create unique index if not exists invoices_one_per_sale on public.invoices(sale_id) where status <> 'iptal';
create index if not exists invoices_business_status on public.invoices(business_id, status, created_at desc);
alter table public.invoices enable row level security;
drop policy if exists invoices_select on public.invoices;
create policy invoices_select on public.invoices for select to authenticated using (app.has_role(business_id, 'yonetici'));
drop trigger if exists invoices_touch on public.invoices;
create trigger invoices_touch before update on public.invoices for each row execute function app.touch_updated_at();
drop trigger if exists invoices_audit on public.invoices;
create trigger invoices_audit after insert or update on public.invoices for each row execute function audit.tg_row();

create table if not exists public.invoice_events (
  id          bigint generated always as identity primary key,
  invoice_id  uuid not null references public.invoices(id),
  business_id uuid not null references public.businesses(id),
  at          timestamptz not null default now(),
  user_id     uuid,
  event       text not null,
  detail      jsonb               -- gizli erişim bilgisi YAZILMAZ
);
create index if not exists invoice_events_invoice on public.invoice_events(invoice_id, at);
alter table public.invoice_events enable row level security;
drop policy if exists invoice_events_select on public.invoice_events;
create policy invoice_events_select on public.invoice_events for select to authenticated using (app.has_role(business_id, 'yonetici'));
drop trigger if exists invoice_events_immutable on public.invoice_events;
create trigger invoice_events_immutable before update or delete on public.invoice_events for each row execute function app.tg_immutable();

-- ---------------------------------------------------------------------------
-- 3) Satıştan fatura verisi (önizleme ve taslak aynı çekirdeği kullanır)
-- Fiyatlar KDV dahildir: KDV hariç = round(satır net × 100 / (100 + oran), 2), KDV = satır net − KDV hariç.
-- ---------------------------------------------------------------------------
create or replace function app.sale_invoice_data(p_sale uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  s public.sales; c public.customers; v_issues jsonb := '[]'; v_lines jsonb; v_cust jsonb; v_kind text; v_tot jsonb; v_rates jsonb;
  v_returns numeric; v_inv public.invoices;
begin
  select * into s from public.sales where id = p_sale;
  if s.id is null then raise exception 'Satış bulunamadı' using errcode = 'P0002'; end if;
  if s.customer_id is not null then select * into c from public.customers where id = s.customer_id; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'line_no', i.line_no, 'product_code', p.code, 'name', p.name, 'unit', i.unit_name, 'qty', i.qty,
           'unit_price', i.unit_price, 'discount', i.line_discount + i.bill_discount_share,
           'vat_rate', i.vat_rate, 'gross', i.line_net,
           'net', round(i.line_net * 100 / (100 + i.vat_rate), 2),
           'vat', i.line_net - round(i.line_net * 100 / (100 + i.vat_rate), 2),
           'unit_price_net', round(i.unit_price * 100 / (100 + i.vat_rate), 4)) order by i.line_no), '[]')
    into v_lines
    from public.sale_items i join public.products p on p.id = i.product_id
   where i.sale_id = p_sale;

  select coalesce(jsonb_agg(jsonb_build_object('rate', r, 'net', n, 'vat', v, 'gross', g) order by r), '[]') into v_rates
    from (select (l->>'vat_rate')::int r, sum((l->>'net')::numeric) n, sum((l->>'vat')::numeric) v, sum((l->>'gross')::numeric) g
            from jsonb_array_elements(v_lines) l group by 1) z;
  select jsonb_build_object('net', coalesce(sum((l->>'net')::numeric), 0), 'vat', coalesce(sum((l->>'vat')::numeric), 0),
                            'gross', coalesce(sum((l->>'gross')::numeric), 0), 'deposit', s.deposit_total, 'by_rate', v_rates)
    into v_tot from jsonb_array_elements(v_lines) l;

  -- Alıcı
  if c.id is null then
    v_cust := jsonb_build_object('kind', 'nihai', 'name', 'Nihai tüketici');
    v_issues := v_issues || jsonb_build_object('level', 'warning', 'field', 'customer',
                  'message', 'Satışta müşteri seçilmemiş: nihai tüketici adına (e-Arşiv) düzenlenir. Logo dokümanıyla doğrulanacak.');
  else
    v_kind := app.tax_id_kind(c.tax_no);
    v_cust := jsonb_build_object('kind', coalesce(v_kind, 'yok'), 'id', c.id, 'code', c.code, 'name', c.name,
                'legal_title', coalesce(c.legal_title, c.name), 'tax_no', c.tax_no, 'tax_office', c.tax_office,
                'address', c.address, 'district', c.district, 'city', c.city, 'email', c.email, 'phone', c.phone, 'channel', c.channel);
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

  -- Satış
  if s.status <> 'tamamlandi' then
    v_issues := v_issues || jsonb_build_object('level', 'error', 'field', 'sale', 'message', 'İptal edilmiş satış faturalanamaz');
  end if;
  if jsonb_array_length(v_lines) = 0 then
    v_issues := v_issues || jsonb_build_object('level', 'error', 'field', 'lines', 'message', 'Satışta ürün yok');
  end if;
  if s.deposit_total <> 0 then
    v_issues := v_issues || jsonb_build_object('level', 'warning', 'field', 'deposit',
                  'message', 'Depozito (' || s.deposit_total || ' TL) faturaya eklenmedi: mali müşavir kararı bekleniyor');
  end if;
  select coalesce(sum(total_refund), 0) into v_returns from public.returns where sale_id = p_sale;
  if v_returns > 0 then
    v_issues := v_issues || jsonb_build_object('level', 'warning', 'field', 'returns',
                  'message', 'Bu satışta ' || v_returns || ' TL iade var: fatura satış tutarıyla hazırlanır, iade faturası ayrıca değerlendirilecek');
  end if;
  select * into v_inv from public.invoices where sale_id = p_sale and status <> 'iptal' limit 1;

  return jsonb_build_object(
    'sale', jsonb_build_object('id', s.id, 'no', s.no, 'sold_at', s.sold_at, 'status', s.status, 'grand_total', s.grand_total),
    'customer', v_cust, 'lines', v_lines, 'totals', v_tot, 'issues', v_issues,
    'invoice_id', v_inv.id,
    'doc_type_hint', case when v_kind = 'vkn' then 'Alıcı e-Fatura mükellefiyse e-Fatura, değilse e-Arşiv (Logo/GİB sorgusuyla belirlenecek)'
                          else 'e-Arşiv (bireysel / nihai tüketici)' end);
end $$;

create or replace function public.invoice_preview(p_sale uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_b uuid;
begin
  select business_id into v_b from public.sales where id = p_sale;
  if v_b is null then raise exception 'Satış bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(v_b, 'yonetici');
  return app.sale_invoice_data(p_sale);
end $$;

-- Taslak oluşturma: satır kilitlenir; aynı satışın iptal edilmemiş ikinci faturası açılamaz (çift tık / iki sekme)
create or replace function public.create_invoice_draft(p_business uuid, p_sale uuid, p_note text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v jsonb; v_id uuid;
begin
  perform app.require_role(p_business, 'yonetici');
  perform 1 from public.sales where id = p_sale and business_id = p_business for update;
  if not found then raise exception 'Satış bulunamadı' using errcode = 'P0002'; end if;
  if exists (select 1 from public.invoices where sale_id = p_sale and status <> 'iptal') then
    raise exception 'Bu satış için fatura kaydı zaten var' using errcode = '23505';
  end if;
  v := app.sale_invoice_data(p_sale);
  if (v->'sale'->>'status') <> 'tamamlandi' then raise exception 'İptal edilmiş satış faturalanamaz' using errcode = '22023'; end if;
  insert into public.invoices(business_id, sale_id, no, customer, lines, totals, issues, note, created_by)
  values (p_business, p_sale, app.next_number(p_business, 'fatura'), v->'customer', v->'lines', v->'totals', v->'issues',
          nullif(trim(coalesce(p_note, '')), ''), auth.uid())
  returning id into v_id;
  insert into public.invoice_events(invoice_id, business_id, user_id, event, detail)
  values (v_id, p_business, auth.uid(), 'taslak', jsonb_build_object('issues', jsonb_array_length(v->'issues')));
  return v_id;
end $$;

-- Kullanıcı eylemleri: yenile (taslak), hazirla (taslak → hazir; hata olmamalı), taslaga (hazir → taslak), iptal
create or replace function public.invoice_action(p_business uuid, p_invoice uuid, p_action text, p_note text default null) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare inv public.invoices; v jsonb; v_errors int;
begin
  perform app.require_role(p_business, 'yonetici');
  select * into inv from public.invoices where id = p_invoice and business_id = p_business for update;
  if inv.id is null then raise exception 'Fatura kaydı bulunamadı' using errcode = 'P0002'; end if;

  if p_action in ('yenile', 'hazirla') then
    if inv.status <> 'taslak' then raise exception 'Yalnızca taslak güncellenebilir / gönderime hazırlanabilir' using errcode = '22023'; end if;
    v := app.sale_invoice_data(inv.sale_id);
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
  else
    raise exception 'Geçersiz işlem' using errcode = '22023';
  end if;
  insert into public.invoice_events(invoice_id, business_id, user_id, event, detail)
  values (inv.id, p_business, auth.uid(), p_action, case when p_note is not null then jsonb_build_object('note', left(p_note, 500)) end);
  return (select status from public.invoices where id = inv.id);
end $$;

-- Faturalanmamış satışlar (tamamlanmış, iptal edilmemiş fatura kaydı yok)
create or replace function public.uninvoiced_sales(p_business uuid, p_only_customer boolean default true, p_limit integer default 50, p_offset integer default 0)
returns table(id uuid, no bigint, sold_at timestamptz, customer_id uuid, customer_name text, channel text, tax_kind text, grand_total numeric, total_count bigint)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  perform app.require_role(p_business, 'yonetici');
  return query
  select s.id, s.no, s.sold_at, s.customer_id, c.name, c.channel, app.tax_id_kind(c.tax_no), s.grand_total, count(*) over ()
    from public.sales s left join public.customers c on c.id = s.customer_id
   where s.business_id = p_business and s.status = 'tamamlandi'
     and (not p_only_customer or s.customer_id is not null)
     and not exists (select 1 from public.invoices i where i.sale_id = s.id and i.status <> 'iptal')
   order by s.sold_at desc
   limit least(greatest(coalesce(p_limit, 50), 1), 200) offset greatest(coalesce(p_offset, 0), 0);
end $$;

select app.apply_grants();
