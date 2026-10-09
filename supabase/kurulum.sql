-- ALKASU veritabanı kurulumu (tüm migrationlar, sırayla). Supabase SQL Editor'de bir kez çalıştırın.
begin;

-- ===== 20260930000100_foundation.sql =====
-- ALKASU 0001 — Temel: işletme, lokasyon, üyelik/rol, ayarlar, denetim kaydı, yardımcı fonksiyonlar
-- Kurallar: G-01, G-05, Y-01, Y-04, L-01..L-03 · Kararlar: T-004, T-005, T-020

create extension if not exists pgcrypto;

create schema if not exists app;    -- iç yardımcılar (API'ye açılmaz)
create schema if not exists audit;  -- denetim kaydı

revoke all on schema app from public;
revoke all on schema audit from public;
grant usage on schema app to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Tipler
-- ---------------------------------------------------------------------------
create type public.member_role as enum ('yonetici', 'satis', 'depo', 'izleyici');

-- ---------------------------------------------------------------------------
-- İşletme, lokasyon, üyelik
-- ---------------------------------------------------------------------------
create table public.businesses (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) > 0),
  timezone    text not null default 'Europe/Istanbul',
  currency    text not null default 'TRY',
  created_at  timestamptz not null default now()
);

create table public.locations (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id),
  name         text not null,
  is_default   boolean not null default false,
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);
create unique index locations_one_default on public.locations(business_id) where is_default;

create table public.memberships (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references public.businesses(id),
  user_id       uuid not null references auth.users(id),
  role          public.member_role not null,
  display_name  text not null,
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (business_id, user_id)
);
create index memberships_user on public.memberships(user_id) where active;

-- Anahtar/değer ayarlar (F-06 indirim limiti, K-04 kasa toleransı, T-05 kritik stok gün sayısı ...)
create table public.app_settings (
  business_id  uuid primary key references public.businesses(id),
  max_discount_pct_satis   numeric(5,2) not null default 5    check (max_discount_pct_satis between 0 and 100),
  cash_diff_tolerance      numeric(14,2) not null default 50  check (cash_diff_tolerance >= 0),
  critical_stock_days      integer not null default 7         check (critical_stock_days between 1 and 90),
  offline_stale_hours      integer not null default 72        check (offline_stale_hours > 0),
  updated_at   timestamptz not null default now()
);

-- Belge numaraları (satış no, mal kabul no ...)
create table public.business_counters (
  business_id uuid not null references public.businesses(id),
  name        text not null,
  value       bigint not null default 0,
  primary key (business_id, name)
);

-- ---------------------------------------------------------------------------
-- Denetim kaydı (L-01, L-02): yalnızca SECURITY DEFINER fonksiyonlar yazar.
-- ---------------------------------------------------------------------------
create table audit.log (
  id           bigint generated always as identity primary key,
  business_id  uuid,
  user_id      uuid,
  at           timestamptz not null default now(),
  action       text not null,
  table_name   text,
  record_id    text,
  old_data     jsonb,
  new_data     jsonb,
  client_info  text
);
create index audit_log_business_at on audit.log(business_id, at desc);
create index audit_log_record on audit.log(table_name, record_id);

create or replace function audit.block_changes() returns trigger
language plpgsql as $$
begin
  raise exception 'Denetim kaydı değiştirilemez veya silinemez (L-02)' using errcode = 'P0001';
end $$;
create trigger audit_log_immutable before update or delete on audit.log
  for each row execute function audit.block_changes();
create trigger audit_log_no_truncate before truncate on audit.log
  for each statement execute function audit.block_changes();

-- ---------------------------------------------------------------------------
-- Yardımcılar
-- ---------------------------------------------------------------------------
create or replace function app.uid() returns uuid
language sql stable as $$ select auth.uid() $$;

create or replace function app.client_info() returns text
language sql stable as $$
  select nullif(current_setting('request.headers', true), '')::jsonb ->> 'user-agent'
$$;

-- Kullanıcının bu işletmedeki aktif rolü (yoksa null)
create or replace function app.role_in(p_business uuid) returns public.member_role
language sql stable security definer set search_path = public, pg_temp as $$
  select m.role from public.memberships m
  where m.business_id = p_business and m.user_id = auth.uid() and m.active
$$;

create or replace function app.is_member(p_business uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select app.role_in(p_business) is not null
$$;

create or replace function app.has_role(p_business uuid, variadic p_roles public.member_role[]) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(app.role_in(p_business) = any(p_roles), false)
$$;

create or replace function app.is_admin(p_business uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select app.has_role(p_business, 'yonetici')
$$;

-- Yetki yoksa hata fırlatır; rolü döner.
create or replace function app.require_role(p_business uuid, variadic p_roles public.member_role[])
returns public.member_role
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r public.member_role;
begin
  if auth.uid() is null then
    raise exception 'Oturum açmanız gerekiyor' using errcode = '28000';
  end if;
  r := app.role_in(p_business);
  if r is null or not (r = any(p_roles)) then
    raise exception 'Bu işlem için yetkiniz yok' using errcode = '42501';
  end if;
  return r;
end $$;

create or replace function app.audit(
  p_business uuid, p_action text, p_table text, p_record text,
  p_old jsonb default null, p_new jsonb default null
) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into audit.log(business_id, user_id, action, table_name, record_id, old_data, new_data, client_info)
  values (p_business, auth.uid(), p_action, p_table, p_record, p_old, p_new, app.client_info());
$$;

-- Genel satır denetim tetikleyicisi (kart tabloları için)
create or replace function audit.tg_row() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end;
  v_bid uuid  := coalesce((v_new->>'business_id')::uuid, (v_old->>'business_id')::uuid);
  v_id  text  := coalesce(v_new->>'id', v_old->>'id', v_new->>'business_id');
begin
  if tg_op = 'UPDATE' and v_old = v_new then return new; end if;
  insert into audit.log(business_id, user_id, action, table_name, record_id, old_data, new_data, client_info)
  values (v_bid, auth.uid(), lower(tg_op), tg_table_name, v_id, v_old, v_new, app.client_info());
  return coalesce(new, old);
end $$;

create or replace function app.touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;

-- Sıradaki belge numarası
create or replace function app.next_number(p_business uuid, p_name text) returns bigint
language plpgsql security definer set search_path = public, pg_temp as $$
declare v bigint;
begin
  insert into public.business_counters(business_id, name, value) values (p_business, p_name, 1)
  on conflict (business_id, name) do update set value = public.business_counters.value + 1
  returning value into v;
  return v;
end $$;

-- İstanbul saatine göre gün
create or replace function app.local_date(p_ts timestamptz) returns date
language sql immutable as $$ select (p_ts at time zone 'Europe/Istanbul')::date $$;

-- Varsayılan lokasyon
create or replace function app.default_location(p_business uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select id from public.locations where business_id = p_business and is_default
$$;

-- ---------------------------------------------------------------------------
-- Y-04: En az bir aktif yönetici kalmalı
-- ---------------------------------------------------------------------------
create or replace function app.tg_keep_one_admin() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if old.role = 'yonetici' and old.active
     and (new.role <> 'yonetici' or not new.active) then
    if not exists (
      select 1 from public.memberships
      where business_id = old.business_id and id <> old.id and role = 'yonetici' and active
    ) then
      raise exception 'İşletmede en az bir aktif yönetici kalmalıdır (Y-04)' using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;

create trigger memberships_keep_admin before update on public.memberships
  for each row execute function app.tg_keep_one_admin();
create trigger memberships_touch before update on public.memberships
  for each row execute function app.touch_updated_at();
create trigger memberships_audit after insert or update on public.memberships
  for each row execute function audit.tg_row();
create trigger settings_audit after insert or update on public.app_settings
  for each row execute function audit.tg_row();
create trigger settings_touch before update on public.app_settings
  for each row execute function app.touch_updated_at();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.businesses        enable row level security;
alter table public.locations         enable row level security;
alter table public.memberships       enable row level security;
alter table public.app_settings      enable row level security;
alter table public.business_counters enable row level security;
alter table audit.log                enable row level security;

create policy businesses_select on public.businesses for select to authenticated
  using (app.is_member(id));
create policy locations_select on public.locations for select to authenticated
  using (app.is_member(business_id));
create policy memberships_select on public.memberships for select to authenticated
  using (user_id = auth.uid() or app.is_admin(business_id));
create policy settings_select on public.app_settings for select to authenticated
  using (app.is_member(business_id));
create policy audit_select on audit.log for select to authenticated
  using (app.is_admin(business_id));

-- ---------------------------------------------------------------------------
-- RPC: oturumdaki kullanıcının bağlamı
-- ---------------------------------------------------------------------------
create or replace function public.my_context() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'business_id', b.id, 'business_name', b.name,
    'location_id', app.default_location(b.id),
    'membership_id', m.id, 'role', m.role, 'display_name', m.display_name
  ) order by b.name), '[]'::jsonb)
  from public.memberships m join public.businesses b on b.id = m.business_id
  where m.user_id = auth.uid() and m.active
$$;

-- RPC: kullanıcı yönetimi (davet sunucu tarafında service_role ile yapılır, T-021)
create or replace function public.add_member(p_business uuid, p_user uuid, p_role public.member_role, p_name text)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    perform app.require_role(p_business, 'yonetici');
  end if;
  insert into public.memberships(business_id, user_id, role, display_name)
  values (p_business, p_user, p_role, trim(p_name))
  on conflict (business_id, user_id) do update
    set role = excluded.role, display_name = excluded.display_name, active = true
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.update_member(p_membership uuid, p_role public.member_role, p_name text, p_active boolean)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bid uuid;
begin
  select business_id into v_bid from public.memberships where id = p_membership;
  if v_bid is null then raise exception 'Kullanıcı bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(v_bid, 'yonetici');
  update public.memberships
     set role = p_role, display_name = trim(p_name), active = p_active
   where id = p_membership;
end $$;

create or replace function public.update_settings(p_business uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app.require_role(p_business, 'yonetici');
  update public.app_settings set
    max_discount_pct_satis = coalesce((p->>'max_discount_pct_satis')::numeric, max_discount_pct_satis),
    cash_diff_tolerance    = coalesce((p->>'cash_diff_tolerance')::numeric, cash_diff_tolerance),
    critical_stock_days    = coalesce((p->>'critical_stock_days')::int, critical_stock_days),
    offline_stale_hours    = coalesce((p->>'offline_stale_hours')::int, offline_stale_hours)
  where business_id = p_business;
end $$;

-- İşletme kurulumu (yalnızca service_role / kurulum betiği)
create or replace function public.create_business(p_name text, p_admin_user uuid, p_admin_name text)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bid uuid;
begin
  if coalesce(auth.role(), '') <> 'service_role' and current_user not in ('postgres', 'supabase_admin') then
    raise exception 'Bu işlem yalnızca kurulum sırasında yapılabilir' using errcode = '42501';
  end if;
  insert into public.businesses(name) values (trim(p_name)) returning id into v_bid;
  insert into public.locations(business_id, name, is_default) values (v_bid, 'Merkez', true);
  insert into public.app_settings(business_id) values (v_bid);
  insert into public.memberships(business_id, user_id, role, display_name)
  values (v_bid, p_admin_user, 'yonetici', trim(p_admin_name));
  return v_bid;
end $$;

-- ---------------------------------------------------------------------------
-- Yetkiler (T-004): istemci rolleri tablolara YAZAMAZ; yalnızca okur (RLS ile)
-- ve public şemadaki RPC fonksiyonlarını çağırır. Her migration sonunda çağrılır.
-- ---------------------------------------------------------------------------
create or replace function app.apply_grants() returns void
language plpgsql as $$
declare f text;
begin
  execute 'revoke all on all tables in schema public from anon, authenticated';
  execute 'grant select on all tables in schema public to authenticated';
  execute 'revoke all on all sequences in schema public from anon, authenticated';
  execute 'revoke execute on all functions in schema public from public, anon';
  execute 'grant execute on all functions in schema public to authenticated, service_role';
  execute 'revoke all on all tables in schema audit from anon, authenticated';
  execute 'grant usage on schema audit to authenticated';
  execute 'grant select on audit.log to authenticated';
  execute 'revoke execute on all functions in schema app from public, anon, authenticated';
  -- RLS politikalarında kullanılan okuma yardımcıları
  foreach f in array array['app.uid()', 'app.role_in(uuid)', 'app.is_member(uuid)',
                           'app.has_role(uuid, public.member_role[])', 'app.is_admin(uuid)',
                           'app.local_date(timestamptz)', 'app.can_see_sale(uuid)'] loop
    if to_regprocedure(f) is not null then
      execute format('grant execute on function %s to authenticated', f);
    end if;
  end loop;
end $$;

-- Supabase varsayılan ayrıcalıklarını daralt (sonradan eklenen tablolar için)
alter default privileges in schema public revoke insert, update, delete, truncate, references, trigger on tables from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon;

select app.apply_grants();

commit;
begin;

-- ===== 20260930000200_catalog.sql =====
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

commit;
begin;

-- ===== 20260930000300_stock.sql =====
-- ALKASU 0003 — Stok çekirdeği, mal kabul, fire, açılış stoğu
-- Kurallar: T-01, T-02, T-03, A-01..A-06, M-02, M-05 · Kararlar: T-007, T-008

create type public.movement_type as enum (
  'acilis', 'satis', 'satis_iptal', 'iade', 'iade_fire', 'mal_kabul', 'mal_kabul_duzeltme',
  'fire', 'sayim_duzeltme', 'bos_kap_giris', 'bos_kap_cikis', 'tedarikci_bos_iade', 'musteri_kap_kaybi'
);

create table public.stock_movements (
  id           bigint generated always as identity primary key,
  business_id  uuid not null references public.businesses(id),
  location_id  uuid not null references public.locations(id),
  product_id   uuid not null references public.products(id),
  qty          integer not null check (qty <> 0),       -- temel birim, + giriş / − çıkış
  type         public.movement_type not null,
  ref_type     text,
  ref_id       uuid,
  note         text,
  created_by   uuid,
  created_at   timestamptz not null default now()
);
create index stock_movements_product on public.stock_movements(product_id, created_at desc);
create index stock_movements_ref on public.stock_movements(ref_type, ref_id);
create index stock_movements_business_at on public.stock_movements(business_id, created_at desc);

-- T-01 / T-007: yalnızca app.post_stock yazar
create table public.stock_levels (
  business_id  uuid not null references public.businesses(id),
  location_id  uuid not null references public.locations(id),
  product_id   uuid not null references public.products(id),
  qty          integer not null default 0,
  updated_at   timestamptz not null default now(),
  primary key (location_id, product_id)
);
create index stock_levels_business on public.stock_levels(business_id);

-- Hareket tablosu değiştirilemez (G-04)
create or replace function app.tg_immutable() returns trigger
language plpgsql as $$
begin
  raise exception '% kayıtları değiştirilemez veya silinemez; ters kayıt kullanın (G-04)', tg_table_name
    using errcode = 'P0001';
end $$;
create trigger stock_movements_immutable before update or delete on public.stock_movements
  for each row execute function app.tg_immutable();

create or replace function app.post_stock(
  p_business uuid, p_location uuid, p_product uuid, p_qty integer,
  p_type public.movement_type, p_ref_type text, p_ref_id uuid, p_note text default null
) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if p_qty = 0 then return; end if;
  insert into public.stock_movements(business_id, location_id, product_id, qty, type, ref_type, ref_id, note, created_by)
  values (p_business, p_location, p_product, p_qty, p_type, p_ref_type, p_ref_id, p_note, auth.uid());
  insert into public.stock_levels(business_id, location_id, product_id, qty, updated_at)
  values (p_business, p_location, p_product, p_qty, now())
  on conflict (location_id, product_id)
  do update set qty = public.stock_levels.qty + excluded.qty, updated_at = now();
end $$;

-- Ürünün bir birimini doğrular ve çarpanını döner
create or replace function app.unit_factor(p_business uuid, p_product uuid, p_unit uuid) returns integer
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare f integer;
begin
  if p_unit is null then return 1; end if;
  select factor into f from public.product_units
   where id = p_unit and product_id = p_product and business_id = p_business;
  if f is null then raise exception 'Ürün birimi geçersiz' using errcode = '22023'; end if;
  return f;
end $$;

create or replace function app.product_in_business(p_business uuid, p_product uuid) returns public.products
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r public.products;
begin
  select * into r from public.products where id = p_product and business_id = p_business;
  if r.id is null then raise exception 'Ürün bulunamadı' using errcode = 'P0002'; end if;
  return r;
end $$;

-- ---------------------------------------------------------------------------
-- Mal kabul
-- ---------------------------------------------------------------------------
create table public.purchases (
  id           uuid primary key,                         -- istemci üretir (idempotency)
  business_id  uuid not null references public.businesses(id),
  location_id  uuid not null references public.locations(id),
  no           bigint not null,
  supplier_id  uuid references public.suppliers(id),
  doc_no       text,
  doc_date     date not null default app.local_date(now()),
  status       text not null default 'onay_bekliyor' check (status in ('onay_bekliyor', 'onaylandi')),
  note         text,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  approved_by  uuid,
  approved_at  timestamptz,
  unique (business_id, no)
);
create index purchases_business_at on public.purchases(business_id, created_at desc);

create table public.purchase_items (
  id           uuid primary key default gen_random_uuid(),
  purchase_id  uuid not null references public.purchases(id),
  business_id  uuid not null references public.businesses(id),
  product_id   uuid not null references public.products(id),
  unit_id      uuid not null references public.product_units(id),
  factor       integer not null check (factor >= 1),
  qty          integer not null check (qty >= 0),
  free_qty     integer not null default 0 check (free_qty >= 0),
  base_qty     integer generated always as (qty * factor) stored,
  free_base    integer generated always as (free_qty * factor) stored,
  constraint purchase_items_nonzero check (qty + free_qty > 0)
);
create index purchase_items_purchase on public.purchase_items(purchase_id);

-- 🔒 alış fiyatları
create table public.purchase_item_costs (
  purchase_item_id uuid primary key references public.purchase_items(id),
  business_id      uuid not null references public.businesses(id),
  unit_cost        numeric(14,4) not null check (unit_cost >= 0),  -- alış birimi başına, KDV dahil
  base_unit_cost   numeric(14,4) not null,
  line_total       numeric(14,2) not null
);

create table public.purchase_empties (
  id           uuid primary key default gen_random_uuid(),
  purchase_id  uuid not null references public.purchases(id),
  business_id  uuid not null references public.businesses(id),
  product_id   uuid not null references public.products(id),   -- boş kap ürünü
  qty          integer not null check (qty > 0)
);

create table public.waste_records (
  id           uuid primary key,
  business_id  uuid not null references public.businesses(id),
  location_id  uuid not null references public.locations(id),
  product_id   uuid not null references public.products(id),
  unit_id      uuid references public.product_units(id),
  qty          integer not null check (qty > 0),        -- girilen birimde
  base_qty     integer not null check (base_qty > 0),
  reason       text not null check (reason in ('kirik', 'sizinti', 'skt', 'kayip', 'iade_kusurlu', 'diger')),
  note         text,
  created_by   uuid,
  created_at   timestamptz not null default now()
);
create index waste_records_business_at on public.waste_records(business_id, created_at desc);

alter table public.stock_movements     enable row level security;
alter table public.stock_levels        enable row level security;
alter table public.purchases           enable row level security;
alter table public.purchase_items      enable row level security;
alter table public.purchase_item_costs enable row level security;
alter table public.purchase_empties    enable row level security;
alter table public.waste_records       enable row level security;

create policy stock_mov_select on public.stock_movements for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'depo'));
create policy stock_lvl_select on public.stock_levels for select to authenticated
  using (app.is_member(business_id));
create policy purchases_select on public.purchases for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'depo'));
create policy purchase_items_select on public.purchase_items for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'depo'));
create policy purchase_costs_select on public.purchase_item_costs for select to authenticated
  using (app.is_admin(business_id));
create policy purchase_empties_select on public.purchase_empties for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'depo'));
create policy waste_select on public.waste_records for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'depo'));

