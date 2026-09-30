-- ALKASU 0006 — Excel içe aktarma (ürün, müşteri) ve stok sayımı
-- Kurallar: E-01..E-04, T-04, D-09, D-025

-- ---------------------------------------------------------------------------
-- Yardımcılar
-- ---------------------------------------------------------------------------
create or replace function app.num(p text) returns numeric
language sql immutable as $$
  select case when trim(coalesce(p, '')) ~ '^-?[0-9]+(\.[0-9]+)?$' then trim(p)::numeric end
$$;
create or replace function app.int(p text) returns integer
language sql immutable as $$
  select case when trim(coalesce(p, '')) ~ '^-?[0-9]{1,9}$' then trim(p)::integer end
$$;
create or replace function app.blank(p text) returns boolean
language sql immutable as $$ select trim(coalesce(p, '')) = '' $$;
create or replace function app.yes(p text, p_default boolean) returns boolean
language sql immutable as $$
  select case upper(trim(coalesce(p, ''))) when 'E' then true when 'EVET' then true when 'H' then false
                                           when 'HAYIR' then false when '' then p_default end
$$;

-- ---------------------------------------------------------------------------
-- Ürün içe aktarma (şablon: templates/urun_ice_aktarma_sablonu.xlsx, sayfa "Ürünler")
-- p_rows: [{ row: excel satır no, urun_kodu, urun_adi, ... }]  (değerler metin; ondalık ayırıcı nokta)
-- p_dry_run = true: yalnızca doğrular, önizleme döner. false: hata yoksa tek işlemde kaydeder.
-- ---------------------------------------------------------------------------
create or replace function public.import_products(p_business uuid, p_rows jsonb, p_dry_run boolean default true)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r        jsonb;
  v_row    int;
  v_errs   jsonb := '[]';
  v_warn   jsonb := '[]';
  v_codes  text[] := '{}';
  v_bcs    text[] := '{}';
  v_code   text;
  v_bc     text;
  v_new    int := 0; v_upd int := 0;
  v_brands text[] := '{}'; v_cats text[] := '{}';
  v_pid    uuid; v_brand uuid; v_cat uuid; v_empty uuid;
  v_units  jsonb;
  v_has_mov boolean;
  v_loc    uuid := app.default_location(p_business);
  pass     int;
  f        text;
