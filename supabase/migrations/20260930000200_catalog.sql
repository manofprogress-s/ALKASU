-- ALKASU 0002 — Katalog: marka, kategori, ürün, birim, barkod, fiyat geçmişi, maliyet, tedarikçi
-- Kurallar: B-01..B-06, F-01..F-03, M-01, D-01, D-02, Y-02 · Kararlar: T-006

create table public.brands (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id),
  name         text not null check (length(trim(name)) > 0),
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);
create unique index brands_name on public.brands(business_id, lower(name));

create table public.categories (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id),
  name         text not null check (length(trim(name)) > 0),
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);
create unique index categories_name on public.categories(business_id, lower(name));

create table public.products (
  id                uuid primary key default gen_random_uuid(),
  business_id       uuid not null references public.businesses(id),
  code              text not null check (length(trim(code)) > 0),
  name              text not null check (length(trim(name)) > 0),
  brand_id          uuid references public.brands(id),
  category_id       uuid references public.categories(id),
  base_unit_name    text not null default 'Adet',
  vat_rate          smallint not null default 1 check (vat_rate in (0, 1, 10, 20)),
  critical_level    integer check (critical_level >= 0),
  is_container      boolean not null default false,  -- boş kap ürünü (satılmaz) D-01
  deposit_amount    numeric(14,2) check (deposit_amount > 0),
  empty_product_id  uuid references public.products(id),
  active            boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint products_deposit_needs_empty check ((deposit_amount is null) = (empty_product_id is null)),
  constraint products_container_no_deposit check (not (is_container and deposit_amount is not null))
);
create unique index products_code on public.products(business_id, lower(code));
create index products_name_search on public.products(business_id, lower(name));

create table public.product_units (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id),
  product_id   uuid not null references public.products(id),
  name         text not null check (length(trim(name)) > 0),
  factor       integer not null check (factor >= 1),
  is_base      boolean not null default false,
  price        numeric(14,2) check (price >= 0),        -- güncel KDV dahil fiyat; null = satılamaz
  active       boolean not null default true,
  sort         smallint not null default 0,
  created_at   timestamptz not null default now(),
  constraint product_units_base_factor check (not is_base or factor = 1)
);
create unique index product_units_one_base on public.product_units(product_id) where is_base;
create unique index product_units_active_name on public.product_units(product_id, lower(name)) where active;
create index product_units_product on public.product_units(product_id);

-- B-06: çarpan değiştirilemez
create or replace function app.tg_unit_factor_immutable() returns trigger
language plpgsql as $$
begin
  if new.factor <> old.factor then
    raise exception 'Birim çarpanı değiştirilemez; yeni birim tanımlayın (B-06)' using errcode = 'P0001';
  end if;
  if new.product_id <> old.product_id or new.is_base <> old.is_base then
    raise exception 'Birimin ürünü veya temel birim durumu değiştirilemez' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger product_units_factor before update on public.product_units
  for each row execute function app.tg_unit_factor_immutable();

create table public.product_barcodes (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id),
  product_id   uuid not null references public.products(id),
  unit_id      uuid references public.product_units(id),   -- null = temel birim
  barcode      text not null check (barcode ~ '^[0-9A-Za-z\-\.]{3,64}$'),
  created_at   timestamptz not null default now()
);
create unique index product_barcodes_code on public.product_barcodes(business_id, barcode);

-- F-03: fiyat geçmişi
create table public.product_prices (
  id           bigint generated always as identity primary key,
  business_id  uuid not null references public.businesses(id),
  unit_id      uuid not null references public.product_units(id),
  price        numeric(14,2) check (price >= 0),
  valid_from   timestamptz not null default now(),
  created_by   uuid,
  source       text not null default 'manuel'
);
create index product_prices_unit on public.product_prices(unit_id, valid_from desc);

-- 🔒 Maliyet (yalnızca yönetici) — T-006
create table public.product_costs (
  product_id   uuid primary key references public.products(id),
  business_id  uuid not null references public.businesses(id),
  avg_cost     numeric(14,4) not null default 0 check (avg_cost >= 0),  -- temel birim başına, KDV dahil
  has_cost     boolean not null default false,
  updated_at   timestamptz not null default now()
);

create table public.cost_history (
  id           bigint generated always as identity primary key,
  business_id  uuid not null references public.businesses(id),
  product_id   uuid not null references public.products(id),
  old_cost     numeric(14,4),
  new_cost     numeric(14,4) not null,
  source       text not null,          -- acilis | mal_kabul | manuel
  ref_id       uuid,
  created_by   uuid,
  created_at   timestamptz not null default now()
);
create index cost_history_product on public.cost_history(product_id, created_at desc);