-- Onay: M-02 ağırlıklı ortalama
create or replace function app.approve_purchase(p_purchase uuid, p_costs jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  pu   public.purchases;
  it   record;
  c    numeric;
  pr   record;
  v_level integer; v_prior integer; v_old numeric; v_new numeric;
begin
  select * into pu from public.purchases where id = p_purchase for update;
  if pu.status <> 'onay_bekliyor' then
    raise exception 'Bu mal kabul zaten onaylanmış (A-04)' using errcode = 'P0001';
  end if;

  for it in select * from public.purchase_items where purchase_id = p_purchase loop
    select (e->>'unit_cost')::numeric into c
      from jsonb_array_elements(p_costs) e where (e->>'item_id')::uuid = it.id;
    if c is null or c < 0 then
      raise exception 'Tüm kalemler için alış fiyatı girilmelidir' using errcode = '22023';
    end if;
    insert into public.purchase_item_costs(purchase_item_id, business_id, unit_cost, base_unit_cost, line_total)
    values (it.id, pu.business_id, c, round(c / it.factor, 4), round(c * it.qty, 2));
  end loop;

  -- Ürün bazında ortalama maliyet (ürünler sıralı kilitlenir: T-008)
  for pr in
    select i.product_id,
           sum(i.base_qty)::int as recv, sum(i.free_base)::int as free,
           sum(i.base_qty * pc.base_unit_cost) as total_cost
      from public.purchase_items i join public.purchase_item_costs pc on pc.purchase_item_id = i.id
     where i.purchase_id = p_purchase
     group by i.product_id order by i.product_id
  loop
    perform 1 from public.products where id = pr.product_id for update;
    select coalesce(qty, 0) into v_level from public.stock_levels
     where location_id = pu.location_id and product_id = pr.product_id;
    v_prior := coalesce(v_level, 0) - pr.recv - pr.free;        -- mal kabul stoğa zaten girdi (A-02)
    select avg_cost into v_old from public.product_costs where product_id = pr.product_id;
    if v_prior > 0 then
      v_new := (v_prior * coalesce(v_old, 0) + pr.total_cost) / (v_prior + pr.recv + pr.free);
    else
      v_new := pr.total_cost / (pr.recv + pr.free);
    end if;
    perform app.set_avg_cost(pr.product_id, v_new, 'mal_kabul', p_purchase);
  end loop;

  update public.purchases set status = 'onaylandi', approved_by = auth.uid(), approved_at = now()
   where id = p_purchase;
  perform app.audit(pu.business_id, 'mal_kabul_onay', 'purchases', p_purchase::text, null, p_costs);
end $$;

-- RPC: mal kabul
-- p = { id, supplier_id?, doc_no?, doc_date?, note?, items:[{product_id, unit_id, qty, free_qty?, unit_cost?}],
--       empties:[{product_id, qty}] }   unit_cost yalnızca yönetici için; tüm kalemlerde varsa anında onaylanır.
create or replace function public.receive_goods(p_business uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role public.member_role := app.require_role(p_business, 'yonetici', 'depo');
  v_id   uuid := (p->>'id')::uuid;
  v_loc  uuid := coalesce(nullif(p->>'location_id', '')::uuid, app.default_location(p_business));
  v_no   bigint;
  it     jsonb;
  pr     public.products;
  f      integer;
  v_item uuid;
  v_costs jsonb := '[]'::jsonb;
  v_all_costed boolean := true;
  e      jsonb;
begin
  if v_id is null then raise exception 'Kayıt kimliği eksik' using errcode = '22023'; end if;
  if exists (select 1 from public.purchases where id = v_id) then
    return (select jsonb_build_object('id', id, 'no', no, 'status', status, 'duplicate', true)
              from public.purchases where id = v_id and business_id = p_business);
  end if;
  if jsonb_array_length(coalesce(p->'items', '[]')) = 0 and jsonb_array_length(coalesce(p->'empties', '[]')) = 0 then
    raise exception 'En az bir kalem girilmelidir' using errcode = '22023';
  end if;
  if nullif(p->>'supplier_id', '') is not null and not exists (
      select 1 from public.suppliers where id = (p->>'supplier_id')::uuid and business_id = p_business) then
    raise exception 'Tedarikçi bulunamadı' using errcode = 'P0002';
  end if;

  v_no := app.next_number(p_business, 'mal_kabul');
  insert into public.purchases(id, business_id, location_id, no, supplier_id, doc_no, doc_date, note, created_by)
  values (v_id, p_business, v_loc, v_no, nullif(p->>'supplier_id', '')::uuid, nullif(trim(p->>'doc_no'), ''),
          coalesce(nullif(p->>'doc_date', '')::date, app.local_date(now())), nullif(trim(p->>'note'), ''), auth.uid());

  for it in select * from jsonb_array_elements(coalesce(p->'items', '[]')) order by value->>'product_id' loop
    pr := app.product_in_business(p_business, (it->>'product_id')::uuid);
    f  := app.unit_factor(p_business, pr.id, (it->>'unit_id')::uuid);
    if coalesce((it->>'qty')::int, 0) < 0 or coalesce((it->>'free_qty')::int, 0) < 0
       or coalesce((it->>'qty')::int, 0) + coalesce((it->>'free_qty')::int, 0) = 0 then
      raise exception 'Miktar geçersiz: %', pr.name using errcode = '22023';
    end if;
    insert into public.purchase_items(purchase_id, business_id, product_id, unit_id, factor, qty, free_qty)
    values (v_id, p_business, pr.id, (it->>'unit_id')::uuid, f, coalesce((it->>'qty')::int, 0), coalesce((it->>'free_qty')::int, 0))
    returning id into v_item;
    perform app.post_stock(p_business, v_loc, pr.id,
                           (coalesce((it->>'qty')::int, 0) + coalesce((it->>'free_qty')::int, 0)) * f,
                           'mal_kabul', 'purchase', v_id);
    if nullif(it->>'unit_cost', '') is null then
      v_all_costed := false;
    else
      v_costs := v_costs || jsonb_build_object('item_id', v_item, 'unit_cost', (it->>'unit_cost')::numeric);
    end if;
  end loop;

  -- A-06: tedarikçiye verilen boş kaplar
  for e in select * from jsonb_array_elements(coalesce(p->'empties', '[]')) loop
    pr := app.product_in_business(p_business, (e->>'product_id')::uuid);
    if not pr.is_container then raise exception 'Yalnızca boş kap ürünleri iade edilebilir' using errcode = '22023'; end if;
    if coalesce((e->>'qty')::int, 0) <= 0 then raise exception 'Boş kap miktarı geçersiz' using errcode = '22023'; end if;
    insert into public.purchase_empties(purchase_id, business_id, product_id, qty)
    values (v_id, p_business, pr.id, (e->>'qty')::int);
    perform app.post_stock(p_business, v_loc, pr.id, -(e->>'qty')::int, 'tedarikci_bos_iade', 'purchase', v_id);
  end loop;

  perform app.audit(p_business, 'mal_kabul', 'purchases', v_id::text, null, p);

  if not exists (select 1 from public.purchase_items where purchase_id = v_id) then
    update public.purchases set status = 'onaylandi', approved_by = auth.uid(), approved_at = now() where id = v_id;
  elsif v_role = 'yonetici' and v_all_costed then
    perform app.approve_purchase(v_id, v_costs);
  end if;

  return (select jsonb_build_object('id', id, 'no', no, 'status', status, 'duplicate', false)
            from public.purchases where id = v_id);
end $$;

-- RPC: alış fiyatı onayı (yönetici)  p_costs = [{item_id, unit_cost}]
create or replace function public.approve_purchase(p_purchase uuid, p_costs jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bid uuid;
begin
  select business_id into v_bid from public.purchases where id = p_purchase;
  if v_bid is null then raise exception 'Mal kabul bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(v_bid, 'yonetici');
  perform app.approve_purchase(p_purchase, p_costs);
end $$;

-- RPC: fire / hasar  p = { id, product_id, unit_id?, qty, reason, note? }
create or replace function public.record_waste(p_business uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id  uuid := (p->>'id')::uuid;
  v_loc uuid := coalesce(nullif(p->>'location_id', '')::uuid, app.default_location(p_business));
  pr    public.products;
  f     integer;
begin
  perform app.require_role(p_business, 'yonetici', 'depo');
  if v_id is null then raise exception 'Kayıt kimliği eksik' using errcode = '22023'; end if;
  if exists (select 1 from public.waste_records where id = v_id) then return v_id; end if;
  pr := app.product_in_business(p_business, (p->>'product_id')::uuid);
  f  := app.unit_factor(p_business, pr.id, nullif(p->>'unit_id', '')::uuid);
  if coalesce((p->>'qty')::int, 0) <= 0 then raise exception 'Miktar sıfırdan büyük olmalıdır' using errcode = '22023'; end if;
  if (p->>'reason') = 'iade_kusurlu' then
    raise exception 'Bu neden yalnızca iade işleminde kullanılır' using errcode = '22023';
  end if;
  insert into public.waste_records(id, business_id, location_id, product_id, unit_id, qty, base_qty, reason, note, created_by)
  values (v_id, p_business, v_loc, pr.id, nullif(p->>'unit_id', '')::uuid, (p->>'qty')::int, (p->>'qty')::int * f,
          p->>'reason', nullif(trim(p->>'note'), ''), auth.uid());
  perform app.post_stock(p_business, v_loc, pr.id, -((p->>'qty')::int * f), 'fire', 'waste', v_id, p->>'reason');
  perform app.audit(p_business, 'fire', 'waste_records', v_id::text, null, p);
  return v_id;
end $$;

-- RPC: stok tutarlılık kontrolü (T-007) — seviye ile hareket toplamı farklı olan ürünler
create or replace function public.stock_consistency_check(p_business uuid)
returns table(product_id uuid, level_qty integer, movement_qty bigint)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform app.require_role(p_business, 'yonetici');
  return query
  select coalesce(l.product_id, m.product_id), l.qty, m.total
    from (select sl.product_id, sl.location_id, sl.qty from public.stock_levels sl where sl.business_id = p_business) l
    full join (select sm.product_id, sm.location_id, sum(sm.qty) as total from public.stock_movements sm
                where sm.business_id = p_business group by sm.product_id, sm.location_id) m
      on m.product_id = l.product_id and m.location_id = l.location_id
   where coalesce(l.qty, 0) <> coalesce(m.total, 0);
end $$;

select app.apply_grants();

commit;
begin;

-- ===== 20260930000400_sales.sql =====
-- ALKASU 0004 — Müşteri, veresiye, kasa oturumu, satış, depozito, iptal, iade, tahsilat
-- Kurallar: S-01..S-08, F-04..F-07, M-04, D-03..D-08, V-01..V-05, I-01..I-07, K-02, K-07, K-08, C-02, C-03

-- ---------------------------------------------------------------------------
-- Müşteriler
-- ---------------------------------------------------------------------------
create table public.customers (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid not null references public.businesses(id),
  code             text not null,
  name             text not null check (length(trim(name)) > 0),
  phone            text,
  address          text,
  tax_no           text,
  credit_limit     numeric(14,2) not null default 0 check (credit_limit >= 0),
  unlimited_credit boolean not null default false,
  note             text,
  active           boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create unique index customers_code on public.customers(business_id, lower(code));
create index customers_name on public.customers(business_id, lower(name));
create trigger customers_touch before update on public.customers for each row execute function app.touch_updated_at();
create trigger customers_audit after insert or update on public.customers for each row execute function audit.tg_row();

-- Veresiye cari hareketleri: amount > 0 müşterinin borcu artar
create table public.customer_ledger (
  id           bigint generated always as identity primary key,
  business_id  uuid not null references public.businesses(id),
  customer_id  uuid not null references public.customers(id),
  type         text not null check (type in ('acilis','satis','tahsilat','tahsilat_iptal','iade','iptal','depozito_mahsup')),
  amount       numeric(14,2) not null check (amount <> 0),
  ref_type     text,
  ref_id       uuid,
  note         text,
  created_by   uuid,
  created_at   timestamptz not null default now()
);
create index customer_ledger_customer on public.customer_ledger(customer_id, created_at);
create trigger customer_ledger_immutable before update or delete on public.customer_ledger
  for each row execute function app.tg_immutable();

-- Müşterideki kaplar ve ödenmiş depozito. customer_id null = kayıtsız (perakende) müşteri havuzu (D-06)
create table public.container_ledger (
  id           bigint generated always as identity primary key,
  business_id  uuid not null references public.businesses(id),
  customer_id  uuid references public.customers(id),
  product_id   uuid not null references public.products(id),   -- depozitolu (dolu) ürün
  qty          integer not null check (qty <> 0),               -- + müşterideki kap artar
  amount       numeric(14,2) not null default 0,                -- + müşteriden alınan depozito
  type         text not null check (type in ('acilis','satis','iade','iptal','kayip')),
  ref_type     text,
  ref_id       uuid,
  created_by   uuid,
  created_at   timestamptz not null default now()
);
create index container_ledger_customer on public.container_ledger(business_id, customer_id, product_id);
create trigger container_ledger_immutable before update or delete on public.container_ledger
  for each row execute function app.tg_immutable();

-- ---------------------------------------------------------------------------
-- Kasa oturumu (gün) ve kasa hareketleri
-- ---------------------------------------------------------------------------
create table public.cash_sessions (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references public.businesses(id),
  location_id   uuid not null references public.locations(id),
  no            bigint not null,
  status        text not null default 'acik' check (status in ('acik', 'kapali')),
  opened_at     timestamptz not null default now(),
  opened_by     uuid,
  opening_cash  numeric(14,2) not null default 0,
  closed_at     timestamptz,
  closed_by     uuid,
  expected_cash numeric(14,2),
  counted_cash  numeric(14,2),
  cash_diff     numeric(14,2),
  diff_note     text,
  pos_expected  numeric(14,2),
  pos_slip      numeric(14,2),
  pos_diff      numeric(14,2),
  carry_over    numeric(14,2),
  unique (business_id, no)
);
create unique index cash_sessions_one_open on public.cash_sessions(location_id) where status = 'acik';

create table public.cash_movements (
  id           bigint generated always as identity primary key,
  business_id  uuid not null references public.businesses(id),
  session_id   uuid not null references public.cash_sessions(id),
  type         text not null check (type in ('satis','satis_iptal','iade','tahsilat','tahsilat_iptal',
                                             'depozito_iade','gider','giris','cikis','gun_sonu_teslim','duzeltme')),
  amount       numeric(14,2) not null check (amount <> 0),   -- + kasaya giren
  ref_type     text,
  ref_id       uuid,
  note         text,
  created_by   uuid,
  created_at   timestamptz not null default now()
);
create index cash_movements_session on public.cash_movements(session_id);
create trigger cash_movements_immutable before update or delete on public.cash_movements
  for each row execute function app.tg_immutable();

-- K-06: kapalı oturum değiştirilemez
create or replace function app.tg_session_closed_lock() returns trigger
language plpgsql as $$
begin
  if old.status = 'kapali' then
    raise exception 'Kapanmış kasa günü değiştirilemez (K-06)' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger cash_sessions_lock before update on public.cash_sessions
  for each row execute function app.tg_session_closed_lock();

create or replace function app.tg_cash_mov_session_open() returns trigger
language plpgsql as $$
begin
  if (select status from public.cash_sessions where id = new.session_id) <> 'acik' then
    raise exception 'Kapanmış kasa gününe hareket yazılamaz (K-06)' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger cash_movements_open before insert on public.cash_movements
  for each row execute function app.tg_cash_mov_session_open();

-- K-02: açık kasa gününü getir, yoksa aç (tek seferde: advisory lock, T-008)
create or replace function app.ensure_session(p_business uuid, p_location uuid) returns public.cash_sessions
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.cash_sessions; v_open numeric;
begin
  perform pg_advisory_xact_lock(hashtext('cash_session:' || p_location::text));
  select * into s from public.cash_sessions where location_id = p_location and status = 'acik';
  if s.id is not null then return s; end if;
  select carry_over into v_open from public.cash_sessions
   where location_id = p_location and status = 'kapali' order by closed_at desc limit 1;
  insert into public.cash_sessions(business_id, location_id, no, opening_cash, opened_by)
  values (p_business, p_location, app.next_number(p_business, 'kasa'), coalesce(v_open, 0), auth.uid())
  returning * into s;
  return s;
end $$;

create or replace function app.post_cash(p_business uuid, p_session uuid, p_type text, p_amount numeric,
                                         p_ref_type text, p_ref uuid, p_note text default null) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into public.cash_movements(business_id, session_id, type, amount, ref_type, ref_id, note, created_by)
  select p_business, p_session, p_type, p_amount, p_ref_type, p_ref, p_note, auth.uid()
  where p_amount <> 0;
$$;

create or replace function app.customer_balance(p_customer uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(amount), 0) from public.customer_ledger where customer_id = p_customer
$$;

-- Kap bakiyesi (qty, amount); p_customer null = perakende havuzu
create or replace function app.container_balance(p_business uuid, p_customer uuid, p_product uuid,
                                                 out qty integer, out amount numeric)
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(c.qty), 0)::int, coalesce(sum(c.amount), 0)
    from public.container_ledger c
   where c.business_id = p_business and c.product_id = p_product
     and c.customer_id is not distinct from p_customer
$$;

-- Kap iadesinde geri verilecek depozito: ödenen ortalama üzerinden
create or replace function app.deposit_refund_amount(p_business uuid, p_customer uuid, p_product uuid, p_qty integer)
returns numeric
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare b record;
begin
  select * into b from app.container_balance(p_business, p_customer, p_product);
  if b.qty < p_qty then
    raise exception 'Müşterinin elinde bu kadar kap görünmüyor (elinde: %, iade: %)', b.qty, p_qty using errcode = 'P0001';
  end if;
  if b.qty = p_qty then return b.amount; end if;
  return round(b.amount * p_qty / b.qty, 2);
end $$;

-- ---------------------------------------------------------------------------
-- Satış
-- ---------------------------------------------------------------------------
create table public.sales (
  id                uuid primary key,                     -- istemci üretir (S-02)
  business_id       uuid not null references public.businesses(id),
  location_id       uuid not null references public.locations(id),
  no                bigint not null,
  session_id        uuid not null references public.cash_sessions(id),
  customer_id       uuid references public.customers(id),
  status            text not null default 'tamamlandi' check (status in ('tamamlandi', 'iptal')),
  goods_gross       numeric(14,2) not null,
  discount_total    numeric(14,2) not null default 0,
  goods_net         numeric(14,2) not null,
  deposit_total     numeric(14,2) not null default 0,
  grand_total       numeric(14,2) not null,
  cash_given        numeric(14,2),
  change_given      numeric(14,2),
  sold_at           timestamptz not null,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  offline           boolean not null default false,
  late_sync         boolean not null default false,
  limit_override    boolean not null default false,
  offline_limit_exceeded boolean not null default false,
  note              text,
  cancelled_at      timestamptz,
  cancelled_by      uuid,
  cancel_reason     text,
  unique (business_id, no)
);
create index sales_business_sold on public.sales(business_id, sold_at desc);
create index sales_session on public.sales(session_id);
create index sales_customer on public.sales(customer_id);
create index sales_created_by on public.sales(created_by, sold_at desc);

create table public.sale_items (
  id                  uuid primary key default gen_random_uuid(),
  sale_id             uuid not null references public.sales(id),
  business_id         uuid not null references public.businesses(id),
  line_no             smallint not null,
  product_id          uuid not null references public.products(id),
  unit_id             uuid not null references public.product_units(id),
  unit_name           text not null,
  factor              integer not null,
  qty                 integer not null check (qty > 0),
  base_qty            integer not null check (base_qty > 0),
  unit_price          numeric(14,2) not null check (unit_price >= 0),
  line_gross          numeric(14,2) not null,
  line_discount       numeric(14,2) not null default 0,
  bill_discount_share numeric(14,2) not null default 0,
  line_net            numeric(14,2) not null,
  vat_rate            smallint not null
);
create index sale_items_sale on public.sale_items(sale_id);
create index sale_items_product on public.sale_items(product_id);

-- 🔒 satış anındaki maliyet (F-04, M-04)
create table public.sale_item_costs (
  sale_item_id uuid primary key references public.sale_items(id),
  business_id  uuid not null references public.businesses(id),
  unit_cost    numeric(14,4) not null,   -- temel birim başına
  total_cost   numeric(14,2) not null,
  has_cost     boolean not null
);

create table public.sale_deposits (
  id              uuid primary key default gen_random_uuid(),
  sale_id         uuid not null references public.sales(id),
  business_id     uuid not null references public.businesses(id),
  product_id      uuid not null references public.products(id),
  sold_qty        integer not null,     -- temel birimde satılan dolu
  empty_returned  integer not null check (empty_returned >= 0),
  net_containers  integer not null,     -- + müşteride kalan
  amount          numeric(14,2) not null  -- + alınan, − iade edilen depozito
);
create index sale_deposits_sale on public.sale_deposits(sale_id);

create table public.sale_payments (
  id           uuid primary key default gen_random_uuid(),
  sale_id      uuid not null references public.sales(id),
  business_id  uuid not null references public.businesses(id),
  method       text not null check (method in ('nakit', 'pos', 'veresiye')),
  amount       numeric(14,2) not null check (amount > 0)
);
create index sale_payments_sale on public.sale_payments(sale_id);

-- ---------------------------------------------------------------------------
-- İade
-- ---------------------------------------------------------------------------
create table public.returns (
  id            uuid primary key,
  business_id   uuid not null references public.businesses(id),
  location_id   uuid not null references public.locations(id),
  no            bigint not null,
  sale_id       uuid not null references public.sales(id),
  session_id    uuid not null references public.cash_sessions(id),
  reason        text not null,
  total_refund  numeric(14,2) not null,
  created_by    uuid,
  created_at    timestamptz not null default now(),
  unique (business_id, no)
);
create index returns_sale on public.returns(sale_id);

create table public.return_items (
  id             uuid primary key default gen_random_uuid(),
  return_id      uuid not null references public.returns(id),
  business_id    uuid not null references public.businesses(id),
  sale_item_id   uuid not null references public.sale_items(id),
  product_id     uuid not null references public.products(id),
  qty            integer not null check (qty > 0),     -- satış biriminde
  base_qty       integer not null check (base_qty > 0),
  condition      text not null check (condition in ('saglam', 'kusurlu')),
  refund_amount  numeric(14,2) not null
);
create index return_items_sale_item on public.return_items(sale_item_id);

create table public.return_item_costs (
  return_item_id uuid primary key references public.return_items(id),
  business_id    uuid not null references public.businesses(id),
  unit_cost      numeric(14,4) not null,
  total_cost     numeric(14,2) not null
);

create table public.return_payments (
  id           uuid primary key default gen_random_uuid(),
  return_id    uuid not null references public.returns(id),
  business_id  uuid not null references public.businesses(id),
  method       text not null check (method in ('nakit', 'pos', 'veresiye')),
  amount       numeric(14,2) not null check (amount > 0)
);

create table public.return_requests (
  id            uuid primary key,
  business_id   uuid not null references public.businesses(id),
  sale_id       uuid not null references public.sales(id),
  items         jsonb not null,
  reason        text not null,
  status        text not null default 'bekliyor' check (status in ('bekliyor', 'onaylandi', 'reddedildi')),
  requested_by  uuid,
  requested_at  timestamptz not null default now(),
  decided_by    uuid,
  decided_at    timestamptz,
  decision_note text,
  return_id     uuid references public.returns(id)
);
create index return_requests_open on public.return_requests(business_id) where status = 'bekliyor';

-- ---------------------------------------------------------------------------
-- Tahsilat ve depozito iadesi
-- ---------------------------------------------------------------------------
create table public.customer_payments (
  id            uuid primary key,
  business_id   uuid not null references public.businesses(id),
  customer_id   uuid not null references public.customers(id),
  session_id    uuid not null references public.cash_sessions(id),
  method        text not null check (method in ('nakit', 'pos')),
  amount        numeric(14,2) not null check (amount > 0),
  note          text,
  status        text not null default 'gecerli' check (status in ('gecerli', 'iptal')),
  created_by    uuid,
  created_at    timestamptz not null default now(),
  cancelled_by  uuid,
  cancelled_at  timestamptz,
  cancel_reason text,
  cancel_session_id uuid references public.cash_sessions(id)
);
create index customer_payments_customer on public.customer_payments(customer_id, created_at desc);

create table public.container_returns (
  id             uuid primary key,
  business_id    uuid not null references public.businesses(id),
  location_id    uuid not null references public.locations(id),
  session_id     uuid references public.cash_sessions(id),
  customer_id    uuid references public.customers(id),
  product_id     uuid not null references public.products(id),
  qty            integer not null check (qty > 0),
  kind           text not null check (kind in ('iade', 'kayip')),
  refund_method  text check (refund_method in ('nakit', 'veresiye')),
  amount         numeric(14,2) not null,
  note           text,
  created_by     uuid,
  created_at     timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Görünümler (RLS'e tabi: security_invoker)
-- ---------------------------------------------------------------------------
create view public.customer_balances with (security_invoker = true) as
  select c.id as customer_id, c.business_id, coalesce(sum(l.amount), 0)::numeric(14,2) as balance
    from public.customers c left join public.customer_ledger l on l.customer_id = c.id
   group by c.id, c.business_id;

create view public.container_balances with (security_invoker = true) as
  select business_id, customer_id, product_id, sum(qty)::int as qty, sum(amount)::numeric(14,2) as amount
    from public.container_ledger group by business_id, customer_id, product_id
  having sum(qty) <> 0 or sum(amount) <> 0;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.customers         enable row level security;
alter table public.customer_ledger   enable row level security;
alter table public.container_ledger  enable row level security;
alter table public.cash_sessions     enable row level security;
alter table public.cash_movements    enable row level security;
alter table public.sales             enable row level security;
alter table public.sale_items        enable row level security;
alter table public.sale_item_costs   enable row level security;
alter table public.sale_deposits     enable row level security;
alter table public.sale_payments     enable row level security;
alter table public.returns           enable row level security;
alter table public.return_items      enable row level security;
alter table public.return_item_costs enable row level security;
alter table public.return_payments   enable row level security;
alter table public.return_requests   enable row level security;
alter table public.customer_payments enable row level security;
alter table public.container_returns enable row level security;

create policy customers_select on public.customers for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis'));
create policy customer_ledger_select on public.customer_ledger for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis'));
create policy container_ledger_select on public.container_ledger for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis'));
create policy cash_sessions_select on public.cash_sessions for select to authenticated
  using (app.is_admin(business_id));
create policy cash_movements_select on public.cash_movements for select to authenticated
  using (app.is_admin(business_id));

-- S-08: satış personeli yalnızca kendi satışlarını görür
create or replace function app.can_see_sale(p_sale uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.sales s where s.id = p_sale
      and (app.is_admin(s.business_id) or (app.has_role(s.business_id, 'satis') and s.created_by = auth.uid()))
  )
$$;

create policy sales_select on public.sales for select to authenticated
  using (app.is_admin(business_id) or (app.has_role(business_id, 'satis') and created_by = auth.uid()));
create policy sale_items_select on public.sale_items for select to authenticated using (app.can_see_sale(sale_id));
create policy sale_deposits_select on public.sale_deposits for select to authenticated using (app.can_see_sale(sale_id));
create policy sale_payments_select on public.sale_payments for select to authenticated using (app.can_see_sale(sale_id));
create policy sale_item_costs_select on public.sale_item_costs for select to authenticated using (app.is_admin(business_id));
create policy returns_select on public.returns for select to authenticated using (app.can_see_sale(sale_id));
create policy return_items_select on public.return_items for select to authenticated
  using (app.can_see_sale((select r.sale_id from public.returns r where r.id = return_id)));
create policy return_payments_select on public.return_payments for select to authenticated
  using (app.can_see_sale((select r.sale_id from public.returns r where r.id = return_id)));
create policy return_item_costs_select on public.return_item_costs for select to authenticated using (app.is_admin(business_id));
create policy return_requests_select on public.return_requests for select to authenticated
  using (app.is_admin(business_id) or requested_by = auth.uid());
create policy customer_payments_select on public.customer_payments for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis'));
create policy container_returns_select on public.container_returns for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis'));

-- ---------------------------------------------------------------------------
-- RPC: müşteri kartı. Kredi limitini yalnızca yönetici belirler.
-- p = { id?, code?, name, phone?, address?, tax_no?, note?, credit_limit?, unlimited_credit?, active? }
-- ---------------------------------------------------------------------------
create or replace function public.upsert_customer(p_business uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role public.member_role := app.require_role(p_business, 'yonetici', 'satis');
  v_id   uuid := nullif(p->>'id', '')::uuid;
  v_code text := nullif(trim(p->>'code'), '');
  v_old  public.customers;
begin
  if coalesce(trim(p->>'name'), '') = '' then raise exception 'Müşteri adı zorunludur' using errcode = '22023'; end if;
  if v_id is null then
    if v_code is null then v_code := 'M' || lpad(app.next_number(p_business, 'musteri')::text, 5, '0'); end if;
    if exists (select 1 from public.customers where business_id = p_business and lower(code) = lower(v_code)) then
      raise exception 'Bu müşteri kodu zaten kullanılıyor: %', v_code using errcode = '23505';
    end if;
    insert into public.customers(business_id, code, name, phone, address, tax_no, note, credit_limit, unlimited_credit)
    values (p_business, v_code, trim(p->>'name'), nullif(trim(p->>'phone'), ''), nullif(trim(p->>'address'), ''),
            nullif(trim(p->>'tax_no'), ''), nullif(trim(p->>'note'), ''),
            case when v_role = 'yonetici' then coalesce(nullif(p->>'credit_limit', '')::numeric, 0) else 0 end,
            case when v_role = 'yonetici' then coalesce((p->>'unlimited_credit')::boolean, false) else false end)
    returning id into v_id;
  else
    select * into v_old from public.customers where id = v_id and business_id = p_business for update;
    if v_old.id is null then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
    if v_code is not null and exists (select 1 from public.customers where business_id = p_business
                                      and lower(code) = lower(v_code) and id <> v_id) then
      raise exception 'Bu müşteri kodu zaten kullanılıyor: %', v_code using errcode = '23505';
    end if;
    update public.customers set
      code = coalesce(v_code, code), name = trim(p->>'name'),
      phone = nullif(trim(p->>'phone'), ''), address = nullif(trim(p->>'address'), ''),
      tax_no = nullif(trim(p->>'tax_no'), ''), note = nullif(trim(p->>'note'), ''),
      credit_limit = case when v_role = 'yonetici' then coalesce(nullif(p->>'credit_limit', '')::numeric, credit_limit) else credit_limit end,
      unlimited_credit = case when v_role = 'yonetici' then coalesce((p->>'unlimited_credit')::boolean, unlimited_credit) else unlimited_credit end,
      active = case when v_role = 'yonetici' then coalesce((p->>'active')::boolean, active) else active end
    where id = v_id;
  end if;
  return v_id;
end $$;

-- Satış ekranı için müşteri özeti (Y-03)
create or replace function public.customer_summary(p_customer uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare c public.customers;
begin
  select * into c from public.customers where id = p_customer;
  if c.id is null then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(c.business_id, 'yonetici', 'satis');
  return jsonb_build_object(
    'id', c.id, 'code', c.code, 'name', c.name, 'phone', c.phone, 'address', c.address,
    'credit_limit', c.credit_limit, 'unlimited_credit', c.unlimited_credit,
    'balance', app.customer_balance(c.id),
    'containers', coalesce((select jsonb_agg(jsonb_build_object('product_id', b.product_id, 'product_name', pr.name,
                                                                'qty', b.qty, 'amount', b.amount))
                              from public.container_balances b join public.products pr on pr.id = b.product_id
                             where b.customer_id = c.id), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- RPC: satışı tamamla (S-01: tek işlem, S-02: idempotent)
-- p = {
--   id: uuid, customer_id?, client_created_at?, offline?: bool, note?,
--   items: [{ product_id, unit_id, qty, unit_price, line_discount? }],
--   bill_discount?: number,
--   deposits?: [{ product_id, empty_returned }],   -- depozitolu ürünlerde getirilen boş (varsayılan: satılan adet)
--   payments: [{ method: nakit|pos|veresiye, amount }],
--   cash_given?: number, limit_override?: bool
-- }
-- ---------------------------------------------------------------------------
create or replace function public.complete_sale(p_business uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role    public.member_role := app.require_role(p_business, 'yonetici', 'satis');
  v_id      uuid := (p->>'id')::uuid;
  v_loc     uuid := coalesce(nullif(p->>'location_id', '')::uuid, app.default_location(p_business));
  v_set     public.app_settings;
  v_sess    public.cash_sessions;
  v_cust    public.customers;
  v_offline boolean := coalesce((p->>'offline')::boolean, false);
  v_client  timestamptz := coalesce(nullif(p->>'client_created_at', '')::timestamptz, now());
  v_sold_at timestamptz;
  v_no      bigint;
  it        jsonb;
  pr        public.products;
  u         public.product_units;
  v_line    int := 0;
  v_qty     int;
  v_price   numeric;
  v_ldisc   numeric;
  v_gross   numeric := 0;
  v_ldisc_total numeric := 0;
  v_bill    numeric := coalesce(nullif(p->>'bill_discount', '')::numeric, 0);
  v_net_before_bill numeric;
  v_share   numeric;
  v_share_left numeric;
  v_goods_net numeric := 0;
  v_dep_total numeric := 0;
  v_grand   numeric;
  v_pay_total numeric := 0;
  v_cash    numeric := 0; v_pos numeric := 0; v_credit numeric := 0;
  v_given   numeric := nullif(p->>'cash_given', '')::numeric;
  v_balance numeric;
  v_limit_override boolean := false;
  v_offline_limit boolean := false;
  d         record;
  v_ret     int;
  v_cb      record;
  v_amt     numeric;
  rec       record;
  v_item_id uuid;
begin
  if v_id is null then raise exception 'Satış kimliği eksik' using errcode = '22023'; end if;

  -- S-02: aynı kimlikle tekrar gönderim
  if exists (select 1 from public.sales where id = v_id) then
    return (select jsonb_build_object('id', s.id, 'no', s.no, 'grand_total', s.grand_total,
                                      'change', s.change_given, 'duplicate', true)
              from public.sales s where s.id = v_id and s.business_id = p_business);
  end if;

  select * into v_set from public.app_settings where business_id = p_business;
  if jsonb_array_length(coalesce(p->'items', '[]')) = 0 then
    raise exception 'Sepet boş' using errcode = '22023';
  end if;
  if v_bill < 0 then raise exception 'İndirim negatif olamaz' using errcode = '22023'; end if;

  if nullif(p->>'customer_id', '') is not null then
    select * into v_cust from public.customers where id = (p->>'customer_id')::uuid and business_id = p_business;
    if v_cust.id is null then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
    if not v_cust.active then raise exception 'Müşteri pasif durumda' using errcode = 'P0001'; end if;
  end if;

  v_sess := app.ensure_session(p_business, v_loc);
  v_sold_at := case when v_offline then least(v_client, now()) else now() end;
  v_no := app.next_number(p_business, 'satis');

  if to_regclass('pg_temp._sale_lines') is null then
  create temp table _sale_lines (
    line_no int, product_id uuid, unit_id uuid, unit_name text, factor int, qty int, base_qty int,
    unit_price numeric, line_gross numeric, line_discount numeric, share numeric default 0,
    line_net numeric, vat_rate smallint, deposit_amount numeric, empty_product_id uuid
  ) on commit drop;
  end if;
  truncate _sale_lines;

  -- 1) Kalemleri doğrula
  for it in select * from jsonb_array_elements(p->'items') loop
    v_line := v_line + 1;
    pr := app.product_in_business(p_business, (it->>'product_id')::uuid);
    if not pr.active then raise exception 'Pasif ürün satılamaz: % (S-06)', pr.name using errcode = 'P0001'; end if;
    if pr.is_container then raise exception 'Boş kap ürünü satılamaz: %', pr.name using errcode = 'P0001'; end if;
    select * into u from public.product_units where id = (it->>'unit_id')::uuid and product_id = pr.id;
    if u.id is null then raise exception 'Ürün birimi geçersiz: %', pr.name using errcode = '22023'; end if;
    if not u.active and not v_offline then raise exception 'Bu birim artık kullanılmıyor: % %', pr.name, u.name using errcode = 'P0001'; end if;

    v_qty   := (it->>'qty')::int;
    v_price := round((it->>'unit_price')::numeric, 2);
    v_ldisc := round(coalesce(nullif(it->>'line_discount', '')::numeric, 0), 2);
    if v_qty is null or v_qty <= 0 then raise exception 'Miktar geçersiz: %', pr.name using errcode = '22023'; end if;
    if v_price is null or v_price < 0 then raise exception 'Fiyat geçersiz: %', pr.name using errcode = '22023'; end if;

    if v_role <> 'yonetici' then
      -- Satış personeli fiyatı değiştiremez; çevrimdışında satış anındaki fiyat da kabul edilir (C-02)
      if u.price is null and app.unit_price_at(u.id, v_client) is null then
        raise exception 'Bu birim için satış fiyatı tanımlı değil: % %', pr.name, u.name using errcode = 'P0001';
      end if;
      if v_price is distinct from u.price
         and not (v_offline and v_price = app.unit_price_at(u.id, v_client)) then
        raise exception 'Fiyat güncel değil: % % (güncel: %)', pr.name, u.name, u.price using errcode = 'P0001';
      end if;
      if v_price = 0 then raise exception 'Sıfır fiyatlı satışı yalnızca yönetici yapabilir (F-07)' using errcode = '42501'; end if;
    end if;

    if v_ldisc < 0 or v_ldisc > round(v_qty * v_price, 2) then
      raise exception 'Satır indirimi geçersiz: %', pr.name using errcode = '22023';
    end if;

    insert into _sale_lines values (v_line, pr.id, u.id, u.name, u.factor, v_qty, v_qty * u.factor, v_price,
      round(v_qty * v_price, 2), v_ldisc, 0, null, pr.vat_rate, pr.deposit_amount, pr.empty_product_id);
    v_gross := v_gross + round(v_qty * v_price, 2);
    v_ldisc_total := v_ldisc_total + v_ldisc;
  end loop;

  -- 2) Fiş indirimini satırlara dağıt (F-05)
  v_net_before_bill := v_gross - v_ldisc_total;
  if v_bill > v_net_before_bill then raise exception 'Fiş indirimi tutarı aşıyor' using errcode = '22023'; end if;
  if v_bill > 0 then
    v_share_left := v_bill;
    for rec in select line_no, line_gross - line_discount as net from _sale_lines order by line_no loop
      if rec.line_no = v_line then
        v_share := v_share_left;
      else
        v_share := round(v_bill * rec.net / v_net_before_bill, 2);
        v_share_left := v_share_left - v_share;
      end if;
      update _sale_lines set share = v_share where line_no = rec.line_no;
    end loop;
  end if;
  update _sale_lines set line_net = line_gross - line_discount - share where true;  -- pg_safeupdate: WHERE zorunlu
  select coalesce(sum(line_net), 0) into v_goods_net from _sale_lines;

  -- F-06: indirim limiti
  if v_role <> 'yonetici' and (v_ldisc_total + v_bill) > round(v_gross * v_set.max_discount_pct_satis / 100, 2) then
    raise exception 'İndirim limitinizi aşıyor (en fazla %%%). Yönetici onayı gerekir (F-06)',
      v_set.max_discount_pct_satis using errcode = '42501';
  end if;

  -- 3) Satış kaydı
  insert into public.sales(id, business_id, location_id, no, session_id, customer_id, goods_gross, discount_total,
                           goods_net, deposit_total, grand_total, sold_at, created_by, offline, late_sync, note)
  values (v_id, p_business, v_loc, v_no, v_sess.id, v_cust.id, v_gross, v_ldisc_total + v_bill,
          v_goods_net, 0, v_goods_net, v_sold_at, auth.uid(), v_offline,
          v_offline and v_client < v_sess.opened_at, nullif(trim(p->>'note'), ''));

  for rec in select l.*, coalesce(pc.avg_cost, 0) as avg_cost, coalesce(pc.has_cost, false) as has_cost
               from _sale_lines l left join public.product_costs pc on pc.product_id = l.product_id
              order by l.line_no loop
    insert into public.sale_items(sale_id, business_id, line_no, product_id, unit_id, unit_name, factor, qty, base_qty,
                                  unit_price, line_gross, line_discount, bill_discount_share, line_net, vat_rate)
    values (v_id, p_business, rec.line_no, rec.product_id, rec.unit_id, rec.unit_name, rec.factor, rec.qty, rec.base_qty,
            rec.unit_price, rec.line_gross, rec.line_discount, rec.share, rec.line_net, rec.vat_rate)
    returning id into v_item_id;
    insert into public.sale_item_costs(sale_item_id, business_id, unit_cost, total_cost, has_cost)
    values (v_item_id, p_business, rec.avg_cost, round(rec.avg_cost * rec.base_qty, 2), rec.has_cost);
  end loop;

  -- 4) Stok hareketleri (ürün sırasıyla: kilit sırası sabit, T-008)
  for rec in select product_id, sum(base_qty)::int as q from _sale_lines group by product_id order by product_id loop
    perform app.post_stock(p_business, v_loc, rec.product_id, -rec.q, 'satis', 'sale', v_id);
  end loop;

  -- 5) Depozito ve boş kap (D-03..D-06)
  for d in select product_id, sum(base_qty)::int as sold, max(deposit_amount) as dep, max(empty_product_id::text)::uuid as empty_id
             from _sale_lines where deposit_amount is not null group by product_id order by product_id loop
    select coalesce(max((x->>'empty_returned')::int), d.sold) into v_ret
      from jsonb_array_elements(coalesce(p->'deposits', '[]')) x where (x->>'product_id')::uuid = d.product_id;
    v_ret := coalesce(v_ret, d.sold);
    if v_ret < 0 then raise exception 'Boş kap sayısı geçersiz' using errcode = '22023'; end if;

    if d.sold - v_ret > 0 then
      v_amt := (d.sold - v_ret) * d.dep;                     -- müşteriden depozito alınır
    elsif d.sold - v_ret < 0 then
      v_amt := -app.deposit_refund_amount(p_business, v_cust.id, d.product_id, v_ret - d.sold);  -- fazla boş: depozito iadesi
    else
      v_amt := 0;
    end if;

    insert into public.sale_deposits(sale_id, business_id, product_id, sold_qty, empty_returned, net_containers, amount)
    values (v_id, p_business, d.product_id, d.sold, v_ret, d.sold - v_ret, v_amt);
    if d.sold - v_ret <> 0 then
      insert into public.container_ledger(business_id, customer_id, product_id, qty, amount, type, ref_type, ref_id, created_by)
      values (p_business, v_cust.id, d.product_id, d.sold - v_ret, v_amt, 'satis', 'sale', v_id, auth.uid());
    end if;
    if v_ret > 0 then
      perform app.post_stock(p_business, v_loc, d.empty_id, v_ret, 'bos_kap_giris', 'sale', v_id);
    end if;
    v_dep_total := v_dep_total + v_amt;
  end loop;
  -- Satılmayan ürün için gönderilmiş depozito satırı kabul edilmez
  if exists (select 1 from jsonb_array_elements(coalesce(p->'deposits', '[]')) x
              where not exists (select 1 from _sale_lines l where l.product_id = (x->>'product_id')::uuid
                                  and l.deposit_amount is not null)) then
    raise exception 'Boş kap bilgisi yalnızca satılan depozitolu ürünler için girilebilir' using errcode = '22023';
  end if;

  v_grand := v_goods_net + v_dep_total;
  if v_grand < 0 then
    raise exception 'Fiş toplamı negatif olamaz; fazla boş kap için "Depozito iadesi" işlemini kullanın' using errcode = '22023';
  end if;

  -- 6) Ödemeler (S-03)
  for it in select * from jsonb_array_elements(coalesce(p->'payments', '[]')) loop
    v_amt := round((it->>'amount')::numeric, 2);
    if v_amt is null or v_amt <= 0 then raise exception 'Ödeme tutarı geçersiz' using errcode = '22023'; end if;
    case it->>'method'
      when 'nakit' then v_cash := v_cash + v_amt;
      when 'pos' then v_pos := v_pos + v_amt;
      when 'veresiye' then v_credit := v_credit + v_amt;
      else raise exception 'Ödeme şekli geçersiz: %', it->>'method' using errcode = '22023';
    end case;
  end loop;
  v_pay_total := v_cash + v_pos + v_credit;
  if v_pay_total <> v_grand then
    raise exception 'Ödemeler toplamı (%) fiş toplamına (%) eşit değil (S-03)', v_pay_total, v_grand using errcode = '22023';
  end if;
  if v_given is not null and v_given < v_cash then
    raise exception 'Alınan nakit, nakit ödeme tutarından az olamaz' using errcode = '22023';
  end if;

  -- V-01..V-02: veresiye
  if v_credit > 0 then
    if v_cust.id is null then raise exception 'Veresiye için müşteri seçilmelidir (V-01)' using errcode = '22023'; end if;
    perform 1 from public.customers where id = v_cust.id for update;   -- aynı müşteriye eşzamanlı veresiye
    v_balance := app.customer_balance(v_cust.id);
    if not v_cust.unlimited_credit and v_balance + v_credit > v_cust.credit_limit then
      if v_offline then
        v_offline_limit := true;                                           -- C-03
      elsif coalesce((p->>'limit_override')::boolean, false) and v_role = 'yonetici' then
        v_limit_override := true;
      else
        raise exception 'Veresiye limiti aşılıyor. Bakiye: %, limit: %, bu satış: % (V-02)',
          v_balance, v_cust.credit_limit, v_credit using errcode = 'P0001';
      end if;
    end if;
    insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, ref_id, created_by)
    values (p_business, v_cust.id, 'satis', v_credit, 'sale', v_id, auth.uid());
  end if;

  if v_cash > 0 then insert into public.sale_payments(sale_id, business_id, method, amount) values (v_id, p_business, 'nakit', v_cash); end if;
  if v_pos > 0 then insert into public.sale_payments(sale_id, business_id, method, amount) values (v_id, p_business, 'pos', v_pos); end if;
  if v_credit > 0 then insert into public.sale_payments(sale_id, business_id, method, amount) values (v_id, p_business, 'veresiye', v_credit); end if;
  perform app.post_cash(p_business, v_sess.id, 'satis', v_cash, 'sale', v_id);

  update public.sales set deposit_total = v_dep_total, grand_total = v_grand,
         cash_given = v_given, change_given = case when v_given is not null then v_given - v_cash end,
         limit_override = v_limit_override, offline_limit_exceeded = v_offline_limit
   where id = v_id;

  perform app.audit(p_business, case when v_limit_override then 'satis_limit_asimi' else 'satis' end,
                    'sales', v_id::text, null,
                    jsonb_build_object('no', v_no, 'grand_total', v_grand, 'customer_id', v_cust.id,
                                       'offline', v_offline, 'limit_override', v_limit_override,
                                       'offline_limit_exceeded', v_offline_limit));

  return jsonb_build_object('id', v_id, 'no', v_no, 'grand_total', v_grand, 'goods_net', v_goods_net,
                            'deposit_total', v_dep_total,
                            'change', case when v_given is not null then v_given - v_cash end,
                            'session_id', v_sess.id, 'duplicate', false,
                            'limit_override', v_limit_override, 'offline_limit_exceeded', v_offline_limit);
end $$;

-- ---------------------------------------------------------------------------
-- RPC: satış iptali (I-01) — yalnızca yönetici, kasa günü açıkken, iadesi yoksa
-- ---------------------------------------------------------------------------
create or replace function public.cancel_sale(p_sale uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.sales; r record;
begin
  select * into s from public.sales where id = p_sale for update;
  if s.id is null then raise exception 'Satış bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(s.business_id, 'yonetici');
  if coalesce(trim(p_reason), '') = '' then raise exception 'İptal nedeni zorunludur (I-05)' using errcode = '22023'; end if;
  if s.status <> 'tamamlandi' then raise exception 'Satış zaten iptal edilmiş' using errcode = 'P0001'; end if;
  if (select status from public.cash_sessions where id = s.session_id) <> 'acik' then
    raise exception 'Kasa günü kapandığı için satış iptal edilemez; iade işlemi yapın (I-01)' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.returns where sale_id = p_sale) then
    raise exception 'İadesi yapılmış satış iptal edilemez' using errcode = 'P0001';
  end if;

  for r in select product_id, location_id, sum(qty)::int as q from public.stock_movements
            where ref_type = 'sale' and ref_id = p_sale group by product_id, location_id order by product_id loop
    perform app.post_stock(s.business_id, r.location_id, r.product_id, -r.q, 'satis_iptal', 'sale_cancel', p_sale);
  end loop;
  insert into public.container_ledger(business_id, customer_id, product_id, qty, amount, type, ref_type, ref_id, created_by)
  select business_id, customer_id, product_id, -qty, -amount, 'iptal', 'sale_cancel', p_sale, auth.uid()
    from public.container_ledger where ref_type = 'sale' and ref_id = p_sale;
  insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, ref_id, created_by)
  select business_id, customer_id, 'iptal', -amount, 'sale_cancel', p_sale, auth.uid()
    from public.customer_ledger where ref_type = 'sale' and ref_id = p_sale;
  insert into public.cash_movements(business_id, session_id, type, amount, ref_type, ref_id, created_by)
  select business_id, session_id, 'satis_iptal', -amount, 'sale_cancel', p_sale, auth.uid()
    from public.cash_movements where ref_type = 'sale' and ref_id = p_sale;

  update public.sales set status = 'iptal', cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = trim(p_reason)
   where id = p_sale;
  perform app.audit(s.business_id, 'satis_iptal', 'sales', p_sale::text,
                    jsonb_build_object('status', 'tamamlandi'), jsonb_build_object('status', 'iptal', 'reason', p_reason));
end $$;

-- ---------------------------------------------------------------------------
-- RPC: iade (I-02..I-07) — yönetici
-- p = { id, sale_id, reason, request_id?,
--       items: [{ sale_item_id, qty, condition: saglam|kusurlu }],
--       refunds?: [{ method: nakit|pos|veresiye, amount }] }   -- verilmezse I-04 dağılımı
-- ---------------------------------------------------------------------------
create or replace function public.create_return(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id    uuid := (p->>'id')::uuid;
  s       public.sales;
  v_sess  public.cash_sessions;
  v_no    bigint;
  it      jsonb;
  si      public.sale_items;
  v_prev  int;
  v_prev_amt numeric;
  v_qty   int;
  v_amt   numeric;
  v_total numeric := 0;
  v_ri    uuid;
  v_cost  numeric;
  v_left  numeric;
  v_avail numeric;
  m       text;
  v_cash numeric := 0; v_pos numeric := 0; v_credit numeric := 0;
begin
  if v_id is null then raise exception 'İade kimliği eksik' using errcode = '22023'; end if;
  if exists (select 1 from public.returns where id = v_id) then
    return (select jsonb_build_object('id', id, 'no', no, 'total_refund', total_refund, 'duplicate', true)
              from public.returns where id = v_id);
  end if;
  select * into s from public.sales where id = (p->>'sale_id')::uuid for update;
  if s.id is null then raise exception 'Satış bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(s.business_id, 'yonetici');
  if s.status <> 'tamamlandi' then raise exception 'İptal edilmiş satış iade edilemez' using errcode = 'P0001'; end if;
  if coalesce(trim(p->>'reason'), '') = '' then raise exception 'İade nedeni zorunludur (I-05)' using errcode = '22023'; end if;
  if jsonb_array_length(coalesce(p->'items', '[]')) = 0 then raise exception 'İade edilecek kalem seçilmedi' using errcode = '22023'; end if;

  v_sess := app.ensure_session(s.business_id, s.location_id);     -- I-06: bugünün kasası
  v_no := app.next_number(s.business_id, 'iade');
  insert into public.returns(id, business_id, location_id, no, sale_id, session_id, reason, total_refund, created_by)
  values (v_id, s.business_id, s.location_id, v_no, s.id, v_sess.id, trim(p->>'reason'), 0, auth.uid());

  for it in select * from jsonb_array_elements(p->'items') loop
    select * into si from public.sale_items where id = (it->>'sale_item_id')::uuid and sale_id = s.id;
    if si.id is null then raise exception 'Satış kalemi bulunamadı' using errcode = 'P0002'; end if;
    v_qty := (it->>'qty')::int;
    if v_qty is null or v_qty <= 0 then raise exception 'İade miktarı geçersiz' using errcode = '22023'; end if;
    if coalesce(it->>'condition', '') not in ('saglam', 'kusurlu') then
      raise exception 'Ürün durumu seçilmelidir: sağlam / kusurlu (I-03)' using errcode = '22023';
    end if;
    select coalesce(sum(qty), 0), coalesce(sum(refund_amount), 0) into v_prev, v_prev_amt
      from public.return_items where sale_item_id = si.id;
    if v_qty > si.qty - v_prev then
      raise exception 'İade miktarı kalan miktarı aşıyor (satılan: %, önceden iade: %) (I-02)', si.qty, v_prev using errcode = 'P0001';
    end if;
    -- Kalanın tamamı iade ediliyorsa kuruş farkı kalmasın
    if v_qty = si.qty - v_prev then v_amt := si.line_net - v_prev_amt;
    else v_amt := round(si.line_net * v_qty / si.qty, 2); end if;

    insert into public.return_items(return_id, business_id, sale_item_id, product_id, qty, base_qty, condition, refund_amount)
    values (v_id, s.business_id, si.id, si.product_id, v_qty, v_qty * si.factor, it->>'condition', v_amt)
    returning id into v_ri;
    select unit_cost into v_cost from public.sale_item_costs where sale_item_id = si.id;
    insert into public.return_item_costs(return_item_id, business_id, unit_cost, total_cost)
    values (v_ri, s.business_id, coalesce(v_cost, 0), round(coalesce(v_cost, 0) * v_qty * si.factor, 2));

    perform app.post_stock(s.business_id, s.location_id, si.product_id, v_qty * si.factor, 'iade', 'return', v_id);
    if it->>'condition' = 'kusurlu' then
      perform app.post_stock(s.business_id, s.location_id, si.product_id, -(v_qty * si.factor), 'iade_fire', 'return', v_id);
      insert into public.waste_records(id, business_id, location_id, product_id, unit_id, qty, base_qty, reason, note, created_by)
      values (gen_random_uuid(), s.business_id, s.location_id, si.product_id, si.unit_id, v_qty, v_qty * si.factor,
              'iade_kusurlu', 'İade no ' || v_no, auth.uid());
    end if;
    v_total := v_total + v_amt;
  end loop;

  -- Para iadesi dağılımı
  if p ? 'refunds' and jsonb_array_length(p->'refunds') > 0 then
    for it in select * from jsonb_array_elements(p->'refunds') loop
      v_amt := round((it->>'amount')::numeric, 2);
      if v_amt is null or v_amt <= 0 then raise exception 'İade tutarı geçersiz' using errcode = '22023'; end if;
      case it->>'method'
        when 'nakit' then v_cash := v_cash + v_amt;
        when 'pos' then v_pos := v_pos + v_amt;
        when 'veresiye' then v_credit := v_credit + v_amt;
        else raise exception 'Ödeme şekli geçersiz' using errcode = '22023';
      end case;
    end loop;
    if v_cash + v_pos + v_credit <> v_total then
      raise exception 'İade ödemeleri toplamı (%) iade tutarına (%) eşit değil', v_cash + v_pos + v_credit, v_total using errcode = '22023';
    end if;
  else
    -- I-04: önce veresiye, sonra POS, sonra nakit (orijinal ödemeden önceki iadeler düşülerek)
    v_left := v_total;
    foreach m in array array['veresiye', 'pos'] loop
      select coalesce(sum(amount), 0) into v_avail from public.sale_payments where sale_id = s.id and method = m;
      v_avail := v_avail - coalesce((select sum(rp.amount) from public.return_payments rp join public.returns r on r.id = rp.return_id
                                      where r.sale_id = s.id and rp.method = m), 0);
      v_amt := greatest(least(v_left, v_avail), 0);
      if m = 'veresiye' then v_credit := v_amt; else v_pos := v_amt; end if;
      v_left := v_left - v_amt;
    end loop;
    v_cash := v_left;
  end if;

  if v_credit > 0 and s.customer_id is null then
    raise exception 'Müşterisiz satışta veresiyeye iade yapılamaz' using errcode = '22023';
  end if;
  if v_cash > 0 then insert into public.return_payments(return_id, business_id, method, amount) values (v_id, s.business_id, 'nakit', v_cash); end if;
  if v_pos > 0 then insert into public.return_payments(return_id, business_id, method, amount) values (v_id, s.business_id, 'pos', v_pos); end if;
  if v_credit > 0 then
    insert into public.return_payments(return_id, business_id, method, amount) values (v_id, s.business_id, 'veresiye', v_credit);
    insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, ref_id, created_by)
    values (s.business_id, s.customer_id, 'iade', -v_credit, 'return', v_id, auth.uid());
  end if;
  perform app.post_cash(s.business_id, v_sess.id, 'iade', -v_cash, 'return', v_id);

  update public.returns set total_refund = v_total where id = v_id;
  if nullif(p->>'request_id', '') is not null then
    update public.return_requests set status = 'onaylandi', decided_by = auth.uid(), decided_at = now(), return_id = v_id
     where id = (p->>'request_id')::uuid and status = 'bekliyor' and sale_id = s.id;
  end if;
  perform app.audit(s.business_id, 'iade', 'returns', v_id::text, null, p || jsonb_build_object('total', v_total));
  return jsonb_build_object('id', v_id, 'no', v_no, 'total_refund', v_total, 'duplicate', false,
                            'refunds', jsonb_build_object('nakit', v_cash, 'pos', v_pos, 'veresiye', v_credit));
end $$;

-- Satış personeli iade talebi (I-05)
create or replace function public.request_return(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.sales; v_id uuid := (p->>'id')::uuid;
begin
  select * into s from public.sales where id = (p->>'sale_id')::uuid;
  if s.id is null then raise exception 'Satış bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(s.business_id, 'yonetici', 'satis');
  if not app.can_see_sale(s.id) then raise exception 'Bu satış için talep oluşturamazsınız' using errcode = '42501'; end if;
  if coalesce(trim(p->>'reason'), '') = '' then raise exception 'Neden zorunludur' using errcode = '22023'; end if;
  insert into public.return_requests(id, business_id, sale_id, items, reason, requested_by)
  values (v_id, s.business_id, s.id, coalesce(p->'items', '[]'), trim(p->>'reason'), auth.uid())
  on conflict (id) do nothing;
  return v_id;
end $$;

create or replace function public.reject_return_request(p_request uuid, p_note text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bid uuid;
begin
  select business_id into v_bid from public.return_requests where id = p_request;
  if v_bid is null then raise exception 'Talep bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(v_bid, 'yonetici');
  update public.return_requests set status = 'reddedildi', decided_by = auth.uid(), decided_at = now(), decision_note = p_note
   where id = p_request and status = 'bekliyor';
end $$;

-- ---------------------------------------------------------------------------
-- RPC: veresiye tahsilatı (V-04, V-05)  p = { id, customer_id, method: nakit|pos, amount, note? }
-- ---------------------------------------------------------------------------
create or replace function public.record_customer_payment(p_business uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id   uuid := (p->>'id')::uuid;
  v_amt  numeric := round((p->>'amount')::numeric, 2);
  v_sess public.cash_sessions;
  c      public.customers;
begin
  perform app.require_role(p_business, 'yonetici', 'satis');
  if v_id is null then raise exception 'Kayıt kimliği eksik' using errcode = '22023'; end if;
  if exists (select 1 from public.customer_payments where id = v_id) then return v_id; end if;
  select * into c from public.customers where id = (p->>'customer_id')::uuid and business_id = p_business;
  if c.id is null then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
  if v_amt is null or v_amt <= 0 then raise exception 'Tutar sıfırdan büyük olmalıdır' using errcode = '22023'; end if;
  if coalesce(p->>'method', '') not in ('nakit', 'pos') then raise exception 'Tahsilat nakit veya POS olmalıdır' using errcode = '22023'; end if;
  v_sess := app.ensure_session(p_business, app.default_location(p_business));
  insert into public.customer_payments(id, business_id, customer_id, session_id, method, amount, note, created_by)
  values (v_id, p_business, c.id, v_sess.id, p->>'method', v_amt, nullif(trim(p->>'note'), ''), auth.uid());
  insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, ref_id, created_by)
  values (p_business, c.id, 'tahsilat', -v_amt, 'customer_payment', v_id, auth.uid());
  if p->>'method' = 'nakit' then
    perform app.post_cash(p_business, v_sess.id, 'tahsilat', v_amt, 'customer_payment', v_id);
  end if;
  perform app.audit(p_business, 'tahsilat', 'customer_payments', v_id::text, null, p);
  return v_id;
end $$;

create or replace function public.cancel_customer_payment(p_payment uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare cp public.customer_payments; v_sess public.cash_sessions;
begin
  select * into cp from public.customer_payments where id = p_payment for update;
  if cp.id is null then raise exception 'Tahsilat bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(cp.business_id, 'yonetici');
  if cp.status <> 'gecerli' then raise exception 'Tahsilat zaten iptal edilmiş' using errcode = 'P0001'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'İptal nedeni zorunludur' using errcode = '22023'; end if;
  v_sess := app.ensure_session(cp.business_id, app.default_location(cp.business_id));
  insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, ref_id, created_by)
  values (cp.business_id, cp.customer_id, 'tahsilat_iptal', cp.amount, 'customer_payment_cancel', cp.id, auth.uid());
  if cp.method = 'nakit' then
    perform app.post_cash(cp.business_id, v_sess.id, 'tahsilat_iptal', -cp.amount, 'customer_payment_cancel', cp.id);
  end if;
  update public.customer_payments set status = 'iptal', cancelled_by = auth.uid(), cancelled_at = now(),
         cancel_reason = trim(p_reason), cancel_session_id = v_sess.id where id = cp.id;
  perform app.audit(cp.business_id, 'tahsilat_iptal', 'customer_payments', cp.id::text, null, jsonb_build_object('reason', p_reason));
end $$;

-- ---------------------------------------------------------------------------
-- RPC: depozito iadesi / kap kaybı (D-05, D-06, D-08)
-- p = { id, customer_id?, product_id (dolu ürün), qty, kind: iade|kayip, refund_method?: nakit|veresiye, note? }
-- ---------------------------------------------------------------------------
create or replace function public.container_return(p_business uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role public.member_role := app.require_role(p_business, 'yonetici', 'satis');
  v_id   uuid := (p->>'id')::uuid;
  v_loc  uuid := app.default_location(p_business);
  v_kind text := coalesce(p->>'kind', 'iade');
  v_qty  int := (p->>'qty')::int;
  v_cust uuid := nullif(p->>'customer_id', '')::uuid;
  v_meth text := coalesce(p->>'refund_method', 'nakit');
  pr     public.products;
  v_amt  numeric;
  v_sess public.cash_sessions;
begin
  if v_id is null then raise exception 'Kayıt kimliği eksik' using errcode = '22023'; end if;
  if exists (select 1 from public.container_returns where id = v_id) then
    return (select jsonb_build_object('id', id, 'amount', amount, 'duplicate', true) from public.container_returns where id = v_id);
  end if;
  pr := app.product_in_business(p_business, (p->>'product_id')::uuid);
  if pr.deposit_amount is null then raise exception 'Bu ürün depozitolu değil' using errcode = '22023'; end if;
  if v_qty is null or v_qty <= 0 then raise exception 'Kap adedi geçersiz' using errcode = '22023'; end if;
  if v_kind not in ('iade', 'kayip') then raise exception 'İşlem türü geçersiz' using errcode = '22023'; end if;
  if v_kind = 'kayip' and v_role <> 'yonetici' then raise exception 'Kap kaybını yalnızca yönetici işleyebilir' using errcode = '42501'; end if;
  if v_cust is not null and not exists (select 1 from public.customers where id = v_cust and business_id = p_business) then
    raise exception 'Müşteri bulunamadı' using errcode = 'P0002';
  end if;
  if v_kind = 'iade' and v_meth = 'veresiye' and v_cust is null then
    raise exception 'Veresiyeden mahsup için müşteri seçilmelidir' using errcode = '22023';
  end if;
  if v_meth not in ('nakit', 'veresiye') then raise exception 'İade şekli geçersiz' using errcode = '22023'; end if;

  v_amt := app.deposit_refund_amount(p_business, v_cust, pr.id, v_qty);
  v_sess := app.ensure_session(p_business, v_loc);

  insert into public.container_returns(id, business_id, location_id, session_id, customer_id, product_id, qty, kind,
                                       refund_method, amount, note, created_by)
  values (v_id, p_business, v_loc, v_sess.id, v_cust, pr.id, v_qty, v_kind,
          case when v_kind = 'iade' then v_meth end, v_amt, nullif(trim(p->>'note'), ''), auth.uid());
  insert into public.container_ledger(business_id, customer_id, product_id, qty, amount, type, ref_type, ref_id, created_by)
  values (p_business, v_cust, pr.id, -v_qty, -v_amt, v_kind, 'container_return', v_id, auth.uid());

  if v_kind = 'iade' then
    perform app.post_stock(p_business, v_loc, pr.empty_product_id, v_qty, 'bos_kap_giris', 'container_return', v_id);
    if v_meth = 'nakit' then
      perform app.post_cash(p_business, v_sess.id, 'depozito_iade', -v_amt, 'container_return', v_id);
    elsif v_amt > 0 then
      insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, ref_id, created_by)
      values (p_business, v_cust, 'depozito_mahsup', -v_amt, 'container_return', v_id, auth.uid());
    end if;
  end if;
  perform app.audit(p_business, 'kap_' || v_kind, 'container_returns', v_id::text, null, p || jsonb_build_object('amount', v_amt));
  return jsonb_build_object('id', v_id, 'amount', v_amt, 'duplicate', false);
end $$;

select app.apply_grants();

commit;
begin;

-- ===== 20260930000500_cash.sql =====
-- ALKASU 0005 — Gider, kasa hareketleri, gün sonu kapatma
-- Kurallar: K-01..K-10

create table public.expense_categories (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id),
  name         text not null check (length(trim(name)) > 0),
  active       boolean not null default true,
  sort         smallint not null default 0
);
create unique index expense_categories_name on public.expense_categories(business_id, lower(name));

create table public.expenses (
  id            uuid primary key,
  business_id   uuid not null references public.businesses(id),
  location_id   uuid not null references public.locations(id),
  category_id   uuid not null references public.expense_categories(id),
  expense_date  date not null,
  amount        numeric(14,2) not null check (amount > 0),
  method        text not null check (method in ('kasa', 'banka')),
  description   text,
  session_id    uuid references public.cash_sessions(id),
  status        text not null default 'gecerli' check (status in ('gecerli', 'iptal')),
  created_by    uuid,
  created_at    timestamptz not null default now(),
  cancelled_by  uuid,
  cancelled_at  timestamptz,
  cancel_reason text
);
create index expenses_business_date on public.expenses(business_id, expense_date desc);
create trigger expenses_audit after insert or update on public.expenses for each row execute function audit.tg_row();

alter table public.expense_categories enable row level security;
alter table public.expenses enable row level security;
create policy expense_categories_select on public.expense_categories for select to authenticated using (app.is_admin(business_id));
create policy expenses_select on public.expenses for select to authenticated using (app.is_admin(business_id));

-- K-10: varsayılan kategoriler işletme oluşturulurken eklenir
create or replace function app.tg_business_defaults() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.expense_categories(business_id, name, sort)
  select new.id, x.name, x.ord from unnest(array['Kira','Elektrik/Su/Doğalgaz','Yakıt','Araç bakım','Personel',
                                                 'Vergi/SGK','Kırtasiye/Sarf','Yemek','Diğer']) with ordinality as x(name, ord);
  return new;
end $$;
create trigger businesses_defaults after insert on public.businesses
  for each row execute function app.tg_business_defaults();

create or replace function public.upsert_expense_category(p_business uuid, p_name text, p_id uuid default null, p_active boolean default true)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  perform app.require_role(p_business, 'yonetici');
  if exists (select 1 from public.expense_categories where business_id = p_business and lower(name) = lower(trim(p_name))
             and id is distinct from p_id) then
    raise exception 'Bu adla bir kategori zaten var' using errcode = '23505';
  end if;
  if p_id is null then
    insert into public.expense_categories(business_id, name, active, sort)
    values (p_business, trim(p_name), p_active, 100) returning id into v_id;
  else
    update public.expense_categories set name = trim(p_name), active = p_active
     where id = p_id and business_id = p_business returning id into v_id;
  end if;
  return v_id;
end $$;

-- RPC: gider (K-09)  p = { id, category_id, expense_date?, amount, method: kasa|banka, description? }
create or replace function public.add_expense(p_business uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id   uuid := (p->>'id')::uuid;
  v_amt  numeric := round((p->>'amount')::numeric, 2);
  v_loc  uuid := app.default_location(p_business);
  v_sess public.cash_sessions;
begin
  perform app.require_role(p_business, 'yonetici');
  if v_id is null then raise exception 'Kayıt kimliği eksik' using errcode = '22023'; end if;
  if exists (select 1 from public.expenses where id = v_id) then return v_id; end if;
  if v_amt is null or v_amt <= 0 then raise exception 'Tutar sıfırdan büyük olmalıdır' using errcode = '22023'; end if;
  if coalesce(p->>'method', '') not in ('kasa', 'banka') then raise exception 'Ödeme şekli geçersiz' using errcode = '22023'; end if;
  if not exists (select 1 from public.expense_categories where id = (p->>'category_id')::uuid and business_id = p_business) then
    raise exception 'Gider kategorisi bulunamadı' using errcode = 'P0002';
  end if;
  if p->>'method' = 'kasa' then v_sess := app.ensure_session(p_business, v_loc); end if;
  insert into public.expenses(id, business_id, location_id, category_id, expense_date, amount, method, description, session_id, created_by)
  values (v_id, p_business, v_loc, (p->>'category_id')::uuid,
          coalesce(nullif(p->>'expense_date', '')::date, app.local_date(now())), v_amt, p->>'method',
          nullif(trim(p->>'description'), ''), v_sess.id, auth.uid());
  if p->>'method' = 'kasa' then
    perform app.post_cash(p_business, v_sess.id, 'gider', -v_amt, 'expense', v_id, nullif(trim(p->>'description'), ''));
  end if;
  return v_id;
end $$;

create or replace function public.cancel_expense(p_expense uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.expenses; v_sess public.cash_sessions;
begin
  select * into e from public.expenses where id = p_expense for update;
  if e.id is null then raise exception 'Gider bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(e.business_id, 'yonetici');
  if e.status <> 'gecerli' then raise exception 'Gider zaten iptal edilmiş' using errcode = 'P0001'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'İptal nedeni zorunludur' using errcode = '22023'; end if;
  if e.method = 'kasa' then
    v_sess := app.ensure_session(e.business_id, e.location_id);
    perform app.post_cash(e.business_id, v_sess.id, 'duzeltme', e.amount, 'expense_cancel', e.id, 'Gider iptali');
  end if;
  update public.expenses set status = 'iptal', cancelled_by = auth.uid(), cancelled_at = now(), cancel_reason = trim(p_reason)
   where id = e.id;
end $$;

-- RPC: kasaya giriş / kasadan çıkış  p = { type: giris|cikis|duzeltme, amount (duzeltme için işaretli), note }
create or replace function public.add_cash_movement(p_business uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_amt numeric := round((p->>'amount')::numeric, 2); v_sess public.cash_sessions; v_type text := p->>'type';
begin
  perform app.require_role(p_business, 'yonetici');
  if v_type not in ('giris', 'cikis', 'duzeltme') then raise exception 'Hareket türü geçersiz' using errcode = '22023'; end if;
  if v_amt is null or v_amt = 0 or (v_type <> 'duzeltme' and v_amt < 0) then
    raise exception 'Tutar geçersiz' using errcode = '22023';
  end if;
  if coalesce(trim(p->>'note'), '') = '' then raise exception 'Açıklama zorunludur' using errcode = '22023'; end if;
  v_sess := app.ensure_session(p_business, app.default_location(p_business));
  perform app.post_cash(p_business, v_sess.id, v_type,
                        case when v_type = 'cikis' then -v_amt else v_amt end, 'manual', null, trim(p->>'note'));
  perform app.audit(p_business, 'kasa_' || v_type, 'cash_movements', v_sess.id::text, null, p);
end $$;

-- Kasa günü özeti (yönetici). p_session null = açık gün
create or replace function public.cash_session_summary(p_business uuid, p_session uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s public.cash_sessions; v jsonb; v_pos numeric;
begin
  perform app.require_role(p_business, 'yonetici');
  if p_session is null then
    select * into s from public.cash_sessions where business_id = p_business and status = 'acik'
     and location_id = app.default_location(p_business);
    if s.id is null then
      return jsonb_build_object('status', 'yok',
        'opening_cash', coalesce((select carry_over from public.cash_sessions where business_id = p_business and status = 'kapali'
                                   order by closed_at desc limit 1), 0));
    end if;
  else
    select * into s from public.cash_sessions where id = p_session and business_id = p_business;
    if s.id is null then raise exception 'Kasa günü bulunamadı' using errcode = 'P0002'; end if;
  end if;

  select coalesce(jsonb_object_agg(type, total), '{}'::jsonb) into v
    from (select type, sum(amount) as total from public.cash_movements where session_id = s.id group by type) t;

  v_pos := coalesce((select sum(sp.amount) from public.sale_payments sp join public.sales sa on sa.id = sp.sale_id
                      where sa.session_id = s.id and sa.status = 'tamamlandi' and sp.method = 'pos'), 0)
         + coalesce((select sum(amount) from public.customer_payments where session_id = s.id and method = 'pos'), 0)
         - coalesce((select sum(amount) from public.customer_payments where cancel_session_id = s.id and method = 'pos'), 0)
         - coalesce((select sum(rp.amount) from public.return_payments rp join public.returns r on r.id = rp.return_id
                      where r.session_id = s.id and rp.method = 'pos'), 0);

  return jsonb_build_object(
    'id', s.id, 'no', s.no, 'status', s.status, 'opened_at', s.opened_at, 'closed_at', s.closed_at,
    'opening_cash', s.opening_cash,
    'movements', v,
    'expected_cash', coalesce(s.expected_cash, s.opening_cash + coalesce((select sum(amount) from public.cash_movements
                                                                          where session_id = s.id and type <> 'gun_sonu_teslim'), 0)),
    'pos_expected', coalesce(s.pos_expected, v_pos),
    'sales_count', (select count(*) from public.sales where session_id = s.id and status = 'tamamlandi'),
    'sales_total', coalesce((select sum(grand_total) from public.sales where session_id = s.id and status = 'tamamlandi'), 0),
    'goods_total', coalesce((select sum(goods_net) from public.sales where session_id = s.id and status = 'tamamlandi'), 0),
    'credit_sales', coalesce((select sum(sp.amount) from public.sale_payments sp join public.sales sa on sa.id = sp.sale_id
                               where sa.session_id = s.id and sa.status = 'tamamlandi' and sp.method = 'veresiye'), 0),
    'late_sync_count', (select count(*) from public.sales where session_id = s.id and late_sync),
    'counted_cash', s.counted_cash, 'cash_diff', s.cash_diff, 'diff_note', s.diff_note,
    'pos_slip', s.pos_slip, 'pos_diff', s.pos_diff, 'carry_over', s.carry_over
  );
end $$;

-- RPC: gün sonu kapatma (K-03..K-06)
-- p = { session_id, counted_cash, carry_over, pos_slip?, diff_note? }
create or replace function public.close_cash_session(p_business uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  s        public.cash_sessions;
  v_set    public.app_settings;
  v_sum    jsonb;
  v_exp    numeric;
  v_cnt    numeric := round((p->>'counted_cash')::numeric, 2);
  v_carry  numeric := round((p->>'carry_over')::numeric, 2);
  v_slip   numeric := round(nullif(p->>'pos_slip', '')::numeric, 2);
  v_posexp numeric;
  v_diff   numeric;
begin
  perform app.require_role(p_business, 'yonetici');
  select * into s from public.cash_sessions where id = (p->>'session_id')::uuid and business_id = p_business for update;
  if s.id is null then raise exception 'Kasa günü bulunamadı' using errcode = 'P0002'; end if;
  if s.status <> 'acik' then raise exception 'Kasa günü zaten kapalı (K-06)' using errcode = 'P0001'; end if;
  if v_cnt is null or v_cnt < 0 then raise exception 'Sayılan nakit girilmelidir' using errcode = '22023'; end if;
  if v_carry is null or v_carry < 0 or v_carry > v_cnt then
    raise exception 'Devreden nakit 0 ile sayılan nakit arasında olmalıdır (K-05)' using errcode = '22023';
  end if;
  select * into v_set from public.app_settings where business_id = p_business;

  v_sum := public.cash_session_summary(p_business, s.id);
  v_exp := (v_sum->>'expected_cash')::numeric;
  v_posexp := (v_sum->>'pos_expected')::numeric;
  v_diff := v_cnt - v_exp;
  if abs(v_diff) > v_set.cash_diff_tolerance and coalesce(trim(p->>'diff_note'), '') = '' then
    raise exception 'Kasa farkı % ₺ toleransı (% ₺) aşıyor; açıklama zorunludur (K-04)', v_diff, v_set.cash_diff_tolerance
      using errcode = '22023';
  end if;

  -- K-05: sayılan − devreden = gün sonu teslim
  perform app.post_cash(p_business, s.id, 'gun_sonu_teslim', -(v_cnt - v_carry), 'cash_session', s.id, 'Gün sonu teslim');

  update public.cash_sessions set
    status = 'kapali', closed_at = now(), closed_by = auth.uid(),
    expected_cash = v_exp, counted_cash = v_cnt, cash_diff = v_diff, diff_note = nullif(trim(p->>'diff_note'), ''),
    pos_expected = v_posexp, pos_slip = v_slip, pos_diff = case when v_slip is not null then v_slip - v_posexp end,
    carry_over = v_carry
  where id = s.id;

  perform app.audit(p_business, 'kasa_kapanis', 'cash_sessions', s.id::text, null,
                    jsonb_build_object('expected', v_exp, 'counted', v_cnt, 'diff', v_diff, 'carry_over', v_carry,
                                       'pos_expected', v_posexp, 'pos_slip', v_slip));
  return public.cash_session_summary(p_business, s.id);
end $$;

select app.apply_grants();

commit;
begin;

-- ===== 20260930000600_import_count.sql =====
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

commit;
begin;

-- ===== 20260930000700_reports.sql =====
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

commit;
begin;

-- ===== 20260930000800_audit_view.sql =====
-- ALKASU 0008 — İşlem geçmişi okuma (yönetici)
create or replace function public.audit_log(p_business uuid, p_limit integer default 100, p_offset integer default 0,
                                            p_action text default null, p_user uuid default null)
returns table(id bigint, at timestamptz, user_id uuid, user_name text, action text, table_name text, record_id text,
              old_data jsonb, new_data jsonb)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  perform app.require_role(p_business, 'yonetici');
  return query
  select l.id, l.at, l.user_id, m.display_name, l.action, l.table_name, l.record_id, l.old_data, l.new_data
    from audit.log l
    left join public.memberships m on m.user_id = l.user_id and m.business_id = l.business_id
   where l.business_id = p_business
     and (p_action is null or l.action = p_action)
     and (p_user is null or l.user_id = p_user)
   order by l.id desc
   limit least(greatest(p_limit, 1), 500) offset greatest(p_offset, 0);
end $$;

select app.apply_grants();

commit;
begin;

-- ===== 20261001000900_fix_safeupdate.sql =====
-- ALKASU 0009 — Supabase API isteklerinde pg_safeupdate etkin: WHERE'siz UPDATE reddedilir.
-- complete_sale içindeki geçici tablo güncellemesine WHERE eklendi (hata: "UPDATE requires a WHERE clause").

create or replace function public.complete_sale(p_business uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role    public.member_role := app.require_role(p_business, 'yonetici', 'satis');
  v_id      uuid := (p->>'id')::uuid;
  v_loc     uuid := coalesce(nullif(p->>'location_id', '')::uuid, app.default_location(p_business));
  v_set     public.app_settings;
  v_sess    public.cash_sessions;
  v_cust    public.customers;
  v_offline boolean := coalesce((p->>'offline')::boolean, false);
  v_client  timestamptz := coalesce(nullif(p->>'client_created_at', '')::timestamptz, now());
  v_sold_at timestamptz;
  v_no      bigint;
  it        jsonb;
  pr        public.products;
  u         public.product_units;
  v_line    int := 0;
  v_qty     int;
  v_price   numeric;
  v_ldisc   numeric;
  v_gross   numeric := 0;
  v_ldisc_total numeric := 0;
  v_bill    numeric := coalesce(nullif(p->>'bill_discount', '')::numeric, 0);
  v_net_before_bill numeric;
  v_share   numeric;
  v_share_left numeric;
  v_goods_net numeric := 0;
  v_dep_total numeric := 0;
  v_grand   numeric;
  v_pay_total numeric := 0;
  v_cash    numeric := 0; v_pos numeric := 0; v_credit numeric := 0;
  v_given   numeric := nullif(p->>'cash_given', '')::numeric;
  v_balance numeric;
  v_limit_override boolean := false;
  v_offline_limit boolean := false;
  d         record;
  v_ret     int;
  v_cb      record;
  v_amt     numeric;
  rec       record;
  v_item_id uuid;
begin
  if v_id is null then raise exception 'Satış kimliği eksik' using errcode = '22023'; end if;

  -- S-02: aynı kimlikle tekrar gönderim
  if exists (select 1 from public.sales where id = v_id) then
    return (select jsonb_build_object('id', s.id, 'no', s.no, 'grand_total', s.grand_total,
                                      'change', s.change_given, 'duplicate', true)
              from public.sales s where s.id = v_id and s.business_id = p_business);
  end if;

  select * into v_set from public.app_settings where business_id = p_business;
  if jsonb_array_length(coalesce(p->'items', '[]')) = 0 then
    raise exception 'Sepet boş' using errcode = '22023';
  end if;
  if v_bill < 0 then raise exception 'İndirim negatif olamaz' using errcode = '22023'; end if;

  if nullif(p->>'customer_id', '') is not null then
    select * into v_cust from public.customers where id = (p->>'customer_id')::uuid and business_id = p_business;
    if v_cust.id is null then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
    if not v_cust.active then raise exception 'Müşteri pasif durumda' using errcode = 'P0001'; end if;
  end if;

  v_sess := app.ensure_session(p_business, v_loc);
  v_sold_at := case when v_offline then least(v_client, now()) else now() end;
  v_no := app.next_number(p_business, 'satis');

  if to_regclass('pg_temp._sale_lines') is null then
  create temp table _sale_lines (
    line_no int, product_id uuid, unit_id uuid, unit_name text, factor int, qty int, base_qty int,
    unit_price numeric, line_gross numeric, line_discount numeric, share numeric default 0,
    line_net numeric, vat_rate smallint, deposit_amount numeric, empty_product_id uuid
  ) on commit drop;
  end if;
  truncate _sale_lines;

  -- 1) Kalemleri doğrula
  for it in select * from jsonb_array_elements(p->'items') loop
    v_line := v_line + 1;
    pr := app.product_in_business(p_business, (it->>'product_id')::uuid);
    if not pr.active then raise exception 'Pasif ürün satılamaz: % (S-06)', pr.name using errcode = 'P0001'; end if;
    if pr.is_container then raise exception 'Boş kap ürünü satılamaz: %', pr.name using errcode = 'P0001'; end if;
    select * into u from public.product_units where id = (it->>'unit_id')::uuid and product_id = pr.id;
    if u.id is null then raise exception 'Ürün birimi geçersiz: %', pr.name using errcode = '22023'; end if;
    if not u.active and not v_offline then raise exception 'Bu birim artık kullanılmıyor: % %', pr.name, u.name using errcode = 'P0001'; end if;

    v_qty   := (it->>'qty')::int;
    v_price := round((it->>'unit_price')::numeric, 2);
    v_ldisc := round(coalesce(nullif(it->>'line_discount', '')::numeric, 0), 2);
    if v_qty is null or v_qty <= 0 then raise exception 'Miktar geçersiz: %', pr.name using errcode = '22023'; end if;
    if v_price is null or v_price < 0 then raise exception 'Fiyat geçersiz: %', pr.name using errcode = '22023'; end if;

    if v_role <> 'yonetici' then
      -- Satış personeli fiyatı değiştiremez; çevrimdışında satış anındaki fiyat da kabul edilir (C-02)
      if u.price is null and app.unit_price_at(u.id, v_client) is null then
        raise exception 'Bu birim için satış fiyatı tanımlı değil: % %', pr.name, u.name using errcode = 'P0001';
      end if;
      if v_price is distinct from u.price
         and not (v_offline and v_price = app.unit_price_at(u.id, v_client)) then
        raise exception 'Fiyat güncel değil: % % (güncel: %)', pr.name, u.name, u.price using errcode = 'P0001';
      end if;
      if v_price = 0 then raise exception 'Sıfır fiyatlı satışı yalnızca yönetici yapabilir (F-07)' using errcode = '42501'; end if;
    end if;

    if v_ldisc < 0 or v_ldisc > round(v_qty * v_price, 2) then
      raise exception 'Satır indirimi geçersiz: %', pr.name using errcode = '22023';
    end if;

    insert into _sale_lines values (v_line, pr.id, u.id, u.name, u.factor, v_qty, v_qty * u.factor, v_price,
      round(v_qty * v_price, 2), v_ldisc, 0, null, pr.vat_rate, pr.deposit_amount, pr.empty_product_id);
    v_gross := v_gross + round(v_qty * v_price, 2);
    v_ldisc_total := v_ldisc_total + v_ldisc;
  end loop;

  -- 2) Fiş indirimini satırlara dağıt (F-05)
  v_net_before_bill := v_gross - v_ldisc_total;
  if v_bill > v_net_before_bill then raise exception 'Fiş indirimi tutarı aşıyor' using errcode = '22023'; end if;
  if v_bill > 0 then
    v_share_left := v_bill;
    for rec in select line_no, line_gross - line_discount as net from _sale_lines order by line_no loop
      if rec.line_no = v_line then
        v_share := v_share_left;
      else
        v_share := round(v_bill * rec.net / v_net_before_bill, 2);
        v_share_left := v_share_left - v_share;
      end if;
      update _sale_lines set share = v_share where line_no = rec.line_no;
    end loop;
  end if;
  update _sale_lines set line_net = line_gross - line_discount - share where true;  -- pg_safeupdate: WHERE zorunlu
  select coalesce(sum(line_net), 0) into v_goods_net from _sale_lines;

  -- F-06: indirim limiti
  if v_role <> 'yonetici' and (v_ldisc_total + v_bill) > round(v_gross * v_set.max_discount_pct_satis / 100, 2) then
    raise exception 'İndirim limitinizi aşıyor (en fazla %%%). Yönetici onayı gerekir (F-06)',
      v_set.max_discount_pct_satis using errcode = '42501';
  end if;

  -- 3) Satış kaydı
  insert into public.sales(id, business_id, location_id, no, session_id, customer_id, goods_gross, discount_total,
                           goods_net, deposit_total, grand_total, sold_at, created_by, offline, late_sync, note)
  values (v_id, p_business, v_loc, v_no, v_sess.id, v_cust.id, v_gross, v_ldisc_total + v_bill,
          v_goods_net, 0, v_goods_net, v_sold_at, auth.uid(), v_offline,
          v_offline and v_client < v_sess.opened_at, nullif(trim(p->>'note'), ''));

  for rec in select l.*, coalesce(pc.avg_cost, 0) as avg_cost, coalesce(pc.has_cost, false) as has_cost
               from _sale_lines l left join public.product_costs pc on pc.product_id = l.product_id
              order by l.line_no loop
    insert into public.sale_items(sale_id, business_id, line_no, product_id, unit_id, unit_name, factor, qty, base_qty,
                                  unit_price, line_gross, line_discount, bill_discount_share, line_net, vat_rate)
    values (v_id, p_business, rec.line_no, rec.product_id, rec.unit_id, rec.unit_name, rec.factor, rec.qty, rec.base_qty,
            rec.unit_price, rec.line_gross, rec.line_discount, rec.share, rec.line_net, rec.vat_rate)
    returning id into v_item_id;
    insert into public.sale_item_costs(sale_item_id, business_id, unit_cost, total_cost, has_cost)
    values (v_item_id, p_business, rec.avg_cost, round(rec.avg_cost * rec.base_qty, 2), rec.has_cost);
  end loop;

  -- 4) Stok hareketleri (ürün sırasıyla: kilit sırası sabit, T-008)
  for rec in select product_id, sum(base_qty)::int as q from _sale_lines group by product_id order by product_id loop
    perform app.post_stock(p_business, v_loc, rec.product_id, -rec.q, 'satis', 'sale', v_id);
  end loop;

  -- 5) Depozito ve boş kap (D-03..D-06)
  for d in select product_id, sum(base_qty)::int as sold, max(deposit_amount) as dep, max(empty_product_id::text)::uuid as empty_id
             from _sale_lines where deposit_amount is not null group by product_id order by product_id loop
    select coalesce(max((x->>'empty_returned')::int), d.sold) into v_ret
      from jsonb_array_elements(coalesce(p->'deposits', '[]')) x where (x->>'product_id')::uuid = d.product_id;
    v_ret := coalesce(v_ret, d.sold);
    if v_ret < 0 then raise exception 'Boş kap sayısı geçersiz' using errcode = '22023'; end if;

    if d.sold - v_ret > 0 then
      v_amt := (d.sold - v_ret) * d.dep;                     -- müşteriden depozito alınır
    elsif d.sold - v_ret < 0 then
      v_amt := -app.deposit_refund_amount(p_business, v_cust.id, d.product_id, v_ret - d.sold);  -- fazla boş: depozito iadesi
    else
      v_amt := 0;
    end if;

    insert into public.sale_deposits(sale_id, business_id, product_id, sold_qty, empty_returned, net_containers, amount)
    values (v_id, p_business, d.product_id, d.sold, v_ret, d.sold - v_ret, v_amt);
    if d.sold - v_ret <> 0 then
      insert into public.container_ledger(business_id, customer_id, product_id, qty, amount, type, ref_type, ref_id, created_by)
      values (p_business, v_cust.id, d.product_id, d.sold - v_ret, v_amt, 'satis', 'sale', v_id, auth.uid());
    end if;
    if v_ret > 0 then
      perform app.post_stock(p_business, v_loc, d.empty_id, v_ret, 'bos_kap_giris', 'sale', v_id);
    end if;
    v_dep_total := v_dep_total + v_amt;
  end loop;
  -- Satılmayan ürün için gönderilmiş depozito satırı kabul edilmez
  if exists (select 1 from jsonb_array_elements(coalesce(p->'deposits', '[]')) x
              where not exists (select 1 from _sale_lines l where l.product_id = (x->>'product_id')::uuid
                                  and l.deposit_amount is not null)) then
    raise exception 'Boş kap bilgisi yalnızca satılan depozitolu ürünler için girilebilir' using errcode = '22023';
  end if;

  v_grand := v_goods_net + v_dep_total;
  if v_grand < 0 then
    raise exception 'Fiş toplamı negatif olamaz; fazla boş kap için "Depozito iadesi" işlemini kullanın' using errcode = '22023';
  end if;

  -- 6) Ödemeler (S-03)
  for it in select * from jsonb_array_elements(coalesce(p->'payments', '[]')) loop
    v_amt := round((it->>'amount')::numeric, 2);
    if v_amt is null or v_amt <= 0 then raise exception 'Ödeme tutarı geçersiz' using errcode = '22023'; end if;
    case it->>'method'
      when 'nakit' then v_cash := v_cash + v_amt;
      when 'pos' then v_pos := v_pos + v_amt;
      when 'veresiye' then v_credit := v_credit + v_amt;
      else raise exception 'Ödeme şekli geçersiz: %', it->>'method' using errcode = '22023';
    end case;
  end loop;
  v_pay_total := v_cash + v_pos + v_credit;
  if v_pay_total <> v_grand then
    raise exception 'Ödemeler toplamı (%) fiş toplamına (%) eşit değil (S-03)', v_pay_total, v_grand using errcode = '22023';
  end if;
  if v_given is not null and v_given < v_cash then
    raise exception 'Alınan nakit, nakit ödeme tutarından az olamaz' using errcode = '22023';
  end if;

  -- V-01..V-02: veresiye
  if v_credit > 0 then
    if v_cust.id is null then raise exception 'Veresiye için müşteri seçilmelidir (V-01)' using errcode = '22023'; end if;
    perform 1 from public.customers where id = v_cust.id for update;   -- aynı müşteriye eşzamanlı veresiye
    v_balance := app.customer_balance(v_cust.id);
    if not v_cust.unlimited_credit and v_balance + v_credit > v_cust.credit_limit then
      if v_offline then
        v_offline_limit := true;                                           -- C-03
      elsif coalesce((p->>'limit_override')::boolean, false) and v_role = 'yonetici' then
        v_limit_override := true;
      else
        raise exception 'Veresiye limiti aşılıyor. Bakiye: %, limit: %, bu satış: % (V-02)',
          v_balance, v_cust.credit_limit, v_credit using errcode = 'P0001';
      end if;
    end if;
    insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, ref_id, created_by)
    values (p_business, v_cust.id, 'satis', v_credit, 'sale', v_id, auth.uid());
  end if;

  if v_cash > 0 then insert into public.sale_payments(sale_id, business_id, method, amount) values (v_id, p_business, 'nakit', v_cash); end if;
  if v_pos > 0 then insert into public.sale_payments(sale_id, business_id, method, amount) values (v_id, p_business, 'pos', v_pos); end if;
  if v_credit > 0 then insert into public.sale_payments(sale_id, business_id, method, amount) values (v_id, p_business, 'veresiye', v_credit); end if;
  perform app.post_cash(p_business, v_sess.id, 'satis', v_cash, 'sale', v_id);

  update public.sales set deposit_total = v_dep_total, grand_total = v_grand,
         cash_given = v_given, change_given = case when v_given is not null then v_given - v_cash end,
         limit_override = v_limit_override, offline_limit_exceeded = v_offline_limit
   where id = v_id;

  perform app.audit(p_business, case when v_limit_override then 'satis_limit_asimi' else 'satis' end,
                    'sales', v_id::text, null,
                    jsonb_build_object('no', v_no, 'grand_total', v_grand, 'customer_id', v_cust.id,
                                       'offline', v_offline, 'limit_override', v_limit_override,
                                       'offline_limit_exceeded', v_offline_limit));

  return jsonb_build_object('id', v_id, 'no', v_no, 'grand_total', v_grand, 'goods_net', v_goods_net,
                            'deposit_total', v_dep_total,
                            'change', case when v_given is not null then v_given - v_cash end,
                            'session_id', v_sess.id, 'duplicate', false,
                            'limit_override', v_limit_override, 'offline_limit_exceeded', v_offline_limit);
end $$;

select app.apply_grants();

commit;
begin;

-- ===== 20261001001000_roles.sql =====
-- ALKASU 0010 — Yeni roller: sevkiyat (depo yöneticisi, sipariş teslimi), bayi (kendi siparişleri ve cari hesabı)
-- Enum değerleri ayrı migration'da eklenir: PostgreSQL yeni değerin aynı işlemde kullanılmasına izin vermez.
alter type public.member_role add value if not exists 'sevkiyat';
alter type public.member_role add value if not exists 'bayi';

commit;
begin;

-- ===== 20261001001100_dealers_orders.sql =====
-- ALKASU 0011 — Bayi sistemi, fiyat listeleri, siparişler ve teslimat
-- Kararlar: D-039..D-046 · Kurallar: BUSINESS_RULES §16-18

-- ---------------------------------------------------------------------------
-- 1) Rol kalıtımı: sevkiyat = depo + satış yetkileri (+ sipariş teslimi)
-- ---------------------------------------------------------------------------
create or replace function app.role_covers(p_role public.member_role, p_roles public.member_role[]) returns boolean
language sql immutable as $$
  select p_role = any(p_roles)
      or (p_role = 'sevkiyat' and p_roles && array['depo', 'satis']::public.member_role[])
$$;

create or replace function app.has_role(p_business uuid, variadic p_roles public.member_role[]) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(app.role_covers(app.role_in(p_business), p_roles), false)
$$;

create or replace function app.require_role(p_business uuid, variadic p_roles public.member_role[])
returns public.member_role
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r public.member_role;
begin
  if auth.uid() is null then
    raise exception 'Oturum açmanız gerekiyor' using errcode = '28000';
  end if;
  r := app.role_in(p_business);
  if r is null or not app.role_covers(r, p_roles) then
    raise exception 'Bu işlem için yetkiniz yok' using errcode = '42501';
  end if;
  return r;
end $$;

-- ---------------------------------------------------------------------------
-- 2) Üyelik: bayi kullanıcısının bağlı olduğu müşteri, ilk girişte şifre değiştirme
-- ---------------------------------------------------------------------------
alter table public.memberships add column if not exists customer_id uuid references public.customers(id);
alter table public.memberships add column if not exists must_change_password boolean not null default false;
alter table public.memberships add column if not exists username text;
alter table public.memberships add constraint memberships_bayi_customer
  check (role <> 'bayi' or customer_id is not null) not valid;

create or replace function app.my_customer(p_business uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select m.customer_id from public.memberships m
   where m.business_id = p_business and m.user_id = auth.uid() and m.active and m.role = 'bayi'
$$;

-- ---------------------------------------------------------------------------
-- 3) Müşteri kanalı ve fiyat listesi
-- ---------------------------------------------------------------------------
alter table public.customers add column if not exists channel text not null default 'perakende'
  check (channel in ('perakende', 'kurumsal', 'bayi'));
alter table public.customers add column if not exists price_list text not null default 'perakende'
  check (price_list in ('perakende', 'bayi', 'palet'));
alter table public.customers add column if not exists regions text;
alter table public.customers add column if not exists default_assignee uuid;

-- Liste fiyatları (perakende fiyat product_units.price'ta kalır)
create table public.product_list_prices (
  unit_id      uuid not null references public.product_units(id),
  business_id  uuid not null references public.businesses(id),
  price_list   text not null check (price_list in ('bayi', 'palet')),
  price        numeric(14,2) not null check (price >= 0),
  updated_at   timestamptz not null default now(),
  primary key (unit_id, price_list)
);
alter table public.product_list_prices enable row level security;
create policy list_prices_select on public.product_list_prices for select to authenticated using (app.is_member(business_id));
create trigger list_prices_audit after insert or update on public.product_list_prices for each row execute function audit.tg_row();

alter table public.product_prices add column if not exists price_list text not null default 'perakende';
drop index if exists product_prices_unit;
create index product_prices_unit on public.product_prices(unit_id, price_list, valid_from desc);

-- Listeye göre güncel fiyat: liste fiyatı yoksa perakende
create or replace function app.unit_list_price(p_unit uuid, p_list text) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select case when coalesce(p_list, 'perakende') = 'perakende' then u.price
              else coalesce((select lp.price from public.product_list_prices lp
                              where lp.unit_id = u.id and lp.price_list = p_list), u.price) end
    from public.product_units u where u.id = p_unit
$$;

-- Perakende fiyat geçmişi: liste fiyatları aynı tabloda tutulduğundan filtrelenir
create or replace function app.unit_price_at(p_unit uuid, p_at timestamptz) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select price from public.product_prices
  where unit_id = p_unit and price_list = 'perakende' and valid_from <= p_at
  order by valid_from desc, id desc limit 1
$$;

-- Belirli andaki liste fiyatı (çevrimdışı doğrulama); listede kayıt yoksa perakende
create or replace function app.unit_price_at(p_unit uuid, p_at timestamptz, p_list text) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(
    (select price from public.product_prices where unit_id = p_unit and price_list = coalesce(p_list, 'perakende')
       and valid_from <= p_at order by valid_from desc, id desc limit 1),
    app.unit_price_at(p_unit, p_at))
$$;

create or replace function public.set_list_price(p_unit uuid, p_list text, p_price numeric) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bid uuid; v_old numeric;
begin
  select business_id into v_bid from public.product_units where id = p_unit;
  if v_bid is null then raise exception 'Birim bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(v_bid, 'yonetici');
  if p_list = 'perakende' then perform public.set_unit_price(p_unit, p_price); return; end if;
  if p_list not in ('bayi', 'palet') then raise exception 'Fiyat listesi geçersiz' using errcode = '22023'; end if;
  if p_price is not null and p_price < 0 then raise exception 'Fiyat negatif olamaz' using errcode = '22023'; end if;
  select price into v_old from public.product_list_prices where unit_id = p_unit and price_list = p_list;
  if p_price is null then
    delete from public.product_list_prices where unit_id = p_unit and price_list = p_list;
  else
    insert into public.product_list_prices(unit_id, business_id, price_list, price)
    values (p_unit, v_bid, p_list, round(p_price, 2))
    on conflict (unit_id, price_list) do update set price = excluded.price, updated_at = now();
  end if;
  if v_old is distinct from round(p_price, 2) then
    insert into public.product_prices(business_id, unit_id, price, created_by, source, price_list)
    values (v_bid, p_unit, round(p_price, 2), auth.uid(), 'manuel', p_list);
  end if;
end $$;

-- Fiyat listesi içe aktarma: rows = [{row, urun_kodu, birim?, perakende_fiyati?, bayi_fiyati?, palet_fiyati?}]
-- birim boşsa ürünün satışta kullanılan birimi (fiyatı olan en büyük birim)
create or replace function public.import_prices(p_business uuid, p_rows jsonb, p_dry_run boolean default true) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r jsonb; v_errs jsonb := '[]'; v_unit uuid; v_n int := 0; f text; v_row int;
begin
  perform app.require_role(p_business, 'yonetici');
  for r in select * from jsonb_array_elements(p_rows) loop
    v_row := coalesce((r->>'row')::int, 0);
    select u.id into v_unit from public.product_units u join public.products p on p.id = u.product_id
     where p.business_id = p_business and lower(p.code) = lower(trim(r->>'urun_kodu')) and u.active
       and (case when app.blank(r->>'birim') then u.price is not null else lower(u.name) = lower(trim(r->>'birim')) end)
     order by u.factor desc limit 1;
    if v_unit is null then
      v_errs := v_errs || jsonb_build_object('row', v_row, 'field', 'urun_kodu', 'message', 'Ürün veya birim bulunamadı: ' || coalesce(r->>'urun_kodu', '') || ' ' || coalesce(r->>'birim', ''));
      continue;
    end if;
    foreach f in array array['perakende_fiyati', 'bayi_fiyati', 'palet_fiyati'] loop
      if not app.blank(r->>f) and coalesce(app.num(r->>f), -1) < 0 then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'field', f, 'message', 'Geçerli bir tutar değil');
      end if;
    end loop;
    if not p_dry_run and jsonb_array_length(v_errs) = 0 then
      if not app.blank(r->>'perakende_fiyati') then perform public.set_list_price(v_unit, 'perakende', app.num(r->>'perakende_fiyati')); end if;
      if not app.blank(r->>'bayi_fiyati') then perform public.set_list_price(v_unit, 'bayi', app.num(r->>'bayi_fiyati')); end if;
      if not app.blank(r->>'palet_fiyati') then perform public.set_list_price(v_unit, 'palet', app.num(r->>'palet_fiyati')); end if;
    end if;
    v_n := v_n + 1;
  end loop;
  if jsonb_array_length(v_errs) > 0 and not p_dry_run then
    raise exception 'Fiyat listesinde hata var: %', v_errs using errcode = '22023';
  end if;
  return jsonb_build_object('ok', jsonb_array_length(v_errs) = 0, 'applied', not p_dry_run, 'errors', v_errs,
                            'warnings', '[]'::jsonb, 'summary', jsonb_build_object('rows', v_n));
end $$;

-- ---------------------------------------------------------------------------
-- 4) RLS: yeni roller
-- ---------------------------------------------------------------------------
drop policy if exists customers_select on public.customers;
create policy customers_select on public.customers for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis') or id = app.my_customer(business_id));
drop policy if exists customer_ledger_select on public.customer_ledger;
create policy customer_ledger_select on public.customer_ledger for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis') or customer_id = app.my_customer(business_id));
drop policy if exists container_ledger_select on public.container_ledger;
create policy container_ledger_select on public.container_ledger for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis') or customer_id = app.my_customer(business_id));
drop policy if exists customer_payments_select on public.customer_payments;
create policy customer_payments_select on public.customer_payments for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis') or customer_id = app.my_customer(business_id));

