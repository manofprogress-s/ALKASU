-- 19.10.2026 yayını: abone listesi aktarma, müşteri durum raporu, arama kaydı (0027). Mevcut veriye dokunmaz; yalnızca yeni sütun/tablo/fonksiyon.
begin;
-- ALKASU 0027 — Abone listesi içe aktarma + Müşteri durum raporu + arama kaydı
-- Kural: BUSINESS_RULES §27 (M-20…M-26) · Karar: D-087
-- 1) Eski sistemin abone listesi (abone no, tür, marka, saha, son satış, alım periyodu, sipariş sayısı, borç, konum…)
--    müşteri kartına işlenir. Aynı dosya tekrar yüklenirse abone no ile güncellenir (çift kayıt olmaz).
--    Eski borç bakiyesi CARİYE İŞLENMEZ; yalnızca bilgi olarak tutulur (legacy_debt). Cariye açılış ayrı karar.
-- 2) Durum raporu: son alım + alışılmış alım aralığına göre "Sırası geldi / Gecikti / Geri kazan / Uyuyan / Hiç almamış".
-- 3) Arama kaydı: kim kimi aradı, sonuç ne; sonuca göre müşteri arama listesinden bir süre düşer.

-- ---------------------------------------------------------------------------
-- 1) Müşteri kartına eski sistem ve saha alanları
-- ---------------------------------------------------------------------------
alter table public.customers add column if not exists legacy_no            integer;
alter table public.customers add column if not exists segment              text check (segment in ('ev', 'isyeri'));
alter table public.customers add column if not exists district             text;
alter table public.customers add column if not exists address_note         text;
alter table public.customers add column if not exists area                 text;     -- saha / bölge (eski "Saha Elemanı")
alter table public.customers add column if not exists brand_pref           text;     -- kullandığı marka
alter table public.customers add column if not exists preferred_product    text;
alter table public.customers add column if not exists extra_phones         text[] not null default '{}';
alter table public.customers add column if not exists legacy_registered_at date;
alter table public.customers add column if not exists legacy_last_sale_at  timestamptz;
alter table public.customers add column if not exists legacy_order_count   integer not null default 0 check (legacy_order_count >= 0);
alter table public.customers add column if not exists legacy_total_sales   numeric(14,2) not null default 0;
alter table public.customers add column if not exists legacy_period_days   integer check (legacy_period_days >= 0);
alter table public.customers add column if not exists legacy_debt          numeric(14,2);
alter table public.customers add column if not exists imported_at          timestamptz;
create unique index if not exists customers_legacy_no on public.customers(business_id, legacy_no) where legacy_no is not null;
create index if not exists customers_area on public.customers(business_id, area);
create index if not exists sales_customer_done on public.sales(customer_id, sold_at desc) where status = 'tamamlandi';
create index if not exists orders_customer_open on public.orders(customer_id) where status in ('acik', 'onay_bekliyor');

-- Telefon: rakamlar → 0XXXXXXXXXX (10 hane, 2-5 ile başlar). Sahte/boş numaralar (0000…, 1010…, tek rakam tekrarı) null.
create or replace function app.norm_phone(p text) returns text
language plpgsql immutable as $$
declare d text := regexp_replace(coalesce(p, ''), '\D', '', 'g');
begin
  if length(d) = 12 and left(d, 2) = '90' then d := substr(d, 3); end if;
  if length(d) = 11 and left(d, 1) = '0' then d := substr(d, 2); end if;
  if d !~ '^[2-5][0-9]{9}$' then return null; end if;
  if d ~ '^(.)\1+$' or d ~ '^(..)\1{4}$' or d ~ '^(.)\1{6}' or right(d, 7) ~ '^(.)\1+$' then return null; end if;
  return '0' || d;
end $$;

-- Türkçe duyarlı arama anahtarı (istemcideki searchKey ile aynı): küçük harf, şapkasız, ı/İ → i
create or replace function app.tr_key(p text) returns text
language sql immutable as $$
  select translate(lower(translate(coalesce(p, ''), 'İIŞĞÜÖÇÂÎÛ', 'iışğüöçâîû')), 'ışğüöçâîû', 'isguocaiu')
$$;
alter table public.customers add column if not exists search_key text
  generated always as (app.tr_key(name || ' ' || code)) stored;
create index if not exists customers_search on public.customers(business_id, search_key);