begin
  perform app.require_role(p_business, 'yonetici');
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'Dosyada ürün satırı bulunamadı' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) > 5000 then
    raise exception 'Tek seferde en fazla 5000 satır aktarılabilir' using errcode = '22023';
  end if;

  -- 1) Doğrulama
  for r in select * from jsonb_array_elements(p_rows) loop
    v_row := coalesce((r->>'row')::int, 0);
    v_code := trim(coalesce(r->>'urun_kodu', ''));
    foreach f in array array['urun_kodu', 'urun_adi', 'marka', 'kategori', 'temel_birim', 'kdv_orani'] loop
      if app.blank(r->>f) then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'field', f, 'message', 'Zorunlu alan boş');
      end if;
    end loop;
    if v_code <> '' then
      if lower(v_code) = any(v_codes) then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'field', 'urun_kodu', 'message', 'Kod dosyada birden fazla kez geçiyor: ' || v_code);
      end if;
      v_codes := v_codes || lower(v_code);
    end if;
    if not app.blank(r->>'kdv_orani') and coalesce(app.int(r->>'kdv_orani'), -1) not in (0, 1, 10, 20) then
      v_errs := v_errs || jsonb_build_object('row', v_row, 'field', 'kdv_orani', 'message', 'KDV oranı 0, 1, 10 veya 20 olmalı');
    end if;
    foreach f in array array['satis_fiyati', 'paket_satis_fiyati', 'koli_satis_fiyati', 'alis_fiyati', 'depozito_tutari'] loop
      if not app.blank(r->>f) and coalesce(app.num(r->>f), -1) < 0 then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'field', f, 'message', 'Geçerli bir tutar değil: ' || (r->>f));
      end if;
    end loop;
    foreach f in array array['acilis_stogu', 'kritik_stok'] loop
      if not app.blank(r->>f) and coalesce(app.int(r->>f), -1) < 0 then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'field', f, 'message', 'Sıfır veya pozitif tam sayı olmalı: ' || (r->>f));
      end if;
    end loop;
    foreach f in array array['paket', 'koli'] loop
      if not app.blank(r->>(f || '_icerik')) and coalesce(app.int(r->>(f || '_icerik')), 0) < 2 then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'field', f || '_icerik', 'message', 'İçerik 1''den büyük tam sayı olmalı');
      end if;
      if app.blank(r->>(f || '_icerik')) and not app.blank(r->>(f || '_satis_fiyati')) then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'field', f || '_icerik', 'message', 'Fiyat girilmiş ama içerik boş');
      end if;
    end loop;
    foreach f in array array['depozitolu', 'bos_kap_mi', 'aktif'] loop
      if app.yes(r->>f, false) is null then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'field', f, 'message', 'E veya H olmalı');
      end if;
    end loop;
    if app.yes(r->>'depozitolu', false) then
      if coalesce(app.num(r->>'depozito_tutari'), 0) <= 0 then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'field', 'depozito_tutari', 'message', 'Depozitolu üründe depozito tutarı zorunlu');
      end if;
      if app.blank(r->>'bos_kap_urun_kodu') then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'field', 'bos_kap_urun_kodu', 'message', 'Depozitolu üründe boş kap ürün kodu zorunlu');
      elsif not exists (select 1 from jsonb_array_elements(p_rows) x
                         where lower(trim(x->>'urun_kodu')) = lower(trim(r->>'bos_kap_urun_kodu')) and app.yes(x->>'bos_kap_mi', false))
        and not exists (select 1 from public.products where business_id = p_business and is_container
                         and lower(code) = lower(trim(r->>'bos_kap_urun_kodu'))) then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'field', 'bos_kap_urun_kodu',
                                               'message', 'Boş kap ürünü bulunamadı (bos_kap_mi = E olan bir satır olmalı): ' || (r->>'bos_kap_urun_kodu'));
      end if;
      if app.yes(r->>'bos_kap_mi', false) then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'field', 'bos_kap_mi', 'message', 'Bir ürün hem depozitolu hem boş kap olamaz');
      end if;
    end if;
    if app.yes(r->>'bos_kap_mi', false) and not app.blank(r->>'satis_fiyati') then
      v_warn := v_warn || jsonb_build_object('row', v_row, 'field', 'satis_fiyati', 'message', 'Boş kap ürünü satılmaz; fiyat yok sayılacak');
    end if;
    -- barkodlar
    if not app.blank(r->>'barkod') then
      foreach v_bc in array string_to_array(r->>'barkod', '|') loop
        v_bc := trim(v_bc);
        continue when v_bc = '';
        if v_bc !~ '^[0-9A-Za-z\-\.]{3,64}$' then
          v_errs := v_errs || jsonb_build_object('row', v_row, 'field', 'barkod', 'message', 'Barkod geçersiz: ' || v_bc);
        elsif v_bc = any(v_bcs) then
          v_errs := v_errs || jsonb_build_object('row', v_row, 'field', 'barkod', 'message', 'Barkod dosyada tekrar ediyor: ' || v_bc);
        elsif exists (select 1 from public.product_barcodes b join public.products p on p.id = b.product_id
                       where b.business_id = p_business and b.barcode = v_bc and lower(p.code) <> lower(v_code)) then
          v_errs := v_errs || jsonb_build_object('row', v_row, 'field', 'barkod', 'message', 'Barkod başka bir üründe kayıtlı: ' || v_bc);
        end if;
        v_bcs := v_bcs || v_bc;
      end loop;
    end if;
    -- yeni/güncelleme, marka/kategori
    select id into v_pid from public.products where business_id = p_business and lower(code) = lower(v_code);
    if v_pid is null then v_new := v_new + 1; else v_upd := v_upd + 1;
      if (not app.blank(r->>'acilis_stogu') or not app.blank(r->>'alis_fiyati'))
         and exists (select 1 from public.stock_movements where product_id = v_pid) then
        v_warn := v_warn || jsonb_build_object('row', v_row, 'field', 'acilis_stogu',
                                               'message', 'Ürünün stok hareketi var; açılış stoğu ve alış fiyatı uygulanmayacak (E-03)');
      end if;
    end if;
    if not app.blank(r->>'marka') and not exists (select 1 from public.brands where business_id = p_business and lower(name) = lower(trim(r->>'marka')))
       and not (lower(trim(r->>'marka')) = any(v_brands)) then
      v_brands := v_brands || lower(trim(r->>'marka'));
    end if;
    if not app.blank(r->>'kategori') and not exists (select 1 from public.categories where business_id = p_business and lower(name) = lower(trim(r->>'kategori')))
       and not (lower(trim(r->>'kategori')) = any(v_cats)) then
      v_cats := v_cats || lower(trim(r->>'kategori'));
    end if;
  end loop;

  if p_dry_run or jsonb_array_length(v_errs) > 0 then
    return jsonb_build_object('ok', jsonb_array_length(v_errs) = 0, 'applied', false, 'errors', v_errs, 'warnings', v_warn,
      'summary', jsonb_build_object('rows', jsonb_array_length(p_rows), 'new', v_new, 'updated', v_upd,
                                    'new_brands', cardinality(v_brands), 'new_categories', cardinality(v_cats)));
  end if;

  -- 2) Kayıt: önce boş kaplar, sonra diğerleri
  for pass in 1..2 loop
    for r in select * from jsonb_array_elements(p_rows)
              where app.yes(value->>'bos_kap_mi', false) = (pass = 1) loop
      select id into v_brand from public.brands where business_id = p_business and lower(name) = lower(trim(r->>'marka'));
      if v_brand is null then v_brand := public.upsert_brand(p_business, trim(r->>'marka')); end if;
      select id into v_cat from public.categories where business_id = p_business and lower(name) = lower(trim(r->>'kategori'));
      if v_cat is null then v_cat := public.upsert_category(p_business, trim(r->>'kategori')); end if;
      v_empty := null;
      if app.yes(r->>'depozitolu', false) then
        select id into v_empty from public.products where business_id = p_business and lower(code) = lower(trim(r->>'bos_kap_urun_kodu'));
      end if;
      select id into v_pid from public.products where business_id = p_business and lower(code) = lower(trim(r->>'urun_kodu'));
      v_has_mov := v_pid is not null and exists (select 1 from public.stock_movements where product_id = v_pid);

      v_units := '[]';
      if not app.blank(r->>'paket_icerik') then
        v_units := v_units || jsonb_build_object('name', coalesce(nullif(trim(r->>'paket_adi'), ''), 'Paket'),
                                                 'factor', app.int(r->>'paket_icerik'), 'price', app.num(r->>'paket_satis_fiyati'), 'sort', 1);
      end if;
      if not app.blank(r->>'koli_icerik') then
        v_units := v_units || jsonb_build_object('name', coalesce(nullif(trim(r->>'koli_adi'), ''), 'Koli'),
                                                 'factor', app.int(r->>'koli_icerik'), 'price', app.num(r->>'koli_satis_fiyati'), 'sort', 2);
      end if;

      v_pid := public.upsert_product(p_business, jsonb_strip_nulls(jsonb_build_object(
        'id', v_pid, 'code', trim(r->>'urun_kodu'), 'name', trim(r->>'urun_adi'),
        'brand_id', v_brand, 'category_id', v_cat, 'base_unit_name', trim(r->>'temel_birim'),
        'vat_rate', app.int(r->>'kdv_orani'), 'critical_level', app.int(r->>'kritik_stok'),
        'is_container', app.yes(r->>'bos_kap_mi', false),
        'deposit_amount', case when app.yes(r->>'depozitolu', false) then app.num(r->>'depozito_tutari') end,
        'empty_product_id', v_empty, 'active', app.yes(r->>'aktif', true))) ||
        jsonb_build_object('base_price', app.num(r->>'satis_fiyati'), 'units', v_units,
                           'critical_level', app.int(r->>'kritik_stok'),
                           'barcodes', coalesce((select jsonb_agg(jsonb_build_object('barcode', trim(b)))
                                                   from unnest(string_to_array(coalesce(r->>'barkod', ''), '|')) b where trim(b) <> ''), '[]')));

      if not v_has_mov then
        if coalesce(app.int(r->>'acilis_stogu'), 0) > 0 then
          perform app.post_stock(p_business, v_loc, v_pid, app.int(r->>'acilis_stogu'), 'acilis', 'import', null, 'Açılış stoğu');
        end if;
        if app.num(r->>'alis_fiyati') is not null then
          perform app.set_avg_cost(v_pid, app.num(r->>'alis_fiyati'), 'acilis', null);
        end if;
      end if;
    end loop;
  end loop;

  perform app.audit(p_business, 'urun_ice_aktarma', 'products', null, null,
                    jsonb_build_object('rows', jsonb_array_length(p_rows), 'new', v_new, 'updated', v_upd));
  return jsonb_build_object('ok', true, 'applied', true, 'errors', '[]'::jsonb, 'warnings', v_warn,
    'summary', jsonb_build_object('rows', jsonb_array_length(p_rows), 'new', v_new, 'updated', v_upd,
                                  'new_brands', cardinality(v_brands), 'new_categories', cardinality(v_cats)));