create or replace function app.can_see_sale(p_sale uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.sales s where s.id = p_sale
      and (app.is_admin(s.business_id)
           or (app.has_role(s.business_id, 'satis') and s.created_by = auth.uid())
           or (s.customer_id is not null and s.customer_id = app.my_customer(s.business_id)))
  )
$$;
drop policy if exists sales_select on public.sales;
create policy sales_select on public.sales for select to authenticated
  using (app.is_admin(business_id)
         or (app.has_role(business_id, 'satis') and created_by = auth.uid())
         or (customer_id is not null and customer_id = app.my_customer(business_id)));

-- Kullanıcı listesi: sipariş ataması için isimler (yönetici tümünü zaten görür)
create or replace function public.assignable_users(p_business uuid)
returns table(user_id uuid, display_name text, role public.member_role)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  perform app.require_role(p_business, 'yonetici', 'satis', 'depo', 'bayi');
  return query select m.user_id, m.display_name, m.role from public.memberships m
   where m.business_id = p_business and m.active and m.role in ('yonetici', 'satis', 'sevkiyat')
   order by m.display_name;
end $$;

-- ---------------------------------------------------------------------------
-- 5) Satış çekirdeği: liste fiyatı doğrulaması ve teslimat (güvenilir fiyat) desteği
-- ---------------------------------------------------------------------------
create or replace function app.complete_sale_core(p_business uuid, p jsonb, p_role public.member_role,
                                              p_trusted boolean default false) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role    public.member_role := p_role;          -- çağıran fonksiyon yetkiyi doğrular
  v_list    text := 'perakende';
  v_cur     numeric;
  v_id      uuid := (p->>'id')::uuid;
  v_loc     uuid := coalesce(nullif(p->>'location_id', '')::uuid, app.default_location(p_business));
  v_set     public.app_settings;
  v_sess    public.cash_sessions;
  v_cust    public.customers;
  v_offline boolean := coalesce((p->>'offline')::boolean, false);
  v_client  timestamptz := coalesce(nullif(p->>'client_created_at', '')::timestamptz, now());
  v_sold_at timestamptz;
  v_no      bigint;
  it        jsonb;
  pr        public.products;
  u         public.product_units;
  v_line    int := 0;
  v_qty     int;
  v_price   numeric;
  v_ldisc   numeric;
  v_gross   numeric := 0;
  v_ldisc_total numeric := 0;
  v_bill    numeric := coalesce(nullif(p->>'bill_discount', '')::numeric, 0);
  v_net_before_bill numeric;
  v_share   numeric;
  v_share_left numeric;
  v_goods_net numeric := 0;
  v_dep_total numeric := 0;
  v_grand   numeric;
  v_pay_total numeric := 0;
  v_cash    numeric := 0; v_pos numeric := 0; v_credit numeric := 0;
  v_given   numeric := nullif(p->>'cash_given', '')::numeric;
  v_balance numeric;
  v_limit_override boolean := false;
  v_offline_limit boolean := false;
  d         record;
  v_ret     int;
  v_cb      record;
  v_amt     numeric;
  rec       record;
  v_item_id uuid;
