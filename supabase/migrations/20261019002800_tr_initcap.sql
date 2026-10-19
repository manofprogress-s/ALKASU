-- ALKASU 0028 — Türkçe büyük harf düzeltmesi: "İBRAHİM" → "İbrahim" (initcap "İbrahi̇m" yapıyordu), marka adları "Gürpınar"
-- Kural: BUSINESS_RULES §27 (M-21) · Karar: D-087

-- Her kelimenin ilk harfi büyük, gerisi küçük (Türkçe i/ı, İ/I doğru)
create or replace function app.tr_initcap(p text) returns text
language sql immutable as $$
  select nullif(string_agg(upper(translate(left(x, 1), 'iışğüöç', 'İIŞĞÜÖÇ')) || substr(x, 2), ' ' order by n), '')
    from regexp_split_to_table(lower(translate(trim(coalesce(p, '')), 'İIŞĞÜÖÇ', 'iışğüöç')), '\s+') with ordinality as t(x, n)
   where x <> ''
$$;

-- Eski sistemin marka kodları → görünen ad
create or replace function app.brand_label(p text) returns text
language sql immutable as $$
  select case upper(trim(coalesce(p, '')))
           when '' then null
           when 'GURPINAR' then 'Gürpınar' when 'KIZILAY' then 'Kızılay' when 'PINAR' then 'Pınar'
           when 'FUSKA' then 'Fuska' when 'ABANT' then 'Abant' when 'BEYPAZARI' then 'Beypazarı'
           when 'PET' then 'Pet' when 'DIGER' then 'Diğer'
           else app.tr_initcap(p) end
$$;

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
      district             = coalesce(nullif(app.tr_initcap(r->>'ilce'), ''), c.district),
      address_note         = coalesce(nullif(trim(r->>'tarif'), ''), c.address_note),
      area                 = coalesce(nullif(app.tr_initcap(r->>'saha'), ''), c.area),
      brand_pref           = coalesce(nullif(app.brand_label(r->>'marka'), ''), c.brand_pref),
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


-- Yüklenmiş kayıtları düzelt
update public.customers set
  area = app.tr_initcap(area),
  district = app.tr_initcap(district),
  brand_pref = app.brand_label(brand_pref)
 where legacy_no is not null;

select app.apply_grants();