-- Karşılaştırma için son 10 hane
create or replace function app.phone10(p text) returns text
language sql immutable as $$ select nullif(right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 10), '') $$;

-- ---------------------------------------------------------------------------
-- 2) Abone listesi içe aktarma
-- Satır anahtarları: abone, baglan (isteğe bağlı: bağlanacak mevcut kart id), tur, tip, ad, adres, ilce, tarif, marka, saha, son_satis, telefonlar[], kayit,
--                    periyot, siparis_sayisi, toplam_satis, borc, konum, tercih, row
-- ---------------------------------------------------------------------------
create or replace function app.import_subscribers(p_business uuid, p_rows jsonb, p_dry_run boolean, p_actor uuid)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r jsonb; v_row int; v_no int; v_errs jsonb := '[]'; v_matched jsonb := '[]'; v_seen int[] := '{}';
  v_id uuid; v_new int := 0; v_upd int := 0; v_phone_match int := 0; v_no_phone int := 0; v_loc int := 0;
  v_phones text[]; v_phone text; v_lat numeric; v_lng numeric; v_code text; v_last timestamptz; v_cnt int;
  v_how text; v_key text; v_names jsonb := '{}';
begin
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 20000 then
    raise exception 'Geçersiz liste' using errcode = '22023';
  end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    v_row := coalesce(app.int(r->>'row'), 0);
    v_no := app.int(r->>'abone');
    if v_no is null or v_no <= 0 then
      v_errs := v_errs || jsonb_build_object('row', v_row, 'field', 'Abone', 'message', 'Abone numarası yok');
      continue;
    end if;
    if app.blank(r->>'ad') then
      v_errs := v_errs || jsonb_build_object('row', v_row, 'field', 'Abone/Firma Adı', 'message', 'Ad boş');
    end if;
    if v_no = any(v_seen) then
      v_errs := v_errs || jsonb_build_object('row', v_row, 'field', 'Abone', 'message', 'Abone numarası dosyada tekrar ediyor: ' || v_no);
    end if;
    v_seen := v_seen || v_no;
    v_key := app.tr_key(regexp_replace(trim(coalesce(r->>'ad', '')), '\s+', ' ', 'g'));
    v_names := v_names || jsonb_build_object(v_key, coalesce((v_names->>v_key)::int, 0) + 1);
  end loop;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_no := app.int(r->>'abone');
    continue when v_no is null or v_no <= 0 or app.blank(r->>'ad');
    v_row := coalesce(app.int(r->>'row'), 0);
    select coalesce(array_agg(x order by o), '{}') into v_phones
      from (select distinct on (app.norm_phone(t)) app.norm_phone(t) x, o
              from jsonb_array_elements_text(coalesce(r->'telefonlar', '[]')) with ordinality as e(t, o)
             where app.norm_phone(t) is not null order by app.norm_phone(t), o) s;
    v_phone := v_phones[1];
    if v_phone is null then v_no_phone := v_no_phone + 1; end if;
    v_lat := null; v_lng := null;
    if coalesce(r->>'konum', '') ~ '^\s*-?\d+(\.\d+)?\s*,\s*-?\d+(\.\d+)?\s*$' then
      v_lat := round(split_part(r->>'konum', ',', 1)::numeric, 6);
      v_lng := round(split_part(r->>'konum', ',', 2)::numeric, 6);
      if v_lat not between 35 and 43 or v_lng not between 25 and 46 then v_lat := null; v_lng := null; end if;
    end if;
    if v_lat is not null then v_loc := v_loc + 1; end if;
    v_last := case when coalesce(r->>'son_satis', '') ~ '^\d{4}-\d{2}-\d{2}' then (r->>'son_satis')::timestamptz end;

    select id into v_id from public.customers where business_id = p_business and legacy_no = v_no;
    v_how := null;
    -- Daha önce elle açılmış (abone numarası olmayan) kart: 1) elle verilen bağlantı, 2) telefon, 3) ad, 4) ad başı.
    -- Her biri yalnızca TEK aday varsa bağlanır; aksi halde yeni kart açılır.
    if v_id is null and app.blank(r->>'baglan') is false then
      select id into v_id from public.customers
       where business_id = p_business and legacy_no is null and id::text = r->>'baglan';
      if v_id is not null then v_how := 'elle'; end if;
    end if;
    if v_id is null and v_phone is not null then
      select count(*), min(id::text)::uuid into v_cnt, v_id from public.customers
       where business_id = p_business and legacy_no is null and app.phone10(phone) = app.phone10(v_phone);
      if v_cnt = 1 then v_how := 'telefon'; else v_id := null; end if;
    end if;
    v_key := app.tr_key(regexp_replace(trim(r->>'ad'), '\s+', ' ', 'g'));
    if v_id is null and coalesce((v_names->>v_key)::int, 0) = 1 then
      select count(*), min(id::text)::uuid into v_cnt, v_id from public.customers
       where business_id = p_business and legacy_no is null and channel <> 'bayi'
         and app.tr_key(regexp_replace(trim(name), '\s+', ' ', 'g')) = v_key;
      if v_cnt = 1 then v_how := 'ad'; else v_id := null; end if;
      if v_id is null and v_cnt = 0 then
        select count(*), min(id::text)::uuid into v_cnt, v_id from public.customers
         where business_id = p_business and legacy_no is null and channel <> 'bayi'
           and length(trim(name)) >= 4 and v_key like app.tr_key(regexp_replace(trim(name), '\s+', ' ', 'g')) || ' %';
        if v_cnt = 1 then v_how := 'ad'; else v_id := null; end if;
      end if;
    end if;
    if v_how is not null then
      v_phone_match := v_phone_match + 1;
      v_matched := v_matched || jsonb_build_object('row', v_row, 'abone', v_no, 'ad', trim(r->>'ad'), 'nasil', v_how,
                     'eslesen', (select name from public.customers where id = v_id));
    end if;

    if v_id is null then v_new := v_new + 1; else v_upd := v_upd + 1; end if;
    continue when p_dry_run or jsonb_array_length(v_errs) > 0;

    if v_id is null then
      v_code := 'A' || v_no;
      if exists (select 1 from public.customers where business_id = p_business and lower(code) = lower(v_code)) then
        v_code := 'M' || lpad(app.next_number(p_business, 'musteri')::text, 5, '0');
      end if;
      insert into public.customers(business_id, code, name, phone, address, channel, legacy_no, source, approved)
      values (p_business, v_code, trim(r->>'ad'), v_phone, nullif(trim(r->>'adres'), ''),
              case when r->>'tip' ilike 'kurumsal' then 'kurumsal' else 'perakende' end, v_no, 'ofis', true)
      returning id into v_id;
    end if;
    update public.customers c set
      legacy_no            = v_no,
      name                 = case when app.blank(c.name) then trim(r->>'ad') else c.name end,
      phone                = coalesce(nullif(trim(c.phone), ''), v_phone),
      extra_phones         = (select coalesce(array_agg(p), '{}') from unnest(v_phones) p
                               where app.phone10(p) is distinct from app.phone10(coalesce(nullif(trim(c.phone), ''), v_phone))),
      address              = coalesce(nullif(trim(c.address), ''), nullif(trim(r->>'adres'), '')),
      segment              = case when r->>'tur' ilike '%yer%' then 'isyeri' else 'ev' end,
      district             = coalesce(nullif(initcap(trim(r->>'ilce')), ''), c.district),
      address_note         = coalesce(nullif(trim(r->>'tarif'), ''), c.address_note),
      area                 = coalesce(nullif(initcap(trim(r->>'saha')), ''), c.area),
      brand_pref           = coalesce(nullif(initcap(trim(r->>'marka')), ''), c.brand_pref),
      preferred_product    = coalesce(nullif(nullif(trim(r->>'tercih'), ''), '-'), c.preferred_product),
      latitude             = coalesce(c.latitude, v_lat),
      longitude            = coalesce(c.longitude, v_lng),
      legacy_registered_at = coalesce(case when coalesce(r->>'kayit', '') ~ '^\d{4}-\d{2}-\d{2}' then left(r->>'kayit', 10)::date end, c.legacy_registered_at),
      legacy_last_sale_at  = greatest(c.legacy_last_sale_at, v_last),
      legacy_order_count   = greatest(coalesce(app.int(r->>'siparis_sayisi'), 0), 0),
      legacy_total_sales   = coalesce(app.num(r->>'toplam_satis'), 0),
      legacy_period_days   = nullif(greatest(coalesce(app.int(r->>'periyot'), 0), 0), 0),
      legacy_debt          = nullif(app.num(r->>'borc'), 0),
      imported_at          = now()
    where c.id = v_id;
  end loop;

  if not p_dry_run and jsonb_array_length(v_errs) = 0 then
    perform app.audit(p_business, 'abone_ice_aktarma', 'customers', null, null,
      jsonb_build_object('rows', jsonb_array_length(p_rows), 'new', v_new, 'updated', v_upd, 'phone_match', v_phone_match, 'actor', p_actor));
  end if;
  return jsonb_build_object('ok', jsonb_array_length(v_errs) = 0, 'applied', not p_dry_run and jsonb_array_length(v_errs) = 0,
    'errors', v_errs, 'matched', v_matched,
    'summary', jsonb_build_object('rows', jsonb_array_length(p_rows), 'new', v_new, 'updated', v_upd,
                                  'phone_match', v_phone_match, 'no_phone', v_no_phone, 'with_location', v_loc));