begin
  if v_id is null then raise exception 'Satış kimliği eksik' using errcode = '22023'; end if;

  -- S-02: aynı kimlikle tekrar gönderim
  if exists (select 1 from public.sales where id = v_id) then
    return (select jsonb_build_object('id', s.id, 'no', s.no, 'grand_total', s.grand_total,
                                      'change', s.change_given, 'duplicate', true)
              from public.sales s where s.id = v_id and s.business_id = p_business);
  end if;

  select * into v_set from public.app_settings where business_id = p_business;
  if jsonb_array_length(coalesce(p->'items', '[]')) = 0 then
    raise exception 'Sepet boş' using errcode = '22023';
  end if;
  if v_bill < 0 then raise exception 'İndirim negatif olamaz' using errcode = '22023'; end if;

  if nullif(p->>'customer_id', '') is not null then
    select * into v_cust from public.customers where id = (p->>'customer_id')::uuid and business_id = p_business;
    if v_cust.id is null then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
    if not v_cust.active then raise exception 'Müşteri pasif durumda' using errcode = 'P0001'; end if;
    v_list := coalesce(v_cust.price_list, 'perakende');   -- F-10: müşterinin fiyat listesi
  end if;

  v_sess := app.ensure_session(p_business, v_loc);
  v_sold_at := case when v_offline then least(v_client, now()) else now() end;
  v_no := app.next_number(p_business, 'satis');

  if to_regclass('pg_temp._sale_lines') is null then
  create temp table _sale_lines (
    line_no int, product_id uuid, unit_id uuid, unit_name text, factor int, qty int, base_qty int,
    unit_price numeric, line_gross numeric, line_discount numeric, share numeric default 0,
    line_net numeric, vat_rate smallint, deposit_amount numeric, empty_product_id uuid
  ) on commit drop;
  end if;
  truncate _sale_lines;

  -- 1) Kalemleri doğrula
  for it in select * from jsonb_array_elements(p->'items') loop
    v_line := v_line + 1;
    pr := app.product_in_business(p_business, (it->>'product_id')::uuid);
    if not pr.active then raise exception 'Pasif ürün satılamaz: % (S-06)', pr.name using errcode = 'P0001'; end if;
    if pr.is_container then raise exception 'Boş kap ürünü satılamaz: %', pr.name using errcode = 'P0001'; end if;
    select * into u from public.product_units where id = (it->>'unit_id')::uuid and product_id = pr.id;
    if u.id is null then raise exception 'Ürün birimi geçersiz: %', pr.name using errcode = '22023'; end if;
    if not u.active and not v_offline then raise exception 'Bu birim artık kullanılmıyor: % %', pr.name, u.name using errcode = 'P0001'; end if;

    v_qty   := (it->>'qty')::int;
    v_price := round((it->>'unit_price')::numeric, 2);
    v_ldisc := round(coalesce(nullif(it->>'line_discount', '')::numeric, 0), 2);
    if v_qty is null or v_qty <= 0 then raise exception 'Miktar geçersiz: %', pr.name using errcode = '22023'; end if;
    if v_price is null or v_price < 0 then raise exception 'Fiyat geçersiz: %', pr.name using errcode = '22023'; end if;

    if v_role <> 'yonetici' and not p_trusted then
      -- Satış personeli fiyatı değiştiremez; müşterinin fiyat listesi geçerlidir (F-10).
      -- Çevrimdışında satış anındaki fiyat da kabul edilir (C-02)
      v_cur := app.unit_list_price(u.id, v_list);
      if v_cur is null and app.unit_price_at(u.id, v_client, v_list) is null then
        raise exception 'Bu birim için satış fiyatı tanımlı değil: % %', pr.name, u.name using errcode = 'P0001';
      end if;
      if v_price is distinct from v_cur
         and not (v_offline and v_price = app.unit_price_at(u.id, v_client, v_list)) then
        raise exception 'Fiyat güncel değil: % % (güncel: %)', pr.name, u.name, v_cur using errcode = 'P0001';
      end if;
      if v_price = 0 then raise exception 'Sıfır fiyatlı satışı yalnızca yönetici yapabilir (F-07)' using errcode = '42501'; end if;
    end if;

    if v_ldisc < 0 or v_ldisc > round(v_qty * v_price, 2) then
      raise exception 'Satır indirimi geçersiz: %', pr.name using errcode = '22023';
    end if;

    insert into _sale_lines values (v_line, pr.id, u.id, u.name, u.factor, v_qty, v_qty * u.factor, v_price,
      round(v_qty * v_price, 2), v_ldisc, 0, null, pr.vat_rate, pr.deposit_amount, pr.empty_product_id);
    v_gross := v_gross + round(v_qty * v_price, 2);
    v_ldisc_total := v_ldisc_total + v_ldisc;
  end loop;

  -- 2) Fiş indirimini satırlara dağıt (F-05)
  v_net_before_bill := v_gross - v_ldisc_total;
  if v_bill > v_net_before_bill then raise exception 'Fiş indirimi tutarı aşıyor' using errcode = '22023'; end if;
  if v_bill > 0 then
    v_share_left := v_bill;
    for rec in select line_no, line_gross - line_discount as net from _sale_lines order by line_no loop
      if rec.line_no = v_line then
        v_share := v_share_left;
      else
        v_share := round(v_bill * rec.net / v_net_before_bill, 2);
        v_share_left := v_share_left - v_share;
      end if;
      update _sale_lines set share = v_share where line_no = rec.line_no;
    end loop;
  end if;
  update _sale_lines set line_net = line_gross - line_discount - share where true;  -- pg_safeupdate: WHERE zorunlu
  select coalesce(sum(line_net), 0) into v_goods_net from _sale_lines;

  -- F-06: indirim limiti
  if v_role <> 'yonetici' and not p_trusted and (v_ldisc_total + v_bill) > round(v_gross * v_set.max_discount_pct_satis / 100, 2) then
    raise exception 'İndirim limitinizi aşıyor (en fazla %%%). Yönetici onayı gerekir (F-06)',
      v_set.max_discount_pct_satis using errcode = '42501';
  end if;

  -- 3) Satış kaydı
  insert into public.sales(id, business_id, location_id, no, session_id, customer_id, goods_gross, discount_total,
                           goods_net, deposit_total, grand_total, sold_at, created_by, offline, late_sync, note)
  values (v_id, p_business, v_loc, v_no, v_sess.id, v_cust.id, v_gross, v_ldisc_total + v_bill,
          v_goods_net, 0, v_goods_net, v_sold_at, auth.uid(), v_offline,
          v_offline and v_client < v_sess.opened_at, nullif(trim(p->>'note'), ''));

  for rec in select l.*, coalesce(pc.avg_cost, 0) as avg_cost, coalesce(pc.has_cost, false) as has_cost
               from _sale_lines l left join public.product_costs pc on pc.product_id = l.product_id
              order by l.line_no loop
    insert into public.sale_items(sale_id, business_id, line_no, product_id, unit_id, unit_name, factor, qty, base_qty,
                                  unit_price, line_gross, line_discount, bill_discount_share, line_net, vat_rate)
    values (v_id, p_business, rec.line_no, rec.product_id, rec.unit_id, rec.unit_name, rec.factor, rec.qty, rec.base_qty,
            rec.unit_price, rec.line_gross, rec.line_discount, rec.share, rec.line_net, rec.vat_rate)
    returning id into v_item_id;
    insert into public.sale_item_costs(sale_item_id, business_id, unit_cost, total_cost, has_cost)
    values (v_item_id, p_business, rec.avg_cost, round(rec.avg_cost * rec.base_qty, 2), rec.has_cost);
  end loop;

  -- 4) Stok hareketleri (ürün sırasıyla: kilit sırası sabit, T-008)
  for rec in select product_id, sum(base_qty)::int as q from _sale_lines group by product_id order by product_id loop
    perform app.post_stock(p_business, v_loc, rec.product_id, -rec.q, 'satis', 'sale', v_id);
  end loop;

  -- 5) Depozito ve boş kap (D-03..D-06)
  for d in select product_id, sum(base_qty)::int as sold, max(deposit_amount) as dep, max(empty_product_id::text)::uuid as empty_id
             from _sale_lines where deposit_amount is not null group by product_id order by product_id loop
    select coalesce(max((x->>'empty_returned')::int), d.sold) into v_ret
      from jsonb_array_elements(coalesce(p->'deposits', '[]')) x where (x->>'product_id')::uuid = d.product_id;
    v_ret := coalesce(v_ret, d.sold);
    if v_ret < 0 then raise exception 'Boş kap sayısı geçersiz' using errcode = '22023'; end if;

    if d.sold - v_ret > 0 then
      v_amt := (d.sold - v_ret) * d.dep;                     -- müşteriden depozito alınır
    elsif d.sold - v_ret < 0 then
      v_amt := -app.deposit_refund_amount(p_business, v_cust.id, d.product_id, v_ret - d.sold);  -- fazla boş: depozito iadesi
    else
      v_amt := 0;
    end if;

    insert into public.sale_deposits(sale_id, business_id, product_id, sold_qty, empty_returned, net_containers, amount)
    values (v_id, p_business, d.product_id, d.sold, v_ret, d.sold - v_ret, v_amt);
    if d.sold - v_ret <> 0 then
      insert into public.container_ledger(business_id, customer_id, product_id, qty, amount, type, ref_type, ref_id, created_by)
      values (p_business, v_cust.id, d.product_id, d.sold - v_ret, v_amt, 'satis', 'sale', v_id, auth.uid());
    end if;
    if v_ret > 0 then
      perform app.post_stock(p_business, v_loc, d.empty_id, v_ret, 'bos_kap_giris', 'sale', v_id);
    end if;
    v_dep_total := v_dep_total + v_amt;
  end loop;
  -- Satılmayan ürün için gönderilmiş depozito satırı kabul edilmez
  if exists (select 1 from jsonb_array_elements(coalesce(p->'deposits', '[]')) x
              where not exists (select 1 from _sale_lines l where l.product_id = (x->>'product_id')::uuid
                                  and l.deposit_amount is not null)) then
    raise exception 'Boş kap bilgisi yalnızca satılan depozitolu ürünler için girilebilir' using errcode = '22023';
  end if;

  v_grand := v_goods_net + v_dep_total;
  if v_grand < 0 then
    raise exception 'Fiş toplamı negatif olamaz; fazla boş kap için "Depozito iadesi" işlemini kullanın' using errcode = '22023';
  end if;

  -- 6) Ödemeler (S-03)
  for it in select * from jsonb_array_elements(coalesce(p->'payments', '[]')) loop
    v_amt := round((it->>'amount')::numeric, 2);
    if v_amt is null or v_amt <= 0 then raise exception 'Ödeme tutarı geçersiz' using errcode = '22023'; end if;
    case it->>'method'
      when 'nakit' then v_cash := v_cash + v_amt;
      when 'pos' then v_pos := v_pos + v_amt;
      when 'veresiye' then v_credit := v_credit + v_amt;
      else raise exception 'Ödeme şekli geçersiz: %', it->>'method' using errcode = '22023';
    end case;
  end loop;
  v_pay_total := v_cash + v_pos + v_credit;
  if v_pay_total <> v_grand then
    raise exception 'Ödemeler toplamı (%) fiş toplamına (%) eşit değil (S-03)', v_pay_total, v_grand using errcode = '22023';
  end if;
  if v_given is not null and v_given < v_cash then
    raise exception 'Alınan nakit, nakit ödeme tutarından az olamaz' using errcode = '22023';
  end if;

  -- V-01..V-02: veresiye
  if v_credit > 0 then
    if v_cust.id is null then raise exception 'Veresiye için müşteri seçilmelidir (V-01)' using errcode = '22023'; end if;
    perform 1 from public.customers where id = v_cust.id for update;   -- aynı müşteriye eşzamanlı veresiye
    v_balance := app.customer_balance(v_cust.id);
    if not v_cust.unlimited_credit and v_balance + v_credit > v_cust.credit_limit then
      if v_offline or p_trusted then
        v_offline_limit := true;                    -- C-03 / teslimat: satış kaydedilir, yöneticiye uyarı
      elsif coalesce((p->>'limit_override')::boolean, false) and v_role = 'yonetici' then
        v_limit_override := true;
      else
        raise exception 'Veresiye limiti aşılıyor. Bakiye: %, limit: %, bu satış: % (V-02)',
          v_balance, v_cust.credit_limit, v_credit using errcode = 'P0001';
      end if;
    end if;
    insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, ref_id, created_by)
    values (p_business, v_cust.id, 'satis', v_credit, 'sale', v_id, auth.uid());
  end if;

  if v_cash > 0 then insert into public.sale_payments(sale_id, business_id, method, amount) values (v_id, p_business, 'nakit', v_cash); end if;
  if v_pos > 0 then insert into public.sale_payments(sale_id, business_id, method, amount) values (v_id, p_business, 'pos', v_pos); end if;
  if v_credit > 0 then insert into public.sale_payments(sale_id, business_id, method, amount) values (v_id, p_business, 'veresiye', v_credit); end if;
  perform app.post_cash(p_business, v_sess.id, 'satis', v_cash, 'sale', v_id);

  update public.sales set deposit_total = v_dep_total, grand_total = v_grand,
         cash_given = v_given, change_given = case when v_given is not null then v_given - v_cash end,
         limit_override = v_limit_override, offline_limit_exceeded = v_offline_limit
   where id = v_id;

  perform app.audit(p_business, case when v_limit_override then 'satis_limit_asimi' else 'satis' end,
                    'sales', v_id::text, null,
                    jsonb_build_object('no', v_no, 'grand_total', v_grand, 'customer_id', v_cust.id,
                                       'offline', v_offline, 'limit_override', v_limit_override,
                                       'offline_limit_exceeded', v_offline_limit));

  return jsonb_build_object('id', v_id, 'no', v_no, 'grand_total', v_grand, 'goods_net', v_goods_net,
                            'deposit_total', v_dep_total,
                            'change', case when v_given is not null then v_given - v_cash end,
                            'session_id', v_sess.id, 'duplicate', false,
                            'limit_override', v_limit_override, 'offline_limit_exceeded', v_offline_limit);