end $$;

-- ---------------------------------------------------------------------------
-- Müşteri içe aktarma (sayfalar "Müşteriler" ve "Müşteri Kapları")
-- ---------------------------------------------------------------------------
create or replace function public.import_customers(p_business uuid, p_customers jsonb, p_containers jsonb default '[]', p_dry_run boolean default true)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r jsonb; v_row int; v_errs jsonb := '[]'; v_warn jsonb := '[]'; v_codes text[] := '{}'; f text;
  v_cid uuid; v_pid uuid; v_new int := 0; v_upd int := 0; v_bal numeric;
begin
  perform app.require_role(p_business, 'yonetici');
  for r in select * from jsonb_array_elements(coalesce(p_customers, '[]')) loop
    v_row := coalesce((r->>'row')::int, 0);
    foreach f in array array['musteri_kodu', 'ad_unvan'] loop
      if app.blank(r->>f) then v_errs := v_errs || jsonb_build_object('sheet', 'Müşteriler', 'row', v_row, 'field', f, 'message', 'Zorunlu alan boş'); end if;
    end loop;
    if lower(trim(r->>'musteri_kodu')) = any(v_codes) then
      v_errs := v_errs || jsonb_build_object('sheet', 'Müşteriler', 'row', v_row, 'field', 'musteri_kodu', 'message', 'Kod dosyada tekrar ediyor');
    end if;
    v_codes := v_codes || lower(trim(coalesce(r->>'musteri_kodu', '')));
    foreach f in array array['kredi_limiti', 'acilis_bakiyesi'] loop
      if not app.blank(r->>f) and app.num(r->>f) is null then
        v_errs := v_errs || jsonb_build_object('sheet', 'Müşteriler', 'row', v_row, 'field', f, 'message', 'Geçerli bir tutar değil');
      end if;
    end loop;
    if app.num(r->>'kredi_limiti') < 0 then
      v_errs := v_errs || jsonb_build_object('sheet', 'Müşteriler', 'row', v_row, 'field', 'kredi_limiti', 'message', 'Limit negatif olamaz');
    end if;
    if app.yes(r->>'limitsiz', false) is null then
      v_errs := v_errs || jsonb_build_object('sheet', 'Müşteriler', 'row', v_row, 'field', 'limitsiz', 'message', 'E veya H olmalı');
    end if;
    select id into v_cid from public.customers where business_id = p_business and lower(code) = lower(trim(r->>'musteri_kodu'));
    if v_cid is null then v_new := v_new + 1; else v_upd := v_upd + 1;
      if not app.blank(r->>'acilis_bakiyesi') and exists (select 1 from public.customer_ledger where customer_id = v_cid) then
        v_warn := v_warn || jsonb_build_object('sheet', 'Müşteriler', 'row', v_row, 'field', 'acilis_bakiyesi',
                                               'message', 'Müşterinin cari hareketi var; açılış bakiyesi uygulanmayacak');
      end if;
    end if;
  end loop;
  for r in select * from jsonb_array_elements(coalesce(p_containers, '[]')) loop
    v_row := coalesce((r->>'row')::int, 0);
    if not (lower(trim(coalesce(r->>'musteri_kodu', ''))) = any(v_codes))
       and not exists (select 1 from public.customers where business_id = p_business and lower(code) = lower(trim(r->>'musteri_kodu'))) then
      v_errs := v_errs || jsonb_build_object('sheet', 'Müşteri Kapları', 'row', v_row, 'field', 'musteri_kodu', 'message', 'Müşteri bulunamadı');
    end if;
    if not exists (select 1 from public.products where business_id = p_business and deposit_amount is not null
                    and lower(code) = lower(trim(r->>'dolu_urun_kodu'))) then
      v_errs := v_errs || jsonb_build_object('sheet', 'Müşteri Kapları', 'row', v_row, 'field', 'dolu_urun_kodu',
                                             'message', 'Depozitolu ürün bulunamadı; önce ürünleri aktarın');
    end if;
    if coalesce(app.int(r->>'kap_adedi'), 0) <= 0 then
      v_errs := v_errs || jsonb_build_object('sheet', 'Müşteri Kapları', 'row', v_row, 'field', 'kap_adedi', 'message', 'Pozitif tam sayı olmalı');
    end if;
  end loop;

  if p_dry_run or jsonb_array_length(v_errs) > 0 then
    return jsonb_build_object('ok', jsonb_array_length(v_errs) = 0, 'applied', false, 'errors', v_errs, 'warnings', v_warn,
      'summary', jsonb_build_object('rows', jsonb_array_length(coalesce(p_customers, '[]')), 'new', v_new, 'updated', v_upd,
                                    'containers', jsonb_array_length(coalesce(p_containers, '[]'))));
  end if;

  for r in select * from jsonb_array_elements(coalesce(p_customers, '[]')) loop
    select id into v_cid from public.customers where business_id = p_business and lower(code) = lower(trim(r->>'musteri_kodu'));
    v_cid := public.upsert_customer(p_business, jsonb_build_object('id', v_cid, 'code', trim(r->>'musteri_kodu'),
      'name', r->>'ad_unvan', 'phone', r->>'telefon', 'address', r->>'adres', 'tax_no', r->>'vergi_no',
      'credit_limit', coalesce(app.num(r->>'kredi_limiti'), 0), 'unlimited_credit', app.yes(r->>'limitsiz', false)));
    v_bal := app.num(r->>'acilis_bakiyesi');
    if coalesce(v_bal, 0) <> 0 and not exists (select 1 from public.customer_ledger where customer_id = v_cid) then
      insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, note, created_by)
      values (p_business, v_cid, 'acilis', v_bal, 'import', 'Açılış bakiyesi', auth.uid());
    end if;
  end loop;
  for r in select * from jsonb_array_elements(coalesce(p_containers, '[]')) loop
    select id into v_cid from public.customers where business_id = p_business and lower(code) = lower(trim(r->>'musteri_kodu'));
    select id into v_pid from public.products where business_id = p_business and lower(code) = lower(trim(r->>'dolu_urun_kodu'));
    insert into public.container_ledger(business_id, customer_id, product_id, qty, amount, type, ref_type, created_by)
    values (p_business, v_cid, v_pid, app.int(r->>'kap_adedi'), coalesce(app.num(r->>'odenen_depozito'), 0), 'acilis', 'import', auth.uid());
  end loop;
  perform app.audit(p_business, 'musteri_ice_aktarma', 'customers', null, null,
                    jsonb_build_object('new', v_new, 'updated', v_upd, 'containers', jsonb_array_length(coalesce(p_containers, '[]'))));
  return jsonb_build_object('ok', true, 'applied', true, 'errors', '[]'::jsonb, 'warnings', v_warn,
    'summary', jsonb_build_object('new', v_new, 'updated', v_upd, 'containers', jsonb_array_length(coalesce(p_containers, '[]'))));
