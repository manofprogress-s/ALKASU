-- 20.10.2026: İşbaşı cari eşleştirme (0032). Dışarıya veri göndermez.
begin;
-- ALKASU 0032 — Logo İşbaşı cari listesini ALKASU müşteri kartlarıyla eşleştirme
-- Kural: BUSINESS_RULES §28 (F-28) · Karar: D-091
-- Amaç: fatura gönderilirken İşbaşı'da aynı müşterinin ikinci kez açılmaması (cari kodu gönderilir) ve
-- boş fatura bilgilerinin (VKN, vergi dairesi, unvan, adres, e-posta) İşbaşı'ndan doldurulması.
-- Dışarıya hiçbir veri gönderilmez; liste yöneticinin yapıştırdığı/yüklediği dosyadan gelir.
-- Kural: dolu alanların üzerine YAZILMAZ; yalnızca boş alanlar doldurulur. Bakiye alınmaz.

alter table public.customers add column if not exists logo_code text
  check (logo_code is null or (length(logo_code) between 1 and 40));
create unique index if not exists customers_logo_code on public.customers(business_id, logo_code) where logo_code is not null;

-- Unvan/ad karşılaştırma anahtarı: Türkçe harfsiz, noktalama yok, tek boşluk
create or replace function app.firm_key(p text) returns text
language sql immutable as $$
  select nullif(trim(regexp_replace(app.tr_key(p), '[^a-z0-9]+', ' ', 'g')), '')
$$;

-- İlk anlamlı kelime (genel kelimeler atlanır): "AKHAUS PVC PENCERE ..." → "akhaus"
create or replace function app.firm_word(p text) returns text
language sql immutable as $$
  select w from unnest(string_to_array(app.firm_key(p), ' ')) with ordinality as t(w, n)
   where length(w) >= 3 and w not in ('ozel', 'turkiye', 'devlet', 'kocaeli', 'istanbul', 'ankara', 'yeni', 'the', 've', 'san', 'tic')
   order by n limit 1
$$;

-- Bir satır için aday kartlar ve durum. Satır: {row, code, tip, unvan, sehir, ilce, adres, telefon, vkn, vd, eposta}
create or replace function app.logo_firm_match(p_business uuid, r jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_code  text := nullif(trim(coalesce(r->>'code', '')), '');
  v_vkn   text := nullif(regexp_replace(coalesce(r->>'vkn', ''), '\D', '', 'g'), '');
  v_tel   text := app.phone10(app.norm_phone(r->>'telefon'));
  v_key   text := app.firm_key(r->>'unvan');
  v_word  text := app.firm_word(r->>'unvan');
  v_person boolean := (r->>'tip') = 'bireysel' or length(coalesce(v_vkn, '')) = 11;
  v_ids uuid[]; v_status text; v_reason text;
begin
  -- 1) Kod zaten bağlı
  select array_agg(id) into v_ids from public.customers where business_id = p_business and logo_code = v_code;
  if v_ids is not null then
    v_status := 'bagli'; v_reason := 'İşbaşı kodu';
  else
    -- 2) Vergi numarası
    if app.tax_id_kind(v_vkn) is not null then
      select array_agg(id order by name) into v_ids from public.customers
       where business_id = p_business and owner_dealer_id is null and logo_code is null and tax_no = v_vkn;
    end if;
    if v_ids is not null then
      v_status := case when cardinality(v_ids) = 1 then 'kesin' else 'coklu' end; v_reason := 'Vergi no';
    else
      -- 3) Telefon veya isim (onay gerekir)
      select array_agg(id order by name) into v_ids from (
        select c.id, c.name from public.customers c
         where c.business_id = p_business and c.owner_dealer_id is null and c.logo_code is null and c.active
           and (
             (v_tel is not null and (app.phone10(c.phone) = v_tel
                                     or exists (select 1 from unnest(c.extra_phones) x where app.phone10(x) = v_tel)))
             or (v_key is not null and (app.firm_key(c.name) = v_key or app.firm_key(c.legal_title) = v_key))
             or (not v_person and v_word is not null and length(v_word) >= 4 and (
                   app.firm_word(c.name) = v_word or app.firm_word(c.legal_title) = v_word
                   or (length(app.firm_word(c.name)) >= 5 and (v_word like app.firm_word(c.name) || '%' or app.firm_word(c.name) like v_word || '%'))))
           )
         order by c.name limit 6) z;
      if v_ids is null then v_status := 'yok'; v_reason := null;
      else
        v_status := case when cardinality(v_ids) = 1 then 'olasi' else 'coklu' end;
        v_reason := 'Telefon / isim benzerliği';
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'row', r->'row', 'code', v_code, 'unvan', r->>'unvan', 'vkn', v_vkn, 'vkn_ok', app.tax_id_kind(v_vkn) is not null,
    'status', v_status, 'reason', v_reason,
    'candidates', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'code', c.code, 'name', c.name, 'legal_title', c.legal_title, 'tax_no', c.tax_no,
                                          'tax_office', c.tax_office, 'phone', c.phone, 'city', c.city, 'district', c.district,
                                          'address', c.address, 'email', c.email, 'channel', c.channel, 'logo_code', c.logo_code)
                       order by c.name)
        from public.customers c where c.id = any(v_ids)), '[]'::jsonb));