end $$;

create or replace function public.complete_sale(p_business uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_role public.member_role := app.require_role(p_business, 'yonetici', 'satis');
begin
  return app.complete_sale_core(p_business, p, v_role, false);
end $$;

-- ---------------------------------------------------------------------------
-- 6) Siparişler
-- ---------------------------------------------------------------------------
create table public.orders (
  id             uuid primary key,
  business_id    uuid not null references public.businesses(id),
  no             bigint not null,
  customer_id    uuid not null references public.customers(id),
  delivery_date  date not null default app.local_date(now()),
  assignee       uuid,                                  -- teslim edecek kullanıcı (auth user)
  status         text not null default 'acik' check (status in ('acik', 'teslim_edildi', 'iptal')),
  address        text,
  note           text,
  price_list     text not null default 'perakende',
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  delivered_by   uuid,
  delivered_at   timestamptz,
  sale_id        uuid references public.sales(id),
  cancelled_by   uuid,
  cancelled_at   timestamptz,
  cancel_reason  text,
  unique (business_id, no)
);
create index orders_business_date on public.orders(business_id, delivery_date, status);
create index orders_assignee on public.orders(assignee) where status = 'acik';
create index orders_customer on public.orders(customer_id);

create table public.order_items (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references public.orders(id),
  business_id uuid not null references public.businesses(id),
  line_no     smallint not null,
  product_id  uuid not null references public.products(id),
  unit_id     uuid not null references public.product_units(id),
  qty         integer not null check (qty > 0),
  unit_price  numeric(14,2) not null check (unit_price >= 0)
);
create index order_items_order on public.order_items(order_id);