end $$;

-- ---------------------------------------------------------------------------
-- Stok sayımı (T-04)
-- ---------------------------------------------------------------------------
create table public.stock_counts (
  id            uuid primary key,
  business_id   uuid not null references public.businesses(id),
  location_id   uuid not null references public.locations(id),
  no            bigint not null,
  scope         text not null check (scope in ('tam', 'kismi')),
  status        text not null default 'acik' check (status in ('acik', 'onaylandi', 'iptal')),
  snapshot_movement_id bigint not null,
  note          text,
  started_by    uuid,
  started_at    timestamptz not null default now(),
  decided_by    uuid,
  decided_at    timestamptz,
  unique (business_id, no)
);
create unique index stock_counts_one_open on public.stock_counts(location_id) where status = 'acik';

create table public.stock_count_lines (
  count_id      uuid not null references public.stock_counts(id),
  business_id   uuid not null references public.businesses(id),
  product_id    uuid not null references public.products(id),
  snapshot_qty  integer not null,
  counted_qty   integer check (counted_qty >= 0),
  counted_by    uuid,
  counted_at    timestamptz,
  moved_during  integer,
  diff          integer,
  primary key (count_id, product_id)
);

alter table public.stock_counts enable row level security;
alter table public.stock_count_lines enable row level security;
create policy stock_counts_select on public.stock_counts for select to authenticated using (app.has_role(business_id, 'yonetici', 'depo'));
create policy stock_count_lines_select on public.stock_count_lines for select to authenticated using (app.has_role(business_id, 'yonetici', 'depo'));