create table public.suppliers (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id),
  name         text not null check (length(trim(name)) > 0),
  phone        text,
  note         text,
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);
create unique index suppliers_name on public.suppliers(business_id, lower(name));

create trigger products_touch before update on public.products for each row execute function app.touch_updated_at();
create trigger products_audit after insert or update on public.products for each row execute function audit.tg_row();
create trigger product_units_audit after insert or update on public.product_units for each row execute function audit.tg_row();
create trigger brands_audit after insert or update on public.brands for each row execute function audit.tg_row();
create trigger categories_audit after insert or update on public.categories for each row execute function audit.tg_row();
create trigger suppliers_audit after insert or update on public.suppliers for each row execute function audit.tg_row();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.brands           enable row level security;
alter table public.categories       enable row level security;
alter table public.products         enable row level security;
alter table public.product_units    enable row level security;
alter table public.product_barcodes enable row level security;
alter table public.product_prices   enable row level security;
alter table public.product_costs    enable row level security;
alter table public.cost_history     enable row level security;
alter table public.suppliers        enable row level security;

create policy brands_select     on public.brands           for select to authenticated using (app.is_member(business_id));
create policy categories_select on public.categories       for select to authenticated using (app.is_member(business_id));
create policy products_select   on public.products         for select to authenticated using (app.is_member(business_id));
create policy units_select      on public.product_units    for select to authenticated using (app.is_member(business_id));
create policy barcodes_select   on public.product_barcodes for select to authenticated using (app.is_member(business_id));
create policy prices_select     on public.product_prices   for select to authenticated using (app.is_member(business_id));
create policy costs_select      on public.product_costs    for select to authenticated using (app.is_admin(business_id));
create policy cost_hist_select  on public.cost_history     for select to authenticated using (app.is_admin(business_id));
create policy suppliers_select  on public.suppliers        for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'depo'));

-- ---------------------------------------------------------------------------
-- İç yardımcılar
-- ---------------------------------------------------------------------------
create or replace function app.set_unit_price(p_unit uuid, p_price numeric, p_source text default 'manuel')
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.product_units;
begin
  select * into u from public.product_units where id = p_unit for update;
  if u.price is distinct from p_price then
    update public.product_units set price = p_price where id = p_unit;
    insert into public.product_prices(business_id, unit_id, price, created_by, source)
    values (u.business_id, p_unit, p_price, auth.uid(), p_source);
  end if;
end $$;

-- Belirli bir andaki birim fiyatı (C-02 çevrimdışı fiyat doğrulaması)
create or replace function app.unit_price_at(p_unit uuid, p_at timestamptz) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select price from public.product_prices
  where unit_id = p_unit and valid_from <= p_at
  order by valid_from desc, id desc limit 1
$$;