create trigger orders_touch before update on public.orders for each row execute function app.touch_updated_at();
create trigger orders_audit after insert or update on public.orders for each row execute function audit.tg_row();

alter table public.orders enable row level security;
alter table public.order_items enable row level security;
create policy orders_select on public.orders for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis') or customer_id = app.my_customer(business_id));
create policy order_items_select on public.order_items for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id
                  and (app.has_role(o.business_id, 'yonetici', 'satis') or o.customer_id = app.my_customer(o.business_id))));

-- Sipariş oluştur / güncelle (yalnızca açık sipariş)
-- p = { id, customer_id, delivery_date?, assignee?, address?, note?, items: [{product_id, unit_id, qty, unit_price?}] }
create or replace function public.save_order(p_business uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role  public.member_role := app.require_role(p_business, 'yonetici', 'satis', 'bayi');
  v_id    uuid := (p->>'id')::uuid;
  o       public.orders;
  c       public.customers;
  it      jsonb;
  pr      public.products;
  u       public.product_units;
  v_price numeric;
  v_line  int := 0;
  v_assignee uuid := nullif(p->>'assignee', '')::uuid;
begin
  if v_id is null then raise exception 'Sipariş kimliği eksik' using errcode = '22023'; end if;
  select * into c from public.customers where id = (case when v_role = 'bayi' then app.my_customer(p_business)
                                                         else nullif(p->>'customer_id', '')::uuid end)
                                          and business_id = p_business;
  if c.id is null then raise exception 'Müşteri seçilmelidir' using errcode = '22023'; end if;
  if not c.active then raise exception 'Müşteri pasif durumda' using errcode = 'P0001'; end if;
  if jsonb_array_length(coalesce(p->'items', '[]')) = 0 then raise exception 'Siparişte ürün yok' using errcode = '22023'; end if;
  if v_assignee is not null and not exists (select 1 from public.memberships where business_id = p_business
                                              and user_id = v_assignee and active and role in ('yonetici', 'satis', 'sevkiyat')) then
    raise exception 'Atanan kişi geçersiz' using errcode = '22023';
  end if;
  if v_role = 'bayi' then v_assignee := null; end if;   -- bayi siparişini yönetici/sevkiyat atar

  select * into o from public.orders where id = v_id for update;
  if o.id is null then
    insert into public.orders(id, business_id, no, customer_id, delivery_date, assignee, address, note, price_list, created_by)
    values (v_id, p_business, app.next_number(p_business, 'siparis'), c.id,
            coalesce(nullif(p->>'delivery_date', '')::date, app.local_date(now())),
            coalesce(v_assignee, c.default_assignee),
            coalesce(nullif(trim(p->>'address'), ''), c.address), nullif(trim(p->>'note'), ''), c.price_list, auth.uid())
    returning * into o;
  else
    if o.business_id <> p_business then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
    if o.status <> 'acik' then raise exception 'Kapanmış sipariş değiştirilemez' using errcode = 'P0001'; end if;
    if v_role = 'bayi' and o.customer_id <> c.id then raise exception 'Bu sipariş size ait değil' using errcode = '42501'; end if;
    update public.orders set customer_id = c.id, price_list = c.price_list,
      delivery_date = coalesce(nullif(p->>'delivery_date', '')::date, delivery_date),
      assignee = case when v_role = 'bayi' then assignee else v_assignee end,
      address = nullif(trim(p->>'address'), ''), note = nullif(trim(p->>'note'), '')
     where id = v_id returning * into o;
    delete from public.order_items where order_id = v_id;
  end if;

  for it in select * from jsonb_array_elements(p->'items') loop
    v_line := v_line + 1;
    pr := app.product_in_business(p_business, (it->>'product_id')::uuid);
    if not pr.active or pr.is_container then raise exception 'Bu ürün siparişe eklenemez: %', pr.name using errcode = 'P0001'; end if;
    select * into u from public.product_units where id = (it->>'unit_id')::uuid and product_id = pr.id and active;
    if u.id is null then raise exception 'Ürün birimi geçersiz: %', pr.name using errcode = '22023'; end if;
    if coalesce((it->>'qty')::int, 0) <= 0 then raise exception 'Miktar geçersiz: %', pr.name using errcode = '22023'; end if;
    v_price := case when v_role = 'yonetici' and nullif(it->>'unit_price', '') is not null
                    then round((it->>'unit_price')::numeric, 2)
                    else app.unit_list_price(u.id, c.price_list) end;
    if v_price is null then raise exception 'Bu birimin fiyatı tanımlı değil: % %', pr.name, u.name using errcode = 'P0001'; end if;
    insert into public.order_items(order_id, business_id, line_no, product_id, unit_id, qty, unit_price)
    values (v_id, p_business, v_line, pr.id, u.id, (it->>'qty')::int, v_price);
  end loop;

  return jsonb_build_object('id', o.id, 'no', o.no, 'status', o.status);
end $$;

create or replace function public.assign_order(p_order uuid, p_assignee uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders;
begin
  select * into o from public.orders where id = p_order for update;
  if o.id is null then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(o.business_id, 'yonetici', 'satis');
  if o.status <> 'acik' then raise exception 'Kapanmış sipariş değiştirilemez' using errcode = 'P0001'; end if;
  if p_assignee is not null and not exists (select 1 from public.memberships where business_id = o.business_id
                                             and user_id = p_assignee and active and role in ('yonetici', 'satis', 'sevkiyat')) then
    raise exception 'Atanan kişi geçersiz' using errcode = '22023';
  end if;
  update public.orders set assignee = p_assignee where id = p_order;
end $$;

create or replace function public.cancel_order(p_order uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders; v_role public.member_role;
begin
  select * into o from public.orders where id = p_order for update;
  if o.id is null then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
  v_role := app.require_role(o.business_id, 'yonetici', 'satis', 'bayi');
  if v_role = 'bayi' and o.customer_id is distinct from app.my_customer(o.business_id) then
    raise exception 'Bu sipariş size ait değil' using errcode = '42501';
  end if;
  if o.status <> 'acik' then raise exception 'Sipariş zaten kapanmış' using errcode = 'P0001'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'İptal nedeni zorunludur' using errcode = '22023'; end if;
  update public.orders set status = 'iptal', cancelled_by = auth.uid(), cancelled_at = now(), cancel_reason = trim(p_reason)
   where id = p_order;
end $$;

-- Teslimat: siparişi satışa dönüştürür (D-041). Atanan kişi veya yönetici kapatabilir.
-- p = { order_id, sale_id, items: [{order_item_id, qty}], deposits?: [{product_id, empty_returned}],
--       payments: [{method, amount}], cash_given?, note? }
create or replace function public.deliver_order(p_business uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role public.member_role := app.require_role(p_business, 'yonetici', 'satis');
  o      public.orders;
  v_items jsonb := '[]';
  oi     record;
  v_qty  int;
  v_res  jsonb;
begin
  select * into o from public.orders where id = (p->>'order_id')::uuid and business_id = p_business for update;
  if o.id is null then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
  if o.status = 'teslim_edildi' and o.sale_id = (p->>'sale_id')::uuid then
    return jsonb_build_object('order_id', o.id, 'sale_id', o.sale_id, 'duplicate', true);
  end if;
  if o.status <> 'acik' then raise exception 'Sipariş açık değil' using errcode = 'P0001'; end if;
  if v_role <> 'yonetici' and o.assignee is distinct from auth.uid() then
    raise exception 'Bu siparişi yalnızca atanan kişi veya yönetici kapatabilir' using errcode = '42501';
  end if;

  for oi in select * from public.order_items where order_id = o.id order by line_no loop
    select coalesce(max((x->>'qty')::int), oi.qty) into v_qty
      from jsonb_array_elements(coalesce(p->'items', '[]')) x where (x->>'order_item_id')::uuid = oi.id;
    v_qty := coalesce(v_qty, oi.qty);
    if v_qty < 0 then raise exception 'Teslim miktarı negatif olamaz' using errcode = '22023'; end if;
    if v_qty > 0 then
      v_items := v_items || jsonb_build_object('product_id', oi.product_id, 'unit_id', oi.unit_id, 'qty', v_qty, 'unit_price', oi.unit_price);
    end if;
  end loop;
  if jsonb_array_length(v_items) = 0 then
    raise exception 'Teslim edilen ürün yok; teslim edilmediyse siparişi iptal edin' using errcode = '22023';
  end if;

  v_res := app.complete_sale_core(p_business, jsonb_build_object(
    'id', p->>'sale_id', 'customer_id', o.customer_id, 'items', v_items,
    'deposits', coalesce(p->'deposits', '[]'), 'payments', coalesce(p->'payments', '[]'),
    'cash_given', p->'cash_given', 'note', coalesce(nullif(trim(p->>'note'), ''), 'Sipariş #' || o.no)), v_role, true);

  update public.orders set status = 'teslim_edildi', delivered_by = auth.uid(), delivered_at = now(),
         sale_id = (v_res->>'id')::uuid where id = o.id;
  perform app.audit(p_business, 'siparis_teslim', 'orders', o.id::text, null, v_res);
  return v_res || jsonb_build_object('order_id', o.id, 'order_no', o.no);
end $$;

-- ---------------------------------------------------------------------------
-- 7) Müşteri kartı: kanal, fiyat listesi, bölge, varsayılan sorumlu
-- ---------------------------------------------------------------------------
create or replace function public.upsert_customer(p_business uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role public.member_role := app.require_role(p_business, 'yonetici', 'satis');
  v_id   uuid := nullif(p->>'id', '')::uuid;
  v_code text := nullif(trim(p->>'code'), '');
  v_adm  boolean := v_role = 'yonetici';
begin
  if coalesce(trim(p->>'name'), '') = '' then raise exception 'Müşteri adı zorunludur' using errcode = '22023'; end if;
  if v_code is not null and exists (select 1 from public.customers where business_id = p_business
                                    and lower(code) = lower(v_code) and id is distinct from v_id) then
    raise exception 'Bu müşteri kodu zaten kullanılıyor: %', v_code using errcode = '23505';
  end if;
  if v_id is null then
    if v_code is null then v_code := 'M' || lpad(app.next_number(p_business, 'musteri')::text, 5, '0'); end if;
    insert into public.customers(business_id, code, name, phone, address, tax_no, note, credit_limit, unlimited_credit,
                                 channel, price_list, regions, default_assignee)
    values (p_business, v_code, trim(p->>'name'), nullif(trim(p->>'phone'), ''), nullif(trim(p->>'address'), ''),
            nullif(trim(p->>'tax_no'), ''), nullif(trim(p->>'note'), ''),
            case when v_adm then coalesce(nullif(p->>'credit_limit', '')::numeric, 0) else 0 end,
            case when v_adm then coalesce((p->>'unlimited_credit')::boolean, false) else false end,
            coalesce(nullif(p->>'channel', ''), 'perakende'),
            case when v_adm then coalesce(nullif(p->>'price_list', ''), 'perakende') else 'perakende' end,
            nullif(trim(p->>'regions'), ''), nullif(p->>'default_assignee', '')::uuid)
    returning id into v_id;
  else
    update public.customers set
      code = coalesce(v_code, code), name = trim(p->>'name'),
      phone = nullif(trim(p->>'phone'), ''), address = nullif(trim(p->>'address'), ''),
      tax_no = nullif(trim(p->>'tax_no'), ''), note = nullif(trim(p->>'note'), ''),
      credit_limit = case when v_adm then coalesce(nullif(p->>'credit_limit', '')::numeric, credit_limit) else credit_limit end,
      unlimited_credit = case when v_adm then coalesce((p->>'unlimited_credit')::boolean, unlimited_credit) else unlimited_credit end,
      active = case when v_adm then coalesce((p->>'active')::boolean, active) else active end,
      channel = coalesce(nullif(p->>'channel', ''), channel),
      price_list = case when v_adm then coalesce(nullif(p->>'price_list', ''), price_list) else price_list end,
      regions = case when p ? 'regions' then nullif(trim(p->>'regions'), '') else regions end,
      default_assignee = case when p ? 'default_assignee' then nullif(p->>'default_assignee', '')::uuid else default_assignee end
    where id = v_id and business_id = p_business;
    if not found then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
  end if;
  return v_id;
end $$;

-- Bayi kendi özetini ve ekstresini görebilir
create or replace function app.require_customer_access(p_customer uuid) returns uuid
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_bid uuid;
begin
  select business_id into v_bid from public.customers where id = p_customer;
  if v_bid is null then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
  if not app.has_role(v_bid, 'yonetici', 'satis') and p_customer is distinct from app.my_customer(v_bid) then
    raise exception 'Bu işlem için yetkiniz yok' using errcode = '42501';
  end if;
  return v_bid;
end $$;

create or replace function public.customer_summary(p_customer uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare c public.customers;
begin
  perform app.require_customer_access(p_customer);
  select * into c from public.customers where id = p_customer;
  return jsonb_build_object(
    'id', c.id, 'code', c.code, 'name', c.name, 'phone', c.phone, 'address', c.address,
    'credit_limit', c.credit_limit, 'unlimited_credit', c.unlimited_credit, 'channel', c.channel,
    'price_list', c.price_list, 'regions', c.regions,
    'balance', app.customer_balance(c.id),
    'containers', coalesce((select jsonb_agg(jsonb_build_object('product_id', b.product_id, 'product_name', pr.name,
                                                                'qty', b.qty, 'amount', b.amount))
                              from public.container_balances b join public.products pr on pr.id = b.product_id
                             where b.customer_id = c.id), '[]'::jsonb));
end $$;

create or replace function public.customer_statement(p_customer uuid, p_from date default null, p_to date default null)
returns table(at timestamptz, type text, description text, debit numeric, credit numeric, balance numeric, ref_type text, ref_id uuid)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  perform app.require_customer_access(p_customer);
  return query
  with l as (
    select cl.*, sum(cl.amount) over (order by cl.created_at, cl.id) as running
      from public.customer_ledger cl where cl.customer_id = p_customer)
  select l.created_at, l.type,
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

-- ---------------------------------------------------------------------------
-- 8) Kullanıcı yönetimi: kullanıcı adı, bağlı müşteri (bayi), ilk girişte şifre değiştirme
-- ---------------------------------------------------------------------------
drop function if exists public.add_member(uuid, uuid, public.member_role, text);
create or replace function public.add_member(p_business uuid, p_user uuid, p_role public.member_role, p_name text,
                                             p_customer uuid default null, p_username text default null,
                                             p_must_change boolean default false)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    perform app.require_role(p_business, 'yonetici');
  end if;
  if p_role = 'bayi' and (p_customer is null or not exists (select 1 from public.customers where id = p_customer and business_id = p_business)) then
    raise exception 'Bayi kullanıcısı bir bayi müşteri kartına bağlanmalıdır' using errcode = '22023';
  end if;
  insert into public.memberships(business_id, user_id, role, display_name, customer_id, username, must_change_password)
  values (p_business, p_user, p_role, trim(p_name), case when p_role = 'bayi' then p_customer end,
          nullif(lower(trim(p_username)), ''), p_must_change)
  on conflict (business_id, user_id) do update
    set role = excluded.role, display_name = excluded.display_name, active = true,
        customer_id = excluded.customer_id, username = coalesce(excluded.username, public.memberships.username),
        must_change_password = excluded.must_change_password
  returning id into v_id;
  return v_id;
end $$;

drop function if exists public.update_member(uuid, public.member_role, text, boolean);
create or replace function public.update_member(p_membership uuid, p_role public.member_role, p_name text, p_active boolean,
                                                p_customer uuid default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bid uuid;
begin
  select business_id into v_bid from public.memberships where id = p_membership;
  if v_bid is null then raise exception 'Kullanıcı bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(v_bid, 'yonetici');
  if p_role = 'bayi' and p_customer is null then
    select customer_id into p_customer from public.memberships where id = p_membership;
    if p_customer is null then raise exception 'Bayi kullanıcısı bir bayi müşteri kartına bağlanmalıdır' using errcode = '22023'; end if;
  end if;
  update public.memberships set role = p_role, display_name = trim(p_name), active = p_active,
         customer_id = case when p_role = 'bayi' then p_customer end
   where id = p_membership;
end $$;

-- Şifre değiştirildi (ilk giriş zorunluluğunu kaldırır)
create or replace function public.password_changed() returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.memberships set must_change_password = false where user_id = auth.uid() and must_change_password;
$$;

-- Yönetici bir kullanıcıya yeni geçici şifre verdiğinde (şifreyi sunucu service_role ile ayarlar)
create or replace function public.require_password_change(p_membership uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bid uuid;
begin
  select business_id into v_bid from public.memberships where id = p_membership;
  if v_bid is null then raise exception 'Kullanıcı bulunamadı' using errcode = 'P0002'; end if;
  if coalesce(auth.role(), '') <> 'service_role' then perform app.require_role(v_bid, 'yonetici'); end if;
  update public.memberships set must_change_password = true where id = p_membership;
end $$;

create or replace function public.my_context() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'business_id', b.id, 'business_name', b.name,
    'location_id', app.default_location(b.id),
    'membership_id', m.id, 'role', m.role, 'display_name', m.display_name,
    'customer_id', m.customer_id, 'must_change_password', m.must_change_password
  ) order by b.name), '[]'::jsonb)
  from public.memberships m join public.businesses b on b.id = m.business_id
  where m.user_id = auth.uid() and m.active
$$;

-- ---------------------------------------------------------------------------
-- 9) Ana sayfa özeti: yeni roller
-- ---------------------------------------------------------------------------
create or replace function public.dashboard(p_business uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_role public.member_role; v_today date := app.local_date(now()); d record; v jsonb; v_cust uuid;
begin
  v_role := app.require_role(p_business, 'yonetici', 'satis', 'depo', 'izleyici', 'bayi');
  v := jsonb_build_object('role', v_role, 'today', v_today);
  if v_role = 'bayi' then
    v_cust := app.my_customer(p_business);
    return v || jsonb_build_object(
      'balance', app.customer_balance(v_cust),
      'open_orders', (select count(*) from public.orders where customer_id = v_cust and status = 'acik'),
      'containers', (select coalesce(sum(qty), 0) from public.container_balances where customer_id = v_cust));
  end if;
  v := v || jsonb_build_object(
    'critical_count', (select count(*) from public.report_stock(p_business) s where s.status = 'kritik' and not s.is_container),
    'negative_count', (select count(*) from public.report_stock(p_business) s where s.status = 'negatif'),
    'orders_today', (select count(*) from public.orders where business_id = p_business and status = 'acik' and delivery_date <= v_today),
    'my_open_orders', (select count(*) from public.orders where business_id = p_business and status = 'acik' and assignee = auth.uid()));
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
      'unassigned_orders', (select count(*) from public.orders where business_id = p_business and status = 'acik' and assignee is null),
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
end $$;

-- ---------------------------------------------------------------------------
-- 10) Yetki listesi: RLS politikalarında kullanılan yeni yardımcılar
-- ---------------------------------------------------------------------------
create or replace function app.apply_grants() returns void
language plpgsql as $$
declare f text;
begin
  execute 'revoke all on all tables in schema public from anon, authenticated';
  execute 'grant select on all tables in schema public to authenticated';
  execute 'revoke all on all sequences in schema public from anon, authenticated';
  execute 'revoke execute on all functions in schema public from public, anon';
  execute 'grant execute on all functions in schema public to authenticated, service_role';
  execute 'revoke all on all tables in schema audit from anon, authenticated';
  execute 'grant usage on schema audit to authenticated';
  execute 'grant select on audit.log to authenticated';
  execute 'revoke execute on all functions in schema app from public, anon, authenticated';
  foreach f in array array['app.uid()', 'app.role_in(uuid)', 'app.is_member(uuid)',
                           'app.has_role(uuid, public.member_role[])', 'app.is_admin(uuid)',
                           'app.local_date(timestamptz)', 'app.can_see_sale(uuid)', 'app.my_customer(uuid)',
                           'app.role_covers(public.member_role, public.member_role[])'] loop
    if to_regprocedure(f) is not null then
      execute format('grant execute on function %s to authenticated', f);
    end if;
  end loop;
end $$;

select app.apply_grants();

commit;
begin;

-- ===== 20261001001200_locations_suppliers.sql =====
-- ALKASU 0012 — Konum (Google Maps), tedarikçi kartı, müşteride sebil ve kap sayısı
-- Kararlar: D-047..D-050 · Kurallar: BUSINESS_RULES §19

-- ---------------------------------------------------------------------------
-- 1) Tedarikçi kartı: adres, konum, yetkili, vergi no
-- ---------------------------------------------------------------------------
alter table public.suppliers add column if not exists address text;
alter table public.suppliers add column if not exists contact_name text;
alter table public.suppliers add column if not exists tax_no text;
alter table public.suppliers add column if not exists latitude numeric(9,6) check (latitude between -90 and 90);
alter table public.suppliers add column if not exists longitude numeric(9,6) check (longitude between -180 and 180);
alter table public.suppliers add column if not exists updated_at timestamptz not null default now();
drop trigger if exists suppliers_touch on public.suppliers;
create trigger suppliers_touch before update on public.suppliers for each row execute function app.touch_updated_at();

-- Konum ya ikisi birlikte girilir ya hiç
alter table public.suppliers add constraint suppliers_location_pair
  check ((latitude is null) = (longitude is null)) not valid;

create or replace function app.coord(p jsonb, p_key text, p_min numeric, p_max numeric) returns numeric
language plpgsql immutable as $$
declare v numeric;
begin
  if p is null or not (p ? p_key) or nullif(trim(p->>p_key), '') is null then return null; end if;
  v := round((p->>p_key)::numeric, 6);
  if v < p_min or v > p_max then raise exception 'Konum geçersiz' using errcode = '22023'; end if;
  return v;
end $$;

create or replace function public.upsert_supplier(p_business uuid, p jsonb)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id  uuid := nullif(p->>'id', '')::uuid;
  v_lat numeric := app.coord(p, 'latitude', -90, 90);
  v_lng numeric := app.coord(p, 'longitude', -180, 180);
begin
  perform app.require_role(p_business, 'yonetici', 'depo');
  if coalesce(trim(p->>'name'), '') = '' then raise exception 'Tedarikçi adı zorunludur' using errcode = '22023'; end if;
  if (v_lat is null) <> (v_lng is null) then raise exception 'Konumun enlem ve boylamı birlikte girilmelidir' using errcode = '22023'; end if;
  if v_id is null then
    insert into public.suppliers(business_id, name, phone, note, address, contact_name, tax_no, latitude, longitude)
    values (p_business, trim(p->>'name'), nullif(trim(p->>'phone'), ''), nullif(trim(p->>'note'), ''),
            nullif(trim(p->>'address'), ''), nullif(trim(p->>'contact_name'), ''), nullif(trim(p->>'tax_no'), ''), v_lat, v_lng)
    returning id into v_id;
  else
    update public.suppliers set
      name = trim(p->>'name'), phone = nullif(trim(p->>'phone'), ''), note = nullif(trim(p->>'note'), ''),
      address = nullif(trim(p->>'address'), ''), contact_name = nullif(trim(p->>'contact_name'), ''),
      tax_no = nullif(trim(p->>'tax_no'), ''), latitude = v_lat, longitude = v_lng,
      active = coalesce((p->>'active')::boolean, active)
    where id = v_id and business_id = p_business returning id into v_id;
    if v_id is null then raise exception 'Tedarikçi bulunamadı' using errcode = 'P0002'; end if;
  end if;
  return v_id;
exception when unique_violation then
  raise exception 'Bu adla bir tedarikçi zaten var' using errcode = '23505';
end $$;

-- ---------------------------------------------------------------------------
-- 2) Müşteri: konum ve müşterideki sebil sayısı
-- ---------------------------------------------------------------------------
alter table public.customers add column if not exists latitude numeric(9,6) check (latitude between -90 and 90);
alter table public.customers add column if not exists longitude numeric(9,6) check (longitude between -180 and 180);
alter table public.customers add column if not exists dispenser_count integer not null default 0 check (dispenser_count >= 0);
alter table public.customers add constraint customers_location_pair
  check ((latitude is null) = (longitude is null)) not valid;