-- p = { id, product_ids?: [uuid] (boşsa tam sayım), note? }
create or replace function public.start_stock_count(p_business uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := (p->>'id')::uuid; v_loc uuid := app.default_location(p_business); v_scope text; v_no bigint;
begin
  perform app.require_role(p_business, 'yonetici', 'depo');
  if exists (select 1 from public.stock_counts where id = v_id) then
    return (select jsonb_build_object('id', id, 'no', no, 'duplicate', true) from public.stock_counts where id = v_id);
  end if;
  if exists (select 1 from public.stock_counts where location_id = v_loc and status = 'acik') then
    raise exception 'Açık bir sayım var; önce onu tamamlayın veya iptal edin' using errcode = 'P0001';
  end if;
  v_scope := case when jsonb_array_length(coalesce(p->'product_ids', '[]')) = 0 then 'tam' else 'kismi' end;
  v_no := app.next_number(p_business, 'sayim');
  insert into public.stock_counts(id, business_id, location_id, no, scope, snapshot_movement_id, note, started_by)
  values (v_id, p_business, v_loc, v_no, v_scope,
          coalesce((select max(id) from public.stock_movements), 0), nullif(trim(p->>'note'), ''), auth.uid());
  insert into public.stock_count_lines(count_id, business_id, product_id, snapshot_qty)
  select v_id, p_business, pr.id, coalesce(l.qty, 0)
    from public.products pr left join public.stock_levels l on l.product_id = pr.id and l.location_id = v_loc
   where pr.business_id = p_business
     and (v_scope = 'tam' and pr.active
          or pr.id in (select (x #>> '{}')::uuid from jsonb_array_elements(p->'product_ids') x));
  return jsonb_build_object('id', v_id, 'no', v_no, 'duplicate', false,
                            'lines', (select count(*) from public.stock_count_lines where count_id = v_id));
end $$;

-- p_lines = [{ product_id, counted_qty (temel birim) | null }]
create or replace function public.save_stock_count_lines(p_count uuid, p_lines jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.stock_counts; x jsonb;
begin
  select * into c from public.stock_counts where id = p_count;
  if c.id is null then raise exception 'Sayım bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(c.business_id, 'yonetici', 'depo');
  if c.status <> 'acik' then raise exception 'Sayım kapanmış' using errcode = 'P0001'; end if;
  for x in select * from jsonb_array_elements(p_lines) loop
    if (x->>'counted_qty') is not null and (x->>'counted_qty')::int < 0 then
      raise exception 'Sayılan miktar negatif olamaz' using errcode = '22023';
    end if;
    update public.stock_count_lines set counted_qty = (x->>'counted_qty')::int, counted_by = auth.uid(), counted_at = now()
     where count_id = p_count and product_id = (x->>'product_id')::uuid;
    if not found then raise exception 'Ürün bu sayımda yok' using errcode = 'P0002'; end if;
  end loop;
end $$;

-- Onay: fark = sayılan − (anlık görüntü + sayım süresindeki hareketler)
create or replace function public.approve_stock_count(p_count uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.stock_counts; l record; v_moved int; v_diff int; v_n int := 0; v_total int := 0;
begin
  select * into c from public.stock_counts where id = p_count for update;
  if c.id is null then raise exception 'Sayım bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(c.business_id, 'yonetici');
  if c.status <> 'acik' then raise exception 'Sayım zaten kapanmış' using errcode = 'P0001'; end if;
  for l in select * from public.stock_count_lines where count_id = p_count and counted_qty is not null order by product_id loop
    select coalesce(sum(qty), 0) into v_moved from public.stock_movements
     where product_id = l.product_id and location_id = c.location_id and id > c.snapshot_movement_id;
    v_diff := l.counted_qty - (l.snapshot_qty + v_moved);
    update public.stock_count_lines set moved_during = v_moved, diff = v_diff where count_id = p_count and product_id = l.product_id;
    if v_diff <> 0 then
      perform app.post_stock(c.business_id, c.location_id, l.product_id, v_diff, 'sayim_duzeltme', 'stock_count', p_count);
      v_n := v_n + 1; v_total := v_total + v_diff;
    end if;
  end loop;
  update public.stock_counts set status = 'onaylandi', decided_by = auth.uid(), decided_at = now() where id = p_count;
  perform app.audit(c.business_id, 'sayim_onay', 'stock_counts', p_count::text, null,
                    jsonb_build_object('adjusted_products', v_n, 'net_diff', v_total));
  return jsonb_build_object('adjusted_products', v_n, 'net_diff', v_total);
end $$;

create or replace function public.cancel_stock_count(p_count uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.stock_counts;
begin
  select * into c from public.stock_counts where id = p_count for update;
  if c.id is null then raise exception 'Sayım bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(c.business_id, 'yonetici');
  if c.status <> 'acik' then raise exception 'Sayım zaten kapanmış' using errcode = 'P0001'; end if;
  update public.stock_counts set status = 'iptal', decided_by = auth.uid(), decided_at = now() where id = p_count;
end $$;

select app.apply_grants();