end $$;

-- Yönetici ekrandan yükler (.xlsx)
create or replace function public.import_subscribers(p_business uuid, p_rows jsonb, p_dry_run boolean default true)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app.require_role(p_business, 'yonetici');
  return app.import_subscribers(p_business, p_rows, p_dry_run, auth.uid());
end $$;

-- ---------------------------------------------------------------------------
-- 3) Arama kaydı
-- ---------------------------------------------------------------------------
create table if not exists public.customer_calls (
  id            bigint generated always as identity primary key,
  business_id   uuid not null references public.businesses(id),
  customer_id   uuid not null references public.customers(id),
  user_id       uuid not null,
  called_at     timestamptz not null default now(),
  outcome       text not null check (outcome in ('siparis', 'sonra', 'ulasilamadi', 'istemiyor', 'yanlis_numara')),
  note          text check (length(note) <= 500),
  next_call_on  date
);
create index if not exists customer_calls_customer on public.customer_calls(customer_id, called_at desc);
create index if not exists customer_calls_business on public.customer_calls(business_id, called_at desc);
alter table public.customer_calls enable row level security;
drop policy if exists customer_calls_select on public.customer_calls;
create policy customer_calls_select on public.customer_calls for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis'));
drop trigger if exists customer_calls_immutable on public.customer_calls;
create trigger customer_calls_immutable before update or delete on public.customer_calls for each row execute function app.tg_immutable();