create or replace function app.set_avg_cost(p_product uuid, p_cost numeric, p_source text, p_ref uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_old numeric; v_bid uuid;
begin
  select business_id into v_bid from public.products where id = p_product;
  select avg_cost into v_old from public.product_costs where product_id = p_product for update;
  insert into public.product_costs(product_id, business_id, avg_cost, has_cost, updated_at)
  values (p_product, v_bid, round(p_cost, 4), true, now())
  on conflict (product_id) do update set avg_cost = excluded.avg_cost, has_cost = true, updated_at = now();
  if v_old is distinct from round(p_cost, 4) then
    insert into public.cost_history(business_id, product_id, old_cost, new_cost, source, ref_id, created_by)
    values (v_bid, p_product, v_old, round(p_cost, 4), p_source, p_ref, auth.uid());
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- RPC: marka / kategori / tedarikçi
-- ---------------------------------------------------------------------------
create or replace function public.upsert_brand(p_business uuid, p_name text, p_id uuid default null, p_active boolean default true)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  perform app.require_role(p_business, 'yonetici');
  if p_id is null then
    insert into public.brands(business_id, name, active) values (p_business, trim(p_name), p_active) returning id into v_id;
  else
    update public.brands set name = trim(p_name), active = p_active
     where id = p_id and business_id = p_business returning id into v_id;
    if v_id is null then raise exception 'Marka bulunamadı' using errcode = 'P0002'; end if;
  end if;
  return v_id;
exception when unique_violation then
  raise exception 'Bu adla bir marka zaten var: %', p_name using errcode = '23505';
end $$;

create or replace function public.upsert_category(p_business uuid, p_name text, p_id uuid default null, p_active boolean default true)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  perform app.require_role(p_business, 'yonetici');
  if p_id is null then
    insert into public.categories(business_id, name, active) values (p_business, trim(p_name), p_active) returning id into v_id;
  else
    update public.categories set name = trim(p_name), active = p_active
     where id = p_id and business_id = p_business returning id into v_id;
    if v_id is null then raise exception 'Kategori bulunamadı' using errcode = 'P0002'; end if;
  end if;
  return v_id;
exception when unique_violation then
  raise exception 'Bu adla bir kategori zaten var: %', p_name using errcode = '23505';
end $$;

create or replace function public.upsert_supplier(p_business uuid, p jsonb)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid;
begin
  perform app.require_role(p_business, 'yonetici', 'depo');
  if v_id is null then
    insert into public.suppliers(business_id, name, phone, note)
    values (p_business, trim(p->>'name'), nullif(trim(p->>'phone'), ''), nullif(trim(p->>'note'), ''))
    returning id into v_id;
  else
    update public.suppliers set
      name = trim(p->>'name'), phone = nullif(trim(p->>'phone'), ''), note = nullif(trim(p->>'note'), ''),
      active = coalesce((p->>'active')::boolean, active)
    where id = v_id and business_id = p_business returning id into v_id;
    if v_id is null then raise exception 'Tedarikçi bulunamadı' using errcode = 'P0002'; end if;
  end if;
  return v_id;
exception when unique_violation then
  raise exception 'Bu adla bir tedarikçi zaten var' using errcode = '23505';
end $$;

-- ---------------------------------------------------------------------------
-- RPC: ürün kartı (yönetici)
-- p = { id?, code, name, brand_id?, category_id?, base_unit_name, base_price?, vat_rate,
--       critical_level?, is_container?, deposit_amount?, empty_product_id?, active?,
--       units: [{id?, name, factor, price?, active?}],   -- en fazla 2 aktif ek birim (B-02)
--       barcodes: [{barcode, unit_id?|unit_name?}] }     -- verilirse tamamen değiştirilir
-- ---------------------------------------------------------------------------
create or replace function public.upsert_product(p_business uuid, p jsonb)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id      uuid := nullif(p->>'id', '')::uuid;
  v_old     public.products;
  v_base    uuid;
  v_unit    jsonb;
  v_uid     uuid;
  v_ex      public.product_units;
  v_keep    uuid[] := '{}';
  v_bc      jsonb;
  v_empty   public.products;
  v_is_cont boolean := coalesce((p->>'is_container')::boolean, false);
  v_dep     numeric := nullif(p->>'deposit_amount', '')::numeric;
  v_emp_id  uuid := nullif(p->>'empty_product_id', '')::uuid;
begin
  perform app.require_role(p_business, 'yonetici');

  if coalesce(trim(p->>'code'), '') = '' or coalesce(trim(p->>'name'), '') = '' then
    raise exception 'Ürün kodu ve adı zorunludur' using errcode = '22023';
  end if;
  if v_emp_id is not null then
    select * into v_empty from public.products where id = v_emp_id and business_id = p_business;
    if v_empty.id is null or not v_empty.is_container then
      raise exception 'Bağlı boş kap ürünü geçersiz; "boş kap" olarak tanımlı bir ürün seçin' using errcode = '22023';
    end if;
  end if;
  if exists (select 1 from public.products where business_id = p_business
              and lower(code) = lower(trim(p->>'code')) and id is distinct from v_id) then
    raise exception 'Bu ürün kodu zaten kullanılıyor: %', p->>'code' using errcode = '23505';
  end if;
  if v_dep is not null and v_emp_id is null then
    raise exception 'Depozitolu ürün için boş kap ürünü seçilmelidir (D-01)' using errcode = '22023';
  end if;

  if v_id is null then
    insert into public.products(business_id, code, name, brand_id, category_id, base_unit_name, vat_rate,
                                critical_level, is_container, deposit_amount, empty_product_id, active)
    values (p_business, trim(p->>'code'), trim(p->>'name'),
            nullif(p->>'brand_id', '')::uuid, nullif(p->>'category_id', '')::uuid,
            coalesce(nullif(trim(p->>'base_unit_name'), ''), 'Adet'),
            coalesce((p->>'vat_rate')::smallint, 1),
            nullif(p->>'critical_level', '')::int, v_is_cont, v_dep, v_emp_id,
            coalesce((p->>'active')::boolean, true))
    returning id into v_id;
    insert into public.product_units(business_id, product_id, name, factor, is_base, sort)
    values (p_business, v_id, coalesce(nullif(trim(p->>'base_unit_name'), ''), 'Adet'), 1, true, 0)
    returning id into v_base;
    insert into public.product_costs(product_id, business_id) values (v_id, p_business);
  else
    select * into v_old from public.products where id = v_id and business_id = p_business for update;
    if v_old.id is null then raise exception 'Ürün bulunamadı' using errcode = 'P0002'; end if;
    update public.products set
      code = trim(p->>'code'), name = trim(p->>'name'),
      brand_id = nullif(p->>'brand_id', '')::uuid, category_id = nullif(p->>'category_id', '')::uuid,
      base_unit_name = coalesce(nullif(trim(p->>'base_unit_name'), ''), base_unit_name),
      vat_rate = coalesce((p->>'vat_rate')::smallint, vat_rate),
      critical_level = nullif(p->>'critical_level', '')::int,
      is_container = v_is_cont, deposit_amount = v_dep, empty_product_id = v_emp_id,
      active = coalesce((p->>'active')::boolean, active)
    where id = v_id;
    select id into v_base from public.product_units where product_id = v_id and is_base;
    update public.product_units set name = (select base_unit_name from public.products where id = v_id)
     where id = v_base;
  end if;

  -- Temel birim fiyatı
  if p ? 'base_price' then
    perform app.set_unit_price(v_base, case when v_is_cont then null else nullif(p->>'base_price', '')::numeric end);
  end if;
  v_keep := array[v_base];

  -- Ek birimler
  if p ? 'units' then
    for v_unit in select * from jsonb_array_elements(coalesce(p->'units', '[]'::jsonb)) loop
      v_uid := nullif(v_unit->>'id', '')::uuid;
      if coalesce((v_unit->>'factor')::int, 0) < 2 then
        raise exception 'Ek birim çarpanı 1''den büyük tam sayı olmalıdır (B-02): %', v_unit->>'name' using errcode = '22023';
      end if;
      if v_uid is null then
        -- Aynı ad + çarpanla aktif bir birim varsa onu kullan
        select * into v_ex from public.product_units
         where product_id = v_id and not is_base and active and lower(name) = lower(trim(v_unit->>'name'));
        if v_ex.id is not null and v_ex.factor <> (v_unit->>'factor')::int then
          -- B-06: eski birimi pasife al, yenisini oluştur
          update public.product_units set active = false where id = v_ex.id;
          v_ex := null;
        end if;
        if v_ex.id is null then
          insert into public.product_units(business_id, product_id, name, factor, sort, active)
          values (p_business, v_id, trim(v_unit->>'name'), (v_unit->>'factor')::int,
                  coalesce((v_unit->>'sort')::smallint, 1), coalesce((v_unit->>'active')::boolean, true))
          returning id into v_uid;
        else
          v_uid := v_ex.id;
        end if;
      else
        update public.product_units set name = trim(v_unit->>'name'),
               factor = (v_unit->>'factor')::int,
               active = coalesce((v_unit->>'active')::boolean, true)
         where id = v_uid and product_id = v_id and not is_base;
        if not found then raise exception 'Birim bulunamadı' using errcode = 'P0002'; end if;
      end if;
      perform app.set_unit_price(v_uid, case when v_is_cont then null else nullif(v_unit->>'price', '')::numeric end);
      if coalesce((v_unit->>'active')::boolean, true) then v_keep := v_keep || v_uid; end if;
    end loop;
    update public.product_units set active = false
     where product_id = v_id and not is_base and active and not (id = any(v_keep));
    if (select count(*) from public.product_units where product_id = v_id and not is_base and active) > 2 then
      raise exception 'Bir ürünün en fazla 2 aktif ek birimi olabilir (B-02)' using errcode = '22023';
    end if;
  end if;

  -- Barkodlar
  if p ? 'barcodes' then
    delete from public.product_barcodes where product_id = v_id;
    for v_bc in select * from jsonb_array_elements(coalesce(p->'barcodes', '[]'::jsonb)) loop
      begin
        insert into public.product_barcodes(business_id, product_id, unit_id, barcode)
        values (p_business, v_id,
                coalesce(nullif(v_bc->>'unit_id', '')::uuid,
                         (select id from public.product_units where product_id = v_id and active
                            and lower(name) = lower(v_bc->>'unit_name') limit 1)),
                trim(v_bc->>'barcode'));
      exception when unique_violation then
        raise exception 'Barkod başka bir üründe kayıtlı: %', v_bc->>'barcode' using errcode = '23505';
      end;
    end loop;
  end if;

  return v_id;
end $$;

create or replace function public.set_unit_price(p_unit uuid, p_price numeric)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bid uuid; v_cont boolean;
begin
  select u.business_id, pr.is_container into v_bid, v_cont
    from public.product_units u join public.products pr on pr.id = u.product_id where u.id = p_unit;
  if v_bid is null then raise exception 'Birim bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(v_bid, 'yonetici');
  if v_cont and p_price is not null then
    raise exception 'Boş kap ürünü satılmaz, fiyatı olamaz' using errcode = '22023';
  end if;
  if p_price < 0 then raise exception 'Fiyat negatif olamaz' using errcode = '22023'; end if;
  perform app.set_unit_price(p_unit, p_price);
end $$;

select app.apply_grants();