-- Yalnızca konum/sebil alanlarını güncelleyen ayrı fonksiyon yerine upsert_customer'ı genişletiyoruz:
-- eski fonksiyon gövdesi 0011'deki ile aynıdır; yeni alanlar sonda.
create or replace function public.upsert_customer(p_business uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role public.member_role := app.require_role(p_business, 'yonetici', 'satis');
  v_id   uuid := nullif(p->>'id', '')::uuid;
  v_code text := nullif(trim(p->>'code'), '');
  v_adm  boolean := v_role = 'yonetici';
  v_lat  numeric := app.coord(p, 'latitude', -90, 90);
  v_lng  numeric := app.coord(p, 'longitude', -180, 180);
  v_disp int := nullif(p->>'dispenser_count', '')::int;
begin
  if coalesce(trim(p->>'name'), '') = '' then raise exception 'Müşteri adı zorunludur' using errcode = '22023'; end if;
  if (v_lat is null) <> (v_lng is null) then raise exception 'Konumun enlem ve boylamı birlikte girilmelidir' using errcode = '22023'; end if;
  if v_disp is not null and v_disp < 0 then raise exception 'Sebil sayısı negatif olamaz' using errcode = '22023'; end if;
  if v_code is not null and exists (select 1 from public.customers where business_id = p_business
                                    and lower(code) = lower(v_code) and id is distinct from v_id) then
    raise exception 'Bu müşteri kodu zaten kullanılıyor: %', v_code using errcode = '23505';
  end if;
  if v_id is null then
    if v_code is null then v_code := 'M' || lpad(app.next_number(p_business, 'musteri')::text, 5, '0'); end if;
    insert into public.customers(business_id, code, name, phone, address, tax_no, note, credit_limit, unlimited_credit,
                                 channel, price_list, regions, default_assignee, latitude, longitude, dispenser_count)
    values (p_business, v_code, trim(p->>'name'), nullif(trim(p->>'phone'), ''), nullif(trim(p->>'address'), ''),
            nullif(trim(p->>'tax_no'), ''), nullif(trim(p->>'note'), ''),
            case when v_adm then coalesce(nullif(p->>'credit_limit', '')::numeric, 0) else 0 end,
            case when v_adm then coalesce((p->>'unlimited_credit')::boolean, false) else false end,
            coalesce(nullif(p->>'channel', ''), 'perakende'),
            case when v_adm then coalesce(nullif(p->>'price_list', ''), 'perakende') else 'perakende' end,
            nullif(trim(p->>'regions'), ''), nullif(p->>'default_assignee', '')::uuid,
            v_lat, v_lng, coalesce(v_disp, 0))
    returning id into v_id;
  else
    update public.customers set
      code = coalesce(v_code, code), name = trim(p->>'name'),
      phone = nullif(trim(p->>'phone'), ''), address = nullif(trim(p->>'address'), ''),
      tax_no = nullif(trim(p->>'tax_no'), ''), note = nullif(trim(p->>'note'), ''),
      credit_limit = case when v_adm then coalesce(nullif(p->>'credit_limit', '')::numeric, credit_limit) else credit_limit end,
      unlimited_credit = case when v_adm then coalesce((p->>'unlimited_credit')::boolean, unlimited_credit) else unlimited_credit end,
      active = case when v_adm then coalesce((p->>'active')::boolean, active) else active end,
      channel = coalesce(nullif(p->>'channel', ''), channel),
      price_list = case when v_adm then coalesce(nullif(p->>'price_list', ''), price_list) else price_list end,
      regions = case when p ? 'regions' then nullif(trim(p->>'regions'), '') else regions end,
      default_assignee = case when p ? 'default_assignee' then nullif(p->>'default_assignee', '')::uuid else default_assignee end,
      latitude = case when p ? 'latitude' then v_lat else latitude end,
      longitude = case when p ? 'longitude' then v_lng else longitude end,
      dispenser_count = coalesce(v_disp, dispenser_count)
    where id = v_id and business_id = p_business;
    if not found then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 3) Müşterideki kap (damacana) sayısını düzeltme / açılış (yalnızca yönetici)
--    Fark, kap hareketlerine 'acilis' kaydı olarak yazılır; geçmiş silinmez (D-049).
-- ---------------------------------------------------------------------------
create or replace function public.set_customer_containers(p_customer uuid, p_product uuid, p_qty integer,
                                                          p_deposit_paid numeric default 0, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_bid uuid;
  pr    public.products;
  v_cur int;
  v_delta int;
begin
  select business_id into v_bid from public.customers where id = p_customer;
  if v_bid is null then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(v_bid, 'yonetici');
  pr := app.product_in_business(v_bid, p_product);
  if pr.deposit_amount is null then raise exception 'Bu ürün depozitolu değil' using errcode = '22023'; end if;
  if p_qty is null or p_qty < 0 then raise exception 'Kap sayısı geçersiz' using errcode = '22023'; end if;
  if coalesce(p_deposit_paid, 0) < 0 then raise exception 'Depozito tutarı negatif olamaz' using errcode = '22023'; end if;
  perform 1 from public.customers where id = p_customer for update;
  select coalesce(sum(qty), 0) into v_cur from public.container_ledger where customer_id = p_customer and product_id = pr.id;
  v_delta := p_qty - v_cur;
  if v_delta = 0 then
    return jsonb_build_object('qty', v_cur, 'changed', false);
  end if;
  insert into public.container_ledger(business_id, customer_id, product_id, qty, amount, type, ref_type, created_by)
  values (v_bid, p_customer, pr.id, v_delta, round(coalesce(p_deposit_paid, 0), 2), 'acilis', 'duzeltme', auth.uid());
  perform app.audit(v_bid, 'kap_sayisi_duzeltme', 'customers', p_customer::text,
                    jsonb_build_object('product_id', pr.id, 'qty', v_cur),
                    jsonb_build_object('product_id', pr.id, 'qty', p_qty, 'deposit_paid', p_deposit_paid, 'note', p_note));
  return jsonb_build_object('qty', p_qty, 'changed', true, 'delta', v_delta);
end $$;

select app.apply_grants();

commit;
begin;

-- ===== 20261006001300_customer_role.sql =====
-- ALKASU 0013 — Yeni rol: musteri (internetten kayıt olan ev müşterisi; yalnızca kendi siparişleri)
-- Enum değeri ayrı migration'da eklenir (aynı işlemde kullanılamaz).
alter type public.member_role add value if not exists 'musteri';

commit;
begin;

-- ===== 20261006001400_online_orders_routes.sql =====
-- ALKASU 0014 — Müşterinin kendi siparişi (online), ilk sipariş onayı, ev müşterisi siparişinin bayiye
-- elle atanması, bayinin teslimatı (bizim stok/kasa etkilenmez), rota sırası, depo konumu.
-- Kararlar: D-051..D-058 · Kurallar: BUSINESS_RULES §20-21

-- ---------------------------------------------------------------------------
-- 1) Yardımcılar: bağlı müşteri (bayi + müşteri), personel, fiyat listesi
-- ---------------------------------------------------------------------------
create or replace function app.my_customer(p_business uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select m.customer_id from public.memberships m
   where m.business_id = p_business and m.user_id = auth.uid() and m.active and m.role in ('bayi', 'musteri')
$$;

-- Personel = bayi ve müşteri dışındaki tüm roller
create or replace function app.is_staff(p_business uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(app.role_in(p_business) not in ('bayi', 'musteri'), false)
$$;

create or replace function app.my_price_list(p_business uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select c.price_list from public.customers c where c.id = app.my_customer(p_business)
$$;

alter table public.memberships add constraint memberships_musteri_customer
  check (role <> 'musteri' or customer_id is not null) not valid;

-- ---------------------------------------------------------------------------
-- 2) RLS sıkılaştırma: bayi ve müşteri stok, fiyat geçmişi, ayarlar ve başka listelerin fiyatlarını görmez
-- ---------------------------------------------------------------------------
drop policy if exists prices_select on public.product_prices;
create policy prices_select on public.product_prices for select to authenticated using (app.is_staff(business_id));
drop policy if exists list_prices_select on public.product_list_prices;
create policy list_prices_select on public.product_list_prices for select to authenticated
  using (app.is_staff(business_id) or price_list = app.my_price_list(business_id));
drop policy if exists stock_lvl_select on public.stock_levels;
create policy stock_lvl_select on public.stock_levels for select to authenticated using (app.is_staff(business_id));
drop policy if exists settings_select on public.app_settings;
create policy settings_select on public.app_settings for select to authenticated using (app.is_staff(business_id));

-- ---------------------------------------------------------------------------
-- 3) Müşteri kartı: internetten kayıt, onay; depo konumu; herkese açık sipariş
-- ---------------------------------------------------------------------------
alter table public.customers add column if not exists user_id uuid unique;
alter table public.customers add column if not exists source text not null default 'ofis' check (source in ('ofis', 'online'));
alter table public.customers add column if not exists approved boolean not null default true;

alter table public.locations add column if not exists latitude numeric(9,6) check (latitude between -90 and 90);
alter table public.locations add column if not exists longitude numeric(9,6) check (longitude between -180 and 180);

alter table public.businesses add column if not exists public_ordering boolean not null default false;

-- Kayıt denemeleri (hız sınırı); yalnızca sunucu (service_role) yazar/okur
create table if not exists public.signup_attempts (
  id         bigint generated always as identity primary key,
  ip         text,
  phone      text,
  ok         boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists signup_attempts_ip on public.signup_attempts(ip, created_at desc);
create index if not exists signup_attempts_phone on public.signup_attempts(phone, created_at desc);
alter table public.signup_attempts enable row level security;   -- politika yok: istemci erişemez

-- ---------------------------------------------------------------------------
-- 4) Sipariş: onay bekliyor durumu, bayi ataması, kaynak, rota sırası
-- ---------------------------------------------------------------------------
alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders add constraint orders_status_check
  check (status in ('onay_bekliyor', 'acik', 'teslim_edildi', 'iptal'));
alter table public.orders add column if not exists dealer_customer_id uuid references public.customers(id);
alter table public.orders add column if not exists source text not null default 'ofis' check (source in ('ofis', 'online', 'bayi'));
alter table public.orders add column if not exists route_seq integer;
alter table public.orders add column if not exists dealer_note text;
create index if not exists orders_dealer on public.orders(dealer_customer_id) where status = 'acik';
-- Bir sipariş ya personele ya bayiye atanır
alter table public.orders add constraint orders_one_owner check (assignee is null or dealer_customer_id is null) not valid;

drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis')
         or customer_id = app.my_customer(business_id)
         or dealer_customer_id = app.my_customer(business_id));
drop policy if exists order_items_select on public.order_items;
create policy order_items_select on public.order_items for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id
                  and (app.has_role(o.business_id, 'yonetici', 'satis')
                       or o.customer_id = app.my_customer(o.business_id)
                       or o.dealer_customer_id = app.my_customer(o.business_id))));

-- Bayi, kendisine atanmış siparişlerin müşterisini (ad, telefon, adres, konum) görür
drop policy if exists customers_select on public.customers;
create policy customers_select on public.customers for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis')
         or id = app.my_customer(business_id)
         or exists (select 1 from public.orders o where o.customer_id = customers.id
                      and o.dealer_customer_id = app.my_customer(customers.business_id)));