-- Rapor kapsamı: personel → bizim müşterilerimiz (bayiye ait olmayan, bayi olmayan); bayi → kendi müşterileri
create or replace function app.status_owner(p_business uuid) returns uuid
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_role public.member_role := app.require_role(p_business, 'yonetici', 'satis', 'sevkiyat', 'bayi');
begin
  if v_role = 'bayi' then
    return coalesce(app.my_customer(p_business), '00000000-0000-0000-0000-000000000000'::uuid);
  end if;
  return null;
end $$;

-- Müşteri durumu (tek çekirdek; özet ve liste bunu kullanır)
create or replace function app.customer_status(p_business uuid, p_owner uuid)
returns table(id uuid, code text, name text, phone text, extra_phones text[], district text, area text, address text,
              channel text, segment text, brand_pref text, preferred_product text, last_at timestamptz, days integer,
              period integer, orders integer, total numeric, open_order boolean, next_call_on date,
              last_call_at timestamptz, last_outcome text, last_caller text, legacy_debt numeric, bucket text, priority numeric)
language sql stable security definer set search_path = public, pg_temp as $$
  with c as (
    select c.* from public.customers c
     where c.business_id = p_business and c.active and c.approved
       and case when p_owner is null then c.owner_dealer_id is null and c.channel <> 'bayi' else c.owner_dealer_id = p_owner end
  ), s as (
    select s.customer_id, max(s.sold_at) last_at, min(s.sold_at) first_at, count(*)::int n, sum(s.goods_net) total
      from public.sales s join c on c.id = s.customer_id
     where s.status = 'tamamlandi' group by s.customer_id
  ), lc as (
    select distinct on (k.customer_id) k.customer_id, k.called_at, k.outcome, k.next_call_on, m.display_name
      from public.customer_calls k join c on c.id = k.customer_id
      left join public.memberships m on m.business_id = k.business_id and m.user_id = k.user_id
     order by k.customer_id, k.called_at desc
  ), x as (
    select c.*, greatest(c.legacy_last_sale_at, s.last_at) as l_at,
           (c.legacy_order_count + coalesce(s.n, 0))::int as n_orders,
           (c.legacy_total_sales + coalesce(s.total, 0)) as t_total,
           least(greatest(coalesce(c.legacy_period_days,
                    case when s.n >= 3 then round(extract(epoch from s.last_at - s.first_at) / 86400 / (s.n - 1))::int end, 30), 7), 90) as p,
           exists (select 1 from public.orders o where o.customer_id = c.id and o.status in ('acik', 'onay_bekliyor')) as has_open,
           lc.called_at as lc_at, lc.outcome as lc_out, lc.next_call_on as lc_next, lc.display_name as lc_by
      from c left join s on s.customer_id = c.id left join lc on lc.customer_id = c.id
  ), y as (
    select x.*, (app.local_date(now()) - app.local_date(x.l_at))::int as d from x
  )
  select y.id, y.code, y.name, y.phone, y.extra_phones, y.district, y.area, y.address, y.channel, y.segment, y.brand_pref,
         y.preferred_product, y.l_at, y.d, y.p, y.n_orders, y.t_total, y.has_open, y.lc_next, y.lc_at, y.lc_out, y.lc_by, y.legacy_debt,
         case when y.has_open then 'siparis_var'
              when y.l_at is null then 'hic'
              when y.d < y.p then 'duzenli'
              when y.d <= greatest(2 * y.p, 30) and y.d <= 90 then 'sirasi_geldi'
              when y.d <= 90 then 'gecikti'
              when y.d <= 365 then 'geri_kazan'
              else 'uyuyan' end,
         round((ln(2 + y.n_orders) * least(coalesce(y.d, 0)::numeric / y.p, 3))::numeric, 3)
    from y