end $$;

-- Yönetici: önizleme (hiçbir şey yazmaz)
create or replace function public.logo_firms_preview(p_business uuid, p_rows jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_res jsonb;
begin
  perform app.require_role(p_business, 'yonetici');
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'Liste boş' using errcode = '22023'; end if;
  if jsonb_array_length(p_rows) > 5000 then raise exception 'Tek seferde en fazla 5000 satır' using errcode = '22023'; end if;
  select jsonb_agg(app.logo_firm_match(p_business, r) order by ord) into v_res
    from jsonb_array_elements(p_rows) with ordinality as t(r, ord);
  return jsonb_build_object(
    'results', v_res,
    -- Listede aynı vergi numarası birden fazla kodla geçiyorsa (İşbaşı'da çift cari)
    'duplicates', coalesce((select jsonb_agg(jsonb_build_object('vkn', vkn, 'codes', codes)) from (
        select regexp_replace(r->>'vkn', '\D', '', 'g') as vkn, jsonb_agg(r->>'code' order by r->>'code') as codes
          from jsonb_array_elements(p_rows) r
         where coalesce(r->>'vkn', '') <> ''
         group by 1 having count(*) > 1) d), '[]'::jsonb));
end $$;

-- Yönetici: onaylanan eşleşmeleri bağlar. p_links: [{customer, firm:{code, unvan, vkn, vd, sehir, ilce, adres, eposta}}]
-- Boş alanları doldurur, dolu alana dokunmaz; farklı VKN varsa uyarı döner.
create or replace function public.logo_firms_apply(p_business uuid, p_links jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  l jsonb; f jsonb; c public.customers; v_code text; v_vkn text; v_mail text; v_filled text[];
  v_linked int := 0; v_fill_n int := 0; v_errors jsonb := '[]'; v_warn jsonb := '[]';
begin
  perform app.require_role(p_business, 'yonetici');
  if jsonb_typeof(p_links) <> 'array' then raise exception 'Geçersiz istek' using errcode = '22023'; end if;
  if jsonb_array_length(p_links) > 5000 then raise exception 'Tek seferde en fazla 5000 satır' using errcode = '22023'; end if;
  for l in select * from jsonb_array_elements(p_links) loop
    f := l->'firm';
    v_code := nullif(trim(coalesce(f->>'code', '')), '');
    select * into c from public.customers where id = (l->>'customer')::uuid and business_id = p_business for update;
    if c.id is null or v_code is null then
      v_errors := v_errors || jsonb_build_object('code', v_code, 'message', 'Kart veya İşbaşı kodu bulunamadı'); continue;
    end if;
    if c.owner_dealer_id is not null then
      v_errors := v_errors || jsonb_build_object('code', v_code, 'name', c.name, 'message', 'Bayiye ait kart bağlanamaz'); continue;
    end if;
    if c.logo_code is not null and c.logo_code <> v_code then
      v_errors := v_errors || jsonb_build_object('code', v_code, 'name', c.name, 'message', 'Kart başka bir İşbaşı koduna bağlı (' || c.logo_code || ')'); continue;
    end if;
    if exists (select 1 from public.customers where business_id = p_business and logo_code = v_code and id <> c.id) then
      v_errors := v_errors || jsonb_build_object('code', v_code, 'name', c.name, 'message', 'Bu İşbaşı kodu başka bir karta bağlı'); continue;
    end if;

    v_vkn := nullif(regexp_replace(coalesce(f->>'vkn', ''), '\D', '', 'g'), '');
    if app.tax_id_kind(v_vkn) is null then v_vkn := null; end if;
    v_mail := nullif(lower(trim(coalesce(f->>'eposta', ''))), '');
    if v_mail is not null and v_mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v_mail := null; end if;
    if c.tax_no is not null and v_vkn is not null and c.tax_no <> v_vkn then
      v_warn := v_warn || jsonb_build_object('code', v_code, 'name', c.name,
                  'message', 'Kartta farklı vergi no var (' || c.tax_no || '), değiştirilmedi');
    end if;

    v_filled := array_remove(array[
      case when c.tax_no is null and v_vkn is not null then 'vergi no' end,
      case when c.tax_office is null and nullif(trim(coalesce(f->>'vd', '')), '') is not null then 'vergi dairesi' end,
      case when c.legal_title is null and nullif(trim(coalesce(f->>'unvan', '')), '') is not null then 'unvan' end,
      case when c.city is null and nullif(trim(coalesce(f->>'sehir', '')), '') is not null then 'il' end,
      case when c.district is null and nullif(trim(coalesce(f->>'ilce', '')), '') is not null then 'ilçe' end,
      case when c.address is null and nullif(trim(coalesce(f->>'adres', '')), '') is not null then 'adres' end,
      case when c.email is null and v_mail is not null then 'e-posta' end], null);

    update public.customers set
      logo_code   = v_code,
      tax_no      = coalesce(tax_no, v_vkn),
      tax_office  = coalesce(tax_office, nullif(left(trim(coalesce(f->>'vd', '')), 100), '')),
      legal_title = coalesce(legal_title, nullif(left(trim(coalesce(f->>'unvan', '')), 250), '')),
      city        = coalesce(city, nullif(left(trim(coalesce(f->>'sehir', '')), 60), '')),
      district    = coalesce(district, nullif(trim(coalesce(f->>'ilce', '')), '')),
      address     = coalesce(address, nullif(trim(coalesce(f->>'adres', '')), '')),
      email       = coalesce(email, v_mail)
    where id = c.id;
    perform app.audit(p_business, 'logo_cari_bagla', 'customers', c.id::text,
                      jsonb_build_object('logo_code', c.logo_code, 'tax_no', c.tax_no),
                      jsonb_build_object('logo_code', v_code, 'doldurulan', to_jsonb(v_filled)));
    v_linked := v_linked + 1;
    if cardinality(v_filled) > 0 then v_fill_n := v_fill_n + 1; end if;
  end loop;
  return jsonb_build_object('linked', v_linked, 'filled', v_fill_n, 'errors', v_errors, 'warnings', v_warn);
end $$;

-- Yönetici: bağlantıyı kaldırır (doldurulan bilgiler kartta kalır)
create or replace function public.logo_firm_unlink(p_business uuid, p_customer uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_old text;
begin
  perform app.require_role(p_business, 'yonetici');
  select logo_code into v_old from public.customers where id = p_customer and business_id = p_business;
  if not found then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
  update public.customers set logo_code = null where id = p_customer;
  perform app.audit(p_business, 'logo_cari_ayir', 'customers', p_customer::text, jsonb_build_object('logo_code', v_old), null);
end $$;

select app.apply_grants();
select 'SONUC: logo cari hazir, fonksiyon=' || count(*) from pg_proc where proname in ('logo_firms_preview','logo_firms_apply','logo_firm_unlink','logo_firm_match');
commit;