-- ---------------------------------------------------------------------------
-- 5) Sipariş kaydı (müşteri ve bayi kendi adına; ilk online sipariş onay bekler)
-- ---------------------------------------------------------------------------
create or replace function public.save_order(p_business uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role  public.member_role := app.require_role(p_business, 'yonetici', 'satis', 'bayi', 'musteri');
  v_self  boolean := v_role in ('bayi', 'musteri');
  v_id    uuid := (p->>'id')::uuid;
  o       public.orders;
  c       public.customers;
  it      jsonb;
  pr      public.products;
  u       public.product_units;
  v_price numeric;
  v_line  int := 0;
  v_assignee uuid := nullif(p->>'assignee', '')::uuid;
  v_date  date := coalesce(nullif(p->>'delivery_date', '')::date, app.local_date(now()));
begin
  if v_id is null then raise exception 'Sipariş kimliği eksik' using errcode = '22023'; end if;
  select * into c from public.customers where id = (case when v_self then app.my_customer(p_business)
                                                         else nullif(p->>'customer_id', '')::uuid end)
                                          and business_id = p_business;
  if c.id is null then raise exception 'Müşteri seçilmelidir' using errcode = '22023'; end if;
  if not c.active then raise exception 'Müşteri pasif durumda' using errcode = 'P0001'; end if;
  if jsonb_array_length(coalesce(p->'items', '[]')) = 0 then raise exception 'Siparişte ürün yok' using errcode = '22023'; end if;
  if jsonb_array_length(p->'items') > 50 then raise exception 'Siparişte en fazla 50 kalem olabilir' using errcode = '22023'; end if;
  if v_self then
    v_assignee := null;                                     -- bayi/müşteri atama yapamaz
    if v_date < app.local_date(now()) then v_date := app.local_date(now()); end if;
  end if;
  if v_assignee is not null and not exists (select 1 from public.memberships where business_id = p_business
                                              and user_id = v_assignee and active and role in ('yonetici', 'satis', 'sevkiyat')) then
    raise exception 'Atanan kişi geçersiz' using errcode = '22023';
  end if;

  select * into o from public.orders where id = v_id for update;
  if o.id is null then
    insert into public.orders(id, business_id, no, customer_id, delivery_date, assignee, address, note, price_list, created_by,
                              status, source)
    values (v_id, p_business, app.next_number(p_business, 'siparis'), c.id, v_date,
            case when v_self then null else coalesce(v_assignee, c.default_assignee) end,
            coalesce(nullif(trim(p->>'address'), ''), c.address), nullif(trim(p->>'note'), ''), c.price_list, auth.uid(),
            case when v_role = 'musteri' and not c.approved then 'onay_bekliyor' else 'acik' end,
            case v_role when 'musteri' then 'online' when 'bayi' then 'bayi' else 'ofis' end)
    returning * into o;
  else
    if o.business_id <> p_business then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
    if o.status not in ('acik', 'onay_bekliyor') then raise exception 'Kapanmış sipariş değiştirilemez' using errcode = 'P0001'; end if;
    if v_self and o.customer_id <> c.id then raise exception 'Bu sipariş size ait değil' using errcode = '42501'; end if;
    if v_self and o.dealer_customer_id is not null then
      raise exception 'Sipariş teslimata çıktı; değişiklik için bizi arayın' using errcode = 'P0001';
    end if;
    update public.orders set customer_id = c.id, price_list = c.price_list, delivery_date = v_date,
      assignee = case when v_self or dealer_customer_id is not null then assignee else v_assignee end,
      address = nullif(trim(p->>'address'), ''), note = nullif(trim(p->>'note'), '')
     where id = v_id returning * into o;
    delete from public.order_items where order_id = v_id;
  end if;

  for it in select * from jsonb_array_elements(p->'items') loop
    v_line := v_line + 1;
    pr := app.product_in_business(p_business, (it->>'product_id')::uuid);
    if not pr.active or pr.is_container then raise exception 'Bu ürün siparişe eklenemez: %', pr.name using errcode = 'P0001'; end if;
    select * into u from public.product_units where id = (it->>'unit_id')::uuid and product_id = pr.id and active;
    if u.id is null then raise exception 'Ürün birimi geçersiz: %', pr.name using errcode = '22023'; end if;
    if coalesce((it->>'qty')::int, 0) <= 0 or (it->>'qty')::int > 10000 then raise exception 'Miktar geçersiz: %', pr.name using errcode = '22023'; end if;
    v_price := case when v_role = 'yonetici' and nullif(it->>'unit_price', '') is not null
                    then round((it->>'unit_price')::numeric, 2)
                    else app.unit_list_price(u.id, c.price_list) end;
    if v_price is null then raise exception 'Bu birimin fiyatı tanımlı değil: % %', pr.name, u.name using errcode = 'P0001'; end if;
    insert into public.order_items(order_id, business_id, line_no, product_id, unit_id, qty, unit_price)
    values (v_id, p_business, v_line, pr.id, u.id, (it->>'qty')::int, v_price);
  end loop;

  return jsonb_build_object('id', o.id, 'no', o.no, 'status', o.status);
end $$;

-- İlk online siparişi onayla (müşteri kartı da onaylanır; sonraki siparişleri doğrudan açılır)
create or replace function public.approve_order(p_order uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders;
begin
  select * into o from public.orders where id = p_order for update;
  if o.id is null then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(o.business_id, 'yonetici', 'satis');
  if o.status <> 'onay_bekliyor' then raise exception 'Sipariş onay beklemiyor' using errcode = 'P0001'; end if;
  update public.orders set status = 'acik' where id = p_order;
  update public.customers set approved = true where id = o.customer_id and not approved;
end $$;

create or replace function public.cancel_order(p_order uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders; v_role public.member_role;
begin
  select * into o from public.orders where id = p_order for update;
  if o.id is null then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
  v_role := app.require_role(o.business_id, 'yonetici', 'satis', 'bayi', 'musteri');
  if v_role in ('bayi', 'musteri') and o.customer_id is distinct from app.my_customer(o.business_id) then
    raise exception 'Bu sipariş size ait değil' using errcode = '42501';
  end if;
  if o.status not in ('acik', 'onay_bekliyor') then raise exception 'Sipariş zaten kapanmış' using errcode = 'P0001'; end if;
  if v_role in ('bayi', 'musteri') and o.dealer_customer_id is not null then
    raise exception 'Sipariş teslimata çıktı; iptal için bizi arayın' using errcode = 'P0001';
  end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'İptal nedeni zorunludur' using errcode = '22023'; end if;
  update public.orders set status = 'iptal', cancelled_by = auth.uid(), cancelled_at = now(), cancel_reason = trim(p_reason)
   where id = p_order;
end $$;

-- Personele ata (bayi ataması kalkar)
create or replace function public.assign_order(p_order uuid, p_assignee uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders;
begin
  select * into o from public.orders where id = p_order for update;
  if o.id is null then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(o.business_id, 'yonetici', 'satis');
  if o.status not in ('acik', 'onay_bekliyor') then raise exception 'Kapanmış sipariş değiştirilemez' using errcode = 'P0001'; end if;
  if p_assignee is not null and not exists (select 1 from public.memberships where business_id = o.business_id
                                             and user_id = p_assignee and active and role in ('yonetici', 'satis', 'sevkiyat')) then
    raise exception 'Atanan kişi geçersiz' using errcode = '22023';
  end if;
  update public.orders set assignee = p_assignee,
         dealer_customer_id = case when p_assignee is not null then null else dealer_customer_id end
   where id = p_order;
end $$;

-- Bayiye ata (D-053: elle). Teslimatı bayi kendi stoğundan yapar.
create or replace function public.assign_order_dealer(p_order uuid, p_dealer uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders;
begin
  select * into o from public.orders where id = p_order for update;
  if o.id is null then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(o.business_id, 'yonetici', 'satis');
  if o.status <> 'acik' then raise exception 'Yalnızca açık (onaylanmış) sipariş bayiye atanabilir' using errcode = 'P0001'; end if;
  if p_dealer is not null and not exists (select 1 from public.customers where id = p_dealer and business_id = o.business_id
                                            and channel = 'bayi' and active) then
    raise exception 'Bayi bulunamadı' using errcode = '22023';
  end if;
  if p_dealer is not null and (select channel from public.customers where id = o.customer_id) <> 'perakende' then
    raise exception 'Bayiye yalnızca ev müşterisi siparişi verilebilir' using errcode = 'P0001';
  end if;
  update public.orders set dealer_customer_id = p_dealer,
         assignee = case when p_dealer is not null then null else assignee end,
         route_seq = null, dealer_note = null
   where id = p_order;
end $$;

-- Bayi: teslim edildi (bizim stok, kasa ve cari etkilenmez — D-054)
create or replace function public.dealer_complete_order(p_order uuid, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders;
begin
  select * into o from public.orders where id = p_order for update;
  if o.id is null then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(o.business_id, 'bayi');
  if o.dealer_customer_id is distinct from app.my_customer(o.business_id) then
    raise exception 'Bu sipariş size atanmamış' using errcode = '42501';
  end if;
  if o.status <> 'acik' then raise exception 'Sipariş açık değil' using errcode = 'P0001'; end if;
  update public.orders set status = 'teslim_edildi', delivered_by = auth.uid(), delivered_at = now(),
         dealer_note = nullif(trim(p_note), '')
   where id = p_order;
end $$;

-- Bayi: teslim edemiyorum, siparişi geri bırak
create or replace function public.dealer_release_order(p_order uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders;
begin
  select * into o from public.orders where id = p_order for update;
  if o.id is null then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(o.business_id, 'bayi');
  if o.dealer_customer_id is distinct from app.my_customer(o.business_id) then
    raise exception 'Bu sipariş size atanmamış' using errcode = '42501';
  end if;
  if o.status <> 'acik' then raise exception 'Sipariş açık değil' using errcode = 'P0001'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Neden zorunludur' using errcode = '22023'; end if;
  update public.orders set dealer_customer_id = null, route_seq = null, dealer_note = 'Bayi geri bıraktı: ' || trim(p_reason)
   where id = p_order;
end $$;

-- Bizim teslimatımız: bayiye atanmış sipariş bizden satışa dönüşmez
create or replace function public.deliver_order(p_business uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role public.member_role := app.require_role(p_business, 'yonetici', 'satis');
  o      public.orders;
  v_items jsonb := '[]';
  oi     record;
  v_qty  int;
  v_res  jsonb;
begin
  select * into o from public.orders where id = (p->>'order_id')::uuid and business_id = p_business for update;
  if o.id is null then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
  if o.status = 'teslim_edildi' and o.sale_id = (p->>'sale_id')::uuid then
    return jsonb_build_object('order_id', o.id, 'sale_id', o.sale_id, 'duplicate', true);
  end if;
  if o.status = 'onay_bekliyor' then raise exception 'Sipariş henüz onaylanmadı' using errcode = 'P0001'; end if;
  if o.status <> 'acik' then raise exception 'Sipariş açık değil' using errcode = 'P0001'; end if;
  if o.dealer_customer_id is not null then raise exception 'Bu sipariş bayiye atanmış; teslimatı bayi kaydeder' using errcode = 'P0001'; end if;
  if v_role <> 'yonetici' and o.assignee is distinct from auth.uid() then
    raise exception 'Bu siparişi yalnızca atanan kişi veya yönetici kapatabilir' using errcode = '42501';
  end if;

  for oi in select * from public.order_items where order_id = o.id order by line_no loop
    select coalesce(max((x->>'qty')::int), oi.qty) into v_qty
      from jsonb_array_elements(coalesce(p->'items', '[]')) x where (x->>'order_item_id')::uuid = oi.id;
    v_qty := coalesce(v_qty, oi.qty);
    if v_qty < 0 then raise exception 'Teslim miktarı negatif olamaz' using errcode = '22023'; end if;
    if v_qty > 0 then
      v_items := v_items || jsonb_build_object('product_id', oi.product_id, 'unit_id', oi.unit_id, 'qty', v_qty, 'unit_price', oi.unit_price);
    end if;
  end loop;
  if jsonb_array_length(v_items) = 0 then
    raise exception 'Teslim edilen ürün yok; teslim edilmediyse siparişi iptal edin' using errcode = '22023';
  end if;

  v_res := app.complete_sale_core(p_business, jsonb_build_object(
    'id', p->>'sale_id', 'customer_id', o.customer_id, 'items', v_items,
    'deposits', coalesce(p->'deposits', '[]'), 'payments', coalesce(p->'payments', '[]'),
    'cash_given', p->'cash_given', 'note', coalesce(nullif(trim(p->>'note'), ''), 'Sipariş #' || o.no)), v_role, true);

  update public.orders set status = 'teslim_edildi', delivered_by = auth.uid(), delivered_at = now(),
         sale_id = (v_res->>'id')::uuid where id = o.id;
  perform app.audit(p_business, 'siparis_teslim', 'orders', o.id::text, null, v_res);
  return v_res || jsonb_build_object('order_id', o.id, 'order_no', o.no);
end $$;

-- Rota sırası: verilen sırayla 1..n yazılır (personel kendi/ekibinin, bayi kendisine atanmış siparişler için)
create or replace function public.set_route(p_business uuid, p_orders uuid[]) returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_role public.member_role := app.require_role(p_business, 'yonetici', 'satis', 'bayi'); v_n int;
begin
  if exists (select 1 from unnest(p_orders) x(id) left join public.orders o on o.id = x.id
              where o.id is null or o.business_id <> p_business or o.status <> 'acik'
                 or (v_role = 'bayi' and o.dealer_customer_id is distinct from app.my_customer(p_business))
                 or (v_role <> 'bayi' and o.dealer_customer_id is not null)) then
    raise exception 'Rotada geçersiz veya size ait olmayan sipariş var' using errcode = '42501';
  end if;
  update public.orders o set route_seq = x.n
    from unnest(p_orders) with ordinality as x(id, n) where o.id = x.id;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- Depo / çıkış noktası konumu (rota başlangıcı)
create or replace function public.set_location_coords(p_location uuid, p_lat numeric, p_lng numeric) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bid uuid;
begin
  select business_id into v_bid from public.locations where id = p_location;
  if v_bid is null then raise exception 'Lokasyon bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(v_bid, 'yonetici');
  if (p_lat is null) <> (p_lng is null) then raise exception 'Konumun enlem ve boylamı birlikte girilmelidir' using errcode = '22023'; end if;
  if p_lat is not null and (abs(p_lat) > 90 or abs(p_lng) > 180) then raise exception 'Konum geçersiz' using errcode = '22023'; end if;
  update public.locations set latitude = round(p_lat, 6), longitude = round(p_lng, 6) where id = p_location;
end $$;

-- ---------------------------------------------------------------------------
-- 6) İnternetten kayıt (yalnızca sunucu / service_role) ve herkese açık katalog
-- ---------------------------------------------------------------------------
create or replace function app.public_business() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select id from public.businesses where public_ordering order by created_at limit 1
$$;

create or replace function public.register_customer(p_user uuid, p_name text, p_phone text, p_address text,
                                                    p_lat numeric default null, p_lng numeric default null)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bid uuid := app.public_business(); v_cid uuid; v_dup text;
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Bu işlem için yetkiniz yok' using errcode = '42501'; end if;
  if v_bid is null then raise exception 'İnternetten sipariş kapalı' using errcode = 'P0001'; end if;
  if length(coalesce(trim(p_name), '')) < 3 then raise exception 'Ad soyad zorunludur' using errcode = '22023'; end if;
  if coalesce(p_phone, '') !~ '^5[0-9]{9}$' then raise exception 'Telefon numarası geçersiz' using errcode = '22023'; end if;
  if length(coalesce(trim(p_address), '')) < 10 then raise exception 'Açık adres zorunludur' using errcode = '22023'; end if;
  if (p_lat is null) <> (p_lng is null) or (p_lat is not null and (abs(p_lat) > 90 or abs(p_lng) > 180)) then
    raise exception 'Konum geçersiz' using errcode = '22023';
  end if;
  if exists (select 1 from public.customers where user_id = p_user) then
    raise exception 'Bu kullanıcı zaten kayıtlı' using errcode = '23505';
  end if;
  -- Aynı telefonla ofiste açılmış kart varsa bağlanmaz (başkası adına kayıt riski); yöneticiye not düşülür
  select string_agg(code, ', ') into v_dup from public.customers
   where business_id = v_bid and regexp_replace(coalesce(phone, ''), '\D', '', 'g') like '%' || p_phone;
  insert into public.customers(business_id, code, name, phone, address, channel, price_list, source, approved, user_id,
                               latitude, longitude, note)
  values (v_bid, 'W' || lpad(app.next_number(v_bid, 'musteri')::text, 5, '0'), trim(p_name), '0' || p_phone, trim(p_address),
          'perakende', 'perakende', 'online', false, p_user, round(p_lat, 6), round(p_lng, 6),
          case when v_dup is not null then 'Aynı telefonla kayıtlı kart: ' || v_dup end)
  returning id into v_cid;
  insert into public.memberships(business_id, user_id, role, display_name, customer_id, username)
  values (v_bid, p_user, 'musteri', trim(p_name), v_cid, p_phone);
  return v_cid;
end $$;

-- Kayıt denemesi hız sınırı: say + yaz tek işlemde, kilitli (eşzamanlı istekler sınırı aşamaz)
create or replace function public.signup_attempt(p_ip text, p_phone text) returns bigint
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id bigint;
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Bu işlem için yetkiniz yok' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtext('alkasu_signup'));
  if (select count(*) from public.signup_attempts where ip = p_ip and created_at > now() - interval '1 hour') >= 5
     or (select count(*) from public.signup_attempts where phone = p_phone and created_at > now() - interval '1 day') >= 5
     or (select count(*) from public.signup_attempts where created_at > now() - interval '1 hour') >= 40 then
    return null;                                            -- sınır aşıldı
  end if;
  insert into public.signup_attempts(ip, phone) values (p_ip, p_phone) returning id into v_id;
  return v_id;
end $$;

-- Müşteri kendi adres/konum bilgisini günceller
create or replace function public.update_my_profile(p_business uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role public.member_role := app.require_role(p_business, 'musteri', 'bayi');
  v_cid uuid := app.my_customer(p_business);
  v_lat numeric := app.coord(p, 'latitude', -90, 90);
  v_lng numeric := app.coord(p, 'longitude', -180, 180);
begin
  if v_cid is null then raise exception 'Müşteri kartı bulunamadı' using errcode = 'P0002'; end if;
  if v_role = 'musteri' and p ? 'name' and length(coalesce(trim(p->>'name'), '')) < 3 then
    raise exception 'Ad soyad zorunludur' using errcode = '22023';
  end if;
  if (p ? 'latitude' or p ? 'longitude') and (v_lat is null) <> (v_lng is null) then
    raise exception 'Konumun enlem ve boylamı birlikte girilmelidir' using errcode = '22023';
  end if;
  -- Bayi ticari kartının adını değiştiremez (yönetici değiştirir); gönderilmeyen alanlar korunur
  update public.customers set
    name = case when v_role = 'musteri' and p ? 'name' then trim(p->>'name') else name end,
    address = case when p ? 'address' then nullif(trim(p->>'address'), '') else address end,
    latitude = case when p ? 'latitude' then v_lat else latitude end,
    longitude = case when p ? 'longitude' then v_lng else longitude end
   where id = v_cid;
  if v_role = 'musteri' and p ? 'name' then
    update public.memberships set display_name = trim(p->>'name') where user_id = auth.uid() and business_id = p_business;
  end if;
end $$;

-- Herkese açık ürün listesi (perakende fiyatlarıyla); giriş yapmamış ziyaretçi de çağırabilir
create or replace function public.public_catalog()
returns table(product_id uuid, product_name text, unit_id uuid, unit_name text, factor integer, price numeric, has_deposit boolean)
language sql stable security definer set search_path = public, pg_temp as $$
  select p.id, p.name, u.id, u.name, u.factor, u.price, p.deposit_amount is not null
    from public.products p join public.product_units u on u.product_id = p.id
   where p.business_id = app.public_business() and p.active and not p.is_container and u.active and u.price is not null
   order by p.name, u.factor desc
$$;

-- ---------------------------------------------------------------------------
-- 7) Ana sayfa özeti
-- ---------------------------------------------------------------------------
create or replace function public.dashboard(p_business uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
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
  if v_role in ('yonetici', 'izleyici') then
    select * into d from public.report_daily_sales(p_business, v_today, v_today);
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
end $$;

-- Kullanıcı güncelleme: online müşteri personele/bayiye çevrilemez (ve tersi); müşteri kartı bağlantısı korunur
create or replace function public.update_member(p_membership uuid, p_role public.member_role, p_name text, p_active boolean,
                                                p_customer uuid default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare m public.memberships;
begin
  select * into m from public.memberships where id = p_membership;
  if m.id is null then raise exception 'Kullanıcı bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(m.business_id, 'yonetici');
  if (m.role = 'musteri') <> (p_role = 'musteri') then
    raise exception 'İnternet müşterisi personel veya bayi yapılamaz (ve tersi)' using errcode = '22023';
  end if;
  if p_role = 'bayi' then
    p_customer := coalesce(p_customer, m.customer_id);
    if p_customer is null or not exists (select 1 from public.customers where id = p_customer and business_id = m.business_id and channel = 'bayi') then
      raise exception 'Bayi kullanıcısı bir bayi müşteri kartına bağlanmalıdır' using errcode = '22023';
    end if;
  end if;
  update public.memberships set role = p_role, display_name = trim(p_name), active = p_active,
         customer_id = case when p_role = 'bayi' then p_customer when p_role = 'musteri' then m.customer_id end
   where id = p_membership;
end $$;

-- assignable_users: müşteri göremez
create or replace function public.assignable_users(p_business uuid)
returns table(user_id uuid, display_name text, role public.member_role)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  perform app.require_role(p_business, 'yonetici', 'satis', 'depo', 'bayi');
  return query select m.user_id, m.display_name, m.role from public.memberships m
   where m.business_id = p_business and m.active and m.role in ('yonetici', 'satis', 'sevkiyat')
   order by m.display_name;
end $$;

-- ---------------------------------------------------------------------------
-- 8) Yetki listesi: yeni RLS yardımcıları ve ziyaretçiye açık tek fonksiyon
-- ---------------------------------------------------------------------------
create or replace function app.apply_grants() returns void
language plpgsql as $$
declare f text;
begin
  execute 'revoke all on all tables in schema public from anon, authenticated';
  execute 'grant select on all tables in schema public to authenticated';
  execute 'revoke all on all sequences in schema public from anon, authenticated';
  execute 'revoke execute on all functions in schema public from public, anon';
  execute 'grant execute on all functions in schema public to authenticated, service_role';
  execute 'revoke all on all tables in schema audit from anon, authenticated';
  execute 'grant usage on schema audit to authenticated';
  execute 'grant select on audit.log to authenticated';
  execute 'revoke execute on all functions in schema app from public, anon, authenticated';
  foreach f in array array['app.uid()', 'app.role_in(uuid)', 'app.is_member(uuid)',
                           'app.has_role(uuid, public.member_role[])', 'app.is_admin(uuid)',
                           'app.local_date(timestamptz)', 'app.can_see_sale(uuid)', 'app.my_customer(uuid)',
                           'app.role_covers(public.member_role, public.member_role[])',
                           'app.is_staff(uuid)', 'app.my_price_list(uuid)'] loop
    if to_regprocedure(f) is not null then
      execute format('grant execute on function %s to authenticated', f);
    end if;
  end loop;
  -- Giriş yapmamış ziyaretçi yalnızca herkese açık ürün listesini okuyabilir
  if to_regprocedure('public.public_catalog()') is not null then
    execute 'grant execute on function public.public_catalog() to anon';
  end if;
end $$;

select app.apply_grants();

commit;
begin;

-- ===== 20261009001500_dealer_customers.sql =====
-- ALKASU 0015 — Bayinin kendi müşteri listesi ve kendi sipariş girişi
-- Kurallar: BUSINESS_RULES §22 · Kararlar: D-059..D-062
-- • Bayi kendi müşterisini ekler/düzenler (yalnızca o bayi ve personel görür).
-- • Bayi kendi müşterisine kendisi teslim edecekse sipariş onaysız açılır (bayinin kendi satışı).
-- • Bayinin başka bayiye veya merkeze (Hüseyin) açtığı sipariş ve bayinin bizden alımı onay bekler;
--   onaylayan: yönetici / satış / sevkiyat. Hedef bayi siparişi ancak onaydan sonra görür.

alter table public.customers add column if not exists owner_dealer_id uuid references public.customers(id);
create index if not exists customers_owner_dealer on public.customers(owner_dealer_id) where owner_dealer_id is not null;
alter table public.orders add column if not exists requested_dealer_id uuid references public.customers(id);

-- RLS özyinelemesini önlemek için sahip bilgisini politikanın dışından okur
create or replace function app.customer_owner(p_customer uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select owner_dealer_id from public.customers where id = p_customer
$$;

-- ---------------------------------------------------------------------------
-- RLS: bayi kendi müşterilerini ve onların siparişlerini görür
-- ---------------------------------------------------------------------------
drop policy if exists customers_select on public.customers;
create policy customers_select on public.customers for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis')
         or id = app.my_customer(business_id)
         or owner_dealer_id = app.my_customer(business_id)
         or exists (select 1 from public.orders o where o.customer_id = customers.id
                      and o.dealer_customer_id = app.my_customer(customers.business_id)));

drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis')
         or customer_id = app.my_customer(business_id)
         or dealer_customer_id = app.my_customer(business_id)
         or app.customer_owner(customer_id) = app.my_customer(business_id));
drop policy if exists order_items_select on public.order_items;
create policy order_items_select on public.order_items for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id
                  and (app.has_role(o.business_id, 'yonetici', 'satis')
                       or o.customer_id = app.my_customer(o.business_id)
                       or o.dealer_customer_id = app.my_customer(o.business_id)
                       or app.customer_owner(o.customer_id) = app.my_customer(o.business_id))));

-- ---------------------------------------------------------------------------
-- Bayinin müşteri kartı (ev müşterisi, perakende, veresiyesiz)
-- ---------------------------------------------------------------------------
create or replace function public.dealer_upsert_customer(p_business uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_me  uuid;
  v_id  uuid := nullif(p->>'id', '')::uuid;
  v_lat numeric := app.coord(p, 'latitude', -90, 90);
  v_lng numeric := app.coord(p, 'longitude', -180, 180);
begin
  perform app.require_role(p_business, 'bayi');
  v_me := app.my_customer(p_business);
  if v_me is null then raise exception 'Hesabınız bir bayi kartına bağlı değil' using errcode = '42501'; end if;
  if length(coalesce(trim(p->>'name'), '')) < 2 then raise exception 'Müşteri adı zorunludur' using errcode = '22023'; end if;
  if (v_lat is null) <> (v_lng is null) then raise exception 'Konumun enlem ve boylamı birlikte girilmelidir' using errcode = '22023'; end if;
  if v_id is null then
    insert into public.customers(business_id, code, name, phone, address, note, channel, price_list, owner_dealer_id,
                                 latitude, longitude, credit_limit, unlimited_credit)
    values (p_business, 'B' || lpad(app.next_number(p_business, 'musteri')::text, 5, '0'), trim(p->>'name'),
            nullif(trim(p->>'phone'), ''), nullif(trim(p->>'address'), ''), nullif(trim(p->>'note'), ''),
            'perakende', 'perakende', v_me, v_lat, v_lng, 0, false)
    returning id into v_id;
  else
    update public.customers set name = trim(p->>'name'), phone = nullif(trim(p->>'phone'), ''),
           address = nullif(trim(p->>'address'), ''), note = nullif(trim(p->>'note'), ''),
           latitude = v_lat, longitude = v_lng,
           active = coalesce((p->>'active')::boolean, active)
     where id = v_id and business_id = p_business and owner_dealer_id = v_me;
    if not found then raise exception 'Bu müşteri size ait değil' using errcode = '42501'; end if;
  end if;
  return v_id;
end $$;

-- Bayilerin adı (sipariş girerken "teslim eden" seçimi için; bayi başka bayinin kartını göremez)
create or replace function public.dealer_list(p_business uuid)
returns table(id uuid, name text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  perform app.require_role(p_business, 'yonetici', 'satis', 'depo', 'bayi');
  return query select c.id, c.name from public.customers c
   where c.business_id = p_business and c.channel = 'bayi' and c.active order by c.name;
end $$;

-- ---------------------------------------------------------------------------
-- Sipariş kaydı
-- p = { id, customer_id?, deliver_by?: 'self' | 'merkez' | <bayi kart id>, delivery_date?, assignee?, address?, note?, items }
-- ---------------------------------------------------------------------------
create or replace function public.save_order(p_business uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role  public.member_role := app.require_role(p_business, 'yonetici', 'satis', 'bayi', 'musteri');
  v_self  boolean := v_role in ('bayi', 'musteri');
  v_me    uuid := case when v_role in ('bayi', 'musteri') then app.my_customer(p_business) end;
  v_id    uuid := (p->>'id')::uuid;
  o       public.orders;
  c       public.customers;
  it      jsonb;
  pr      public.products;
  u       public.product_units;
  v_price numeric;
  v_line  int := 0;
  v_assignee uuid := nullif(p->>'assignee', '')::uuid;
  v_date  date := coalesce(nullif(p->>'delivery_date', '')::date, app.local_date(now()));
  v_cust  uuid;
  v_by    text := coalesce(nullif(p->>'deliver_by', ''), 'self');
  v_status text;
  v_dealer uuid;      -- hemen teslim edecek bayi (bayinin kendi teslimatı)
  v_req    uuid;      -- onaydan sonra teslim edecek bayi
begin
  if v_id is null then raise exception 'Sipariş kimliği eksik' using errcode = '22023'; end if;
  if v_self and v_me is null then raise exception 'Hesabınız bir müşteri kartına bağlı değil' using errcode = '42501'; end if;
  -- Müşteri: personel seçer; müşteri kendisi; bayi kendisi (alım) veya kendi müşterisi
  v_cust := case
    when v_role = 'musteri' then v_me
    when v_role = 'bayi' then coalesce(nullif(p->>'customer_id', '')::uuid, v_me)
    else nullif(p->>'customer_id', '')::uuid end;
  select * into c from public.customers where id = v_cust and business_id = p_business;
  if c.id is null then raise exception 'Müşteri seçilmelidir' using errcode = '22023'; end if;
  if v_role = 'bayi' and c.id <> v_me and c.owner_dealer_id is distinct from v_me then
    raise exception 'Bu müşteri size ait değil' using errcode = '42501';
  end if;
  if not c.active then raise exception 'Müşteri pasif durumda' using errcode = 'P0001'; end if;
  if jsonb_array_length(coalesce(p->'items', '[]')) = 0 then raise exception 'Siparişte ürün yok' using errcode = '22023'; end if;
  if jsonb_array_length(p->'items') > 50 then raise exception 'Siparişte en fazla 50 kalem olabilir' using errcode = '22023'; end if;
  if v_self then
    v_assignee := null;                                     -- bayi/müşteri personel atayamaz
    if v_date < app.local_date(now()) then v_date := app.local_date(now()); end if;
  end if;
  if v_assignee is not null and not exists (select 1 from public.memberships where business_id = p_business
                                              and user_id = v_assignee and active and role in ('yonetici', 'satis', 'sevkiyat')) then
    raise exception 'Atanan kişi geçersiz' using errcode = '22023';
  end if;

  -- Durum ve teslim eden
  if v_role = 'musteri' then
    v_status := case when c.approved then 'acik' else 'onay_bekliyor' end;
  elsif v_role = 'bayi' then
    if c.id = v_me then
      v_status := 'onay_bekliyor';                          -- bayinin bizden alımı: merkez teslim eder, onay gerekir
    elsif v_by = 'self' then
      v_status := 'acik'; v_dealer := v_me;                 -- kendi müşterisine kendisi teslim eder
    elsif v_by = 'merkez' then
      v_status := 'onay_bekliyor';
    else
      v_req := nullif(v_by, '')::uuid;
      if v_req = v_me then
        v_status := 'acik'; v_dealer := v_me; v_req := null;
      elsif not exists (select 1 from public.customers where id = v_req and business_id = p_business and channel = 'bayi' and active) then
        raise exception 'Teslim edecek bayi bulunamadı' using errcode = '22023';
      else
        v_status := 'onay_bekliyor';
      end if;
    end if;
  else
    v_status := 'acik';
  end if;

  select * into o from public.orders where id = v_id for update;
  if o.id is null then
    insert into public.orders(id, business_id, no, customer_id, delivery_date, assignee, address, note, price_list, created_by,
                              status, source, dealer_customer_id, requested_dealer_id)
    values (v_id, p_business, app.next_number(p_business, 'siparis'), c.id, v_date,
            case when v_self then null else coalesce(v_assignee, c.default_assignee) end,
            coalesce(nullif(trim(p->>'address'), ''), c.address), nullif(trim(p->>'note'), ''), c.price_list, auth.uid(),
            v_status, case v_role when 'musteri' then 'online' when 'bayi' then 'bayi' else 'ofis' end,
            v_dealer, v_req)
    returning * into o;
  else
    if o.business_id <> p_business then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
    if o.status not in ('acik', 'onay_bekliyor') then raise exception 'Kapanmış sipariş değiştirilemez' using errcode = 'P0001'; end if;
    if v_self and o.customer_id <> c.id then raise exception 'Bu sipariş size ait değil' using errcode = '42501'; end if;
    if v_self and o.dealer_customer_id is not null and o.dealer_customer_id is distinct from v_me then
      raise exception 'Sipariş teslimata çıktı; değişiklik için bizi arayın' using errcode = 'P0001';
    end if;
    -- Teslim eden ve durum güncellemede değişmez
    update public.orders set customer_id = c.id, price_list = c.price_list, delivery_date = v_date,
      assignee = case when v_self or dealer_customer_id is not null then assignee else v_assignee end,
      address = nullif(trim(p->>'address'), ''), note = nullif(trim(p->>'note'), '')
     where id = v_id returning * into o;
    delete from public.order_items where order_id = v_id;
  end if;

  for it in select * from jsonb_array_elements(p->'items') loop
    v_line := v_line + 1;
    pr := app.product_in_business(p_business, (it->>'product_id')::uuid);
    if not pr.active or pr.is_container then raise exception 'Bu ürün siparişe eklenemez: %', pr.name using errcode = 'P0001'; end if;
    select * into u from public.product_units where id = (it->>'unit_id')::uuid and product_id = pr.id and active;
    if u.id is null then raise exception 'Ürün birimi geçersiz: %', pr.name using errcode = '22023'; end if;
    if coalesce((it->>'qty')::int, 0) <= 0 or (it->>'qty')::int > 10000 then raise exception 'Miktar geçersiz: %', pr.name using errcode = '22023'; end if;
    v_price := case when v_role = 'yonetici' and nullif(it->>'unit_price', '') is not null
                    then round((it->>'unit_price')::numeric, 2)
                    else app.unit_list_price(u.id, c.price_list) end;
    if v_price is null then raise exception 'Bu birimin fiyatı tanımlı değil: % %', pr.name, u.name using errcode = 'P0001'; end if;
    insert into public.order_items(order_id, business_id, line_no, product_id, unit_id, qty, unit_price)
    values (v_id, p_business, v_line, pr.id, u.id, (it->>'qty')::int, v_price);
  end loop;

  return jsonb_build_object('id', o.id, 'no', o.no, 'status', o.status);
end $$;

-- Onay: talep edilen bayiye geçer (yoksa merkezin açık siparişi olur)
create or replace function public.approve_order(p_order uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders;
begin
  select * into o from public.orders where id = p_order for update;
  if o.id is null then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(o.business_id, 'yonetici', 'satis');
  if o.status <> 'onay_bekliyor' then raise exception 'Sipariş onay beklemiyor' using errcode = 'P0001'; end if;
  update public.orders set status = 'acik',
         dealer_customer_id = coalesce(requested_dealer_id, dealer_customer_id),
         assignee = case when requested_dealer_id is not null then null else assignee end,
         requested_dealer_id = null
   where id = p_order;
  update public.customers set approved = true where id = o.customer_id and not approved;
end $$;

create or replace function public.cancel_order(p_order uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders; v_role public.member_role; v_me uuid;
begin
  select * into o from public.orders where id = p_order for update;
  if o.id is null then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
  v_role := app.require_role(o.business_id, 'yonetici', 'satis', 'bayi', 'musteri');
  v_me := app.my_customer(o.business_id);
  if v_role in ('bayi', 'musteri') and o.customer_id is distinct from v_me
     and not (v_role = 'bayi' and app.customer_owner(o.customer_id) is not distinct from v_me and v_me is not null) then
    raise exception 'Bu sipariş size ait değil' using errcode = '42501';
  end if;
  if o.status not in ('acik', 'onay_bekliyor') then raise exception 'Sipariş zaten kapanmış' using errcode = 'P0001'; end if;
  if v_role in ('bayi', 'musteri') and o.dealer_customer_id is not null and o.dealer_customer_id is distinct from v_me then
    raise exception 'Sipariş teslimata çıktı; iptal için bizi arayın' using errcode = 'P0001';
  end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'İptal nedeni zorunludur' using errcode = '22023'; end if;
  update public.orders set status = 'iptal', cancelled_by = auth.uid(), cancelled_at = now(), cancel_reason = trim(p_reason)
   where id = p_order;
end $$;

-- Bayiye elle atama: ev müşterisi (bayi müşterisi dahil) siparişi; talep alanı temizlenir
create or replace function public.assign_order_dealer(p_order uuid, p_dealer uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders;
begin
  select * into o from public.orders where id = p_order for update;
  if o.id is null then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(o.business_id, 'yonetici', 'satis');
  if o.status <> 'acik' then raise exception 'Yalnızca açık (onaylanmış) sipariş bayiye atanabilir' using errcode = 'P0001'; end if;
  if p_dealer is not null and not exists (select 1 from public.customers where id = p_dealer and business_id = o.business_id
                                            and channel = 'bayi' and active) then
    raise exception 'Bayi bulunamadı' using errcode = '22023';
  end if;
  if p_dealer is not null and (select channel from public.customers where id = o.customer_id) <> 'perakende' then
    raise exception 'Bayiye yalnızca ev müşterisi siparişi verilebilir' using errcode = 'P0001';
  end if;
  update public.orders set dealer_customer_id = p_dealer, requested_dealer_id = null,
         assignee = case when p_dealer is not null then null else assignee end,
         route_seq = null, dealer_note = null
   where id = p_order;
end $$;

create or replace function app.apply_grants() returns void
language plpgsql as $$
declare f text;
begin
  execute 'revoke all on all tables in schema public from anon, authenticated';
  execute 'grant select on all tables in schema public to authenticated';
  execute 'revoke all on all sequences in schema public from anon, authenticated';
  execute 'revoke execute on all functions in schema public from public, anon';
  execute 'grant execute on all functions in schema public to authenticated, service_role';
  execute 'revoke all on all tables in schema audit from anon, authenticated';
  execute 'grant usage on schema audit to authenticated';
  execute 'grant select on audit.log to authenticated';
  execute 'revoke execute on all functions in schema app from public, anon, authenticated';
  foreach f in array array['app.uid()', 'app.role_in(uuid)', 'app.is_member(uuid)',
                           'app.has_role(uuid, public.member_role[])', 'app.is_admin(uuid)',
                           'app.local_date(timestamptz)', 'app.can_see_sale(uuid)', 'app.my_customer(uuid)',
                           'app.role_covers(public.member_role, public.member_role[])',
                           'app.is_staff(uuid)', 'app.my_price_list(uuid)', 'app.customer_owner(uuid)'] loop
    if to_regprocedure(f) is not null then
      execute format('grant execute on function %s to authenticated', f);
    end if;
  end loop;
  if to_regprocedure('public.public_catalog()') is not null then
    execute 'grant execute on function public.public_catalog() to anon';
  end if;
end $$;

select app.apply_grants();

commit;
begin;

create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (version text primary key, statements text[], name text);
insert into supabase_migrations.schema_migrations(version, name) values ('20260930000100', 'foundation') on conflict do nothing;
insert into supabase_migrations.schema_migrations(version, name) values ('20260930000200', 'catalog') on conflict do nothing;
insert into supabase_migrations.schema_migrations(version, name) values ('20260930000300', 'stock') on conflict do nothing;
insert into supabase_migrations.schema_migrations(version, name) values ('20260930000400', 'sales') on conflict do nothing;
insert into supabase_migrations.schema_migrations(version, name) values ('20260930000500', 'cash') on conflict do nothing;
insert into supabase_migrations.schema_migrations(version, name) values ('20260930000600', 'import_count') on conflict do nothing;
insert into supabase_migrations.schema_migrations(version, name) values ('20260930000700', 'reports') on conflict do nothing;
insert into supabase_migrations.schema_migrations(version, name) values ('20260930000800', 'audit_view') on conflict do nothing;
insert into supabase_migrations.schema_migrations(version, name) values ('20261001000900', 'fix_safeupdate') on conflict do nothing;
insert into supabase_migrations.schema_migrations(version, name) values ('20261001001000', 'roles') on conflict do nothing;
insert into supabase_migrations.schema_migrations(version, name) values ('20261001001100', 'dealers_orders') on conflict do nothing;
insert into supabase_migrations.schema_migrations(version, name) values ('20261001001200', 'locations_suppliers') on conflict do nothing;
insert into supabase_migrations.schema_migrations(version, name) values ('20261006001300', 'customer_role') on conflict do nothing;
insert into supabase_migrations.schema_migrations(version, name) values ('20261006001400', 'online_orders_routes') on conflict do nothing;
insert into supabase_migrations.schema_migrations(version, name) values ('20261009001500', 'dealer_customers') on conflict do nothing;
commit;