$$;

-- Özet: kartlar + bugünkü/haftalık arama tablosu
create or replace function public.customer_status_summary(p_business uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_owner uuid := app.status_owner(p_business); v jsonb; v_today date := app.local_date(now());
begin
  select jsonb_build_object(
    'total', count(*),
    'active30', count(*) filter (where days <= 30),
    'new30', count(*) filter (where days is not null and days <= 30 and orders <= 1),
    'call_now', count(*) filter (where bucket in ('sirasi_geldi', 'gecikti') and coalesce(next_call_on, v_today) <= v_today),
    'snoozed', count(*) filter (where bucket in ('sirasi_geldi', 'gecikti') and next_call_on > v_today),
    'buckets', jsonb_build_object(
      'duzenli', count(*) filter (where bucket = 'duzenli'),
      'siparis_var', count(*) filter (where bucket = 'siparis_var'),
      'sirasi_geldi', count(*) filter (where bucket = 'sirasi_geldi'),
      'gecikti', count(*) filter (where bucket = 'gecikti'),
      'geri_kazan', count(*) filter (where bucket = 'geri_kazan'),
      'uyuyan', count(*) filter (where bucket = 'uyuyan'),
      'hic', count(*) filter (where bucket = 'hic')),
    'areas', (select coalesce(jsonb_agg(a order by a), '[]') from (select distinct area a from app.customer_status(p_business, v_owner) where area is not null) z))
    into v from app.customer_status(p_business, v_owner);
  -- Arama tablosu: bugün ve son 7 gün, kişi başı arama ve siparişle sonuçlanan
  v := v || jsonb_build_object('callers', (
    select coalesce(jsonb_agg(jsonb_build_object('name', coalesce(m.display_name, 'Kullanıcı'), 'today', t.today, 'today_orders', t.today_orders,
                                                 'week', t.week, 'week_orders', t.week_orders) order by t.today desc, t.week desc), '[]')
      from (select k.user_id,
                   count(*) filter (where app.local_date(k.called_at) = v_today) today,
                   count(*) filter (where app.local_date(k.called_at) = v_today and k.outcome = 'siparis') today_orders,
                   count(*) week, count(*) filter (where k.outcome = 'siparis') week_orders
              from public.customer_calls k
             where k.business_id = p_business and k.called_at > now() - interval '7 days'
               and (v_owner is null or k.customer_id in (select cc.id from public.customers cc where cc.owner_dealer_id = v_owner))
               and (v_owner is not null or k.customer_id in (select cc.id from public.customers cc where cc.business_id = p_business and cc.owner_dealer_id is null))
             group by k.user_id) t
      left join public.memberships m on m.business_id = p_business and m.user_id = t.user_id));
  return v;
end $$;

-- Liste: bölüm (ara = sırası gelen + geciken, ertelenmemiş), arama, bölge; sayfalı
create or replace function public.customer_status_list(p_business uuid, p_bucket text, p_q text default null, p_area text default null,
                                                       p_limit integer default 50, p_offset integer default 0)
returns table(id uuid, code text, name text, phone text, extra_phones text[], district text, area text, address text,
              channel text, segment text, brand_pref text, preferred_product text, last_at timestamptz, days integer,
              period integer, orders integer, total numeric, open_order boolean, next_call_on date,
              last_call_at timestamptz, last_outcome text, last_caller text, legacy_debt numeric, bucket text, priority numeric)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare
  v_owner uuid := app.status_owner(p_business);
  v_admin boolean := app.has_role(p_business, 'yonetici');
  v_today date := app.local_date(now());
  v_q text := nullif(app.tr_key(trim(coalesce(p_q, ''))), '');
  v_d text := nullif(regexp_replace(regexp_replace(coalesce(p_q, ''), '\D', '', 'g'), '^(90|0)', ''), '');
begin
  return query
  select s.id, s.code, s.name, s.phone, s.extra_phones, s.district, s.area, s.address, s.channel, s.segment, s.brand_pref,
         s.preferred_product, s.last_at, s.days, s.period, s.orders, case when v_admin then s.total end, s.open_order, s.next_call_on,
         s.last_call_at, s.last_outcome, s.last_caller, case when v_admin then s.legacy_debt end, s.bucket, s.priority
    from app.customer_status(p_business, v_owner) s
   where case p_bucket
           when 'ara' then s.bucket in ('sirasi_geldi', 'gecikti') and coalesce(s.next_call_on, v_today) <= v_today
           when 'ertelenen' then s.bucket in ('sirasi_geldi', 'gecikti') and s.next_call_on > v_today
           when 'tumu' then true
           else s.bucket = p_bucket end
     and (v_q is null or app.tr_key(s.name || ' ' || s.code) like '%' || v_q || '%'
          or (length(v_d) >= 4 and (app.phone10(s.phone) like '%' || v_d || '%' or exists (select 1 from unnest(s.extra_phones) e where app.phone10(e) like '%' || v_d || '%'))))
     and (p_area is null or s.area = p_area)
   order by case when p_bucket in ('ara', 'ertelenen', 'sirasi_geldi', 'gecikti') then s.priority end desc nulls last,
            case when p_bucket in ('geri_kazan', 'uyuyan') then s.orders end desc nulls last,
            s.days nulls last, s.name
   limit least(greatest(coalesce(p_limit, 50), 1), 200) offset greatest(coalesce(p_offset, 0), 0);
end $$;

-- Arama sonucu kaydı
create or replace function public.log_customer_call(p_business uuid, p_customer uuid, p_outcome text, p_note text default null, p_next date default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_owner uuid := app.status_owner(p_business); v_next date; v_today date := app.local_date(now());
begin
  if not exists (select 1 from public.customers c where c.id = p_customer and c.business_id = p_business
                   and case when v_owner is null then c.owner_dealer_id is null else c.owner_dealer_id = v_owner end) then
    raise exception 'Müşteri bulunamadı' using errcode = 'P0002';
  end if;
  if p_outcome not in ('siparis', 'sonra', 'ulasilamadi', 'istemiyor', 'yanlis_numara') then
    raise exception 'Geçersiz arama sonucu' using errcode = '22023';
  end if;
  if p_next is not null and (p_next < v_today or p_next > v_today + 365) then
    raise exception 'Tekrar arama tarihi bugünden sonra ve bir yıl içinde olmalı' using errcode = '22023';
  end if;
  v_next := coalesce(p_next, case p_outcome
              when 'siparis' then v_today + 7
              when 'sonra' then v_today + 3
              when 'ulasilamadi' then v_today + 1
              when 'istemiyor' then v_today + 60
              when 'yanlis_numara' then v_today + 365 end);
  insert into public.customer_calls(business_id, customer_id, user_id, outcome, note, next_call_on)
  values (p_business, p_customer, auth.uid(), p_outcome, nullif(trim(coalesce(p_note, '')), ''), v_next);
  return jsonb_build_object('next_call_on', v_next);
end $$;

select app.apply_grants();
select 'SONUC: musteri_durum hazir, ' || (select count(*) from public.customers) || ' musteri' as sonuc;
commit;
