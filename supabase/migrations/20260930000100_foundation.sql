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
