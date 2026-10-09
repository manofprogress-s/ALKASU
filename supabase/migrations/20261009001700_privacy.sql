-- ALKASU 0017 — KVKK: aydınlatma kayıtları ve isteğe bağlı kampanya izni
-- Kural: BUSINESS_RULES §23 (K-01..K-07) · Karar: D-064..D-067
-- Aydınlatma için rıza istenmez; hangi sürümün ne zaman, hangi kanaldan iletildiği değiştirilemez kayda yazılır.
-- Kampanya (ticari ileti) izni ayrı, isteğe bağlı ve geri çekilebilir.

alter table public.customers add column if not exists marketing_consent boolean not null default false;
alter table public.customers add column if not exists marketing_consent_at timestamptz;

create table if not exists public.privacy_events (
  id              bigserial primary key,
  business_id     uuid not null references public.businesses(id),
  customer_id     uuid not null references public.customers(id),
  kind            text not null check (kind in ('aydinlatma', 'kampanya_izni', 'kampanya_ret')),
  notice_version  text not null check (length(notice_version) between 1 and 40),
  channel         text not null check (channel in ('online_kayit', 'musteri', 'personel', 'bayi')),
  created_at      timestamptz not null default now(),
  created_by      uuid
);
create index if not exists privacy_events_customer on public.privacy_events(customer_id, created_at desc);
alter table public.privacy_events enable row level security;
-- Yönetici/satış tümünü; bayi kendi müşterilerini; müşteri kendi kayıtlarını görür. Yazma yalnızca fonksiyonlarla.
create policy privacy_events_select on public.privacy_events for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis')
         or customer_id = app.my_customer(business_id)
         or app.customer_owner(customer_id) = app.my_customer(business_id));

-- Değiştirilemez kayıt: güncelleme ve silme her rol için yasak (service_role dahil)
create or replace function app.tg_immutable() returns trigger language plpgsql as $$
begin
  raise exception 'Bu kayıt değiştirilemez' using errcode = '42501';
end $$;
drop trigger if exists privacy_events_immutable on public.privacy_events;
create trigger privacy_events_immutable before update or delete on public.privacy_events
  for each row execute function app.tg_immutable();

create or replace function app.privacy_log(p_business uuid, p_customer uuid, p_kind text, p_version text, p_channel text)
returns void language sql security definer set search_path = public, pg_temp as $$
  insert into public.privacy_events(business_id, customer_id, kind, notice_version, channel, created_by)
  values (p_business, p_customer, p_kind, p_version, p_channel, auth.uid())
$$;

-- Kampanya izni: kart + kayıt birlikte; değişiklik yoksa kayıt düşülmez
create or replace function app.set_marketing(p_customer uuid, p_value boolean, p_version text, p_channel text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bid uuid; v_old boolean;
begin
  select business_id, marketing_consent into v_bid, v_old from public.customers where id = p_customer for update;
  if v_old is not distinct from p_value then return; end if;
  update public.customers set marketing_consent = p_value, marketing_consent_at = now() where id = p_customer;
  perform app.privacy_log(v_bid, p_customer, case when p_value then 'kampanya_izni' else 'kampanya_ret' end, p_version, p_channel);
end $$;

-- Online kayıt: aydınlatma kaydı ve isteğe bağlı kampanya izni eklendi (eski çağrılar yeni parametreler olmadan da çalışır)
drop function if exists public.register_customer(uuid, text, text, text, numeric, numeric);
create or replace function public.register_customer(p_user uuid, p_name text, p_phone text, p_address text,
                                                    p_lat numeric default null, p_lng numeric default null,
                                                    p_notice_version text default null, p_marketing boolean default false)
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
  if p_notice_version is not null then
    perform app.privacy_log(v_bid, v_cid, 'aydinlatma', left(p_notice_version, 40), 'online_kayit');
  end if;
  if coalesce(p_marketing, false) then
    perform app.set_marketing(v_cid, true, coalesce(left(p_notice_version, 40), '?'), 'online_kayit');
  end if;
  return v_cid;
end $$;

-- Müşteri kendi kampanya iznini verir / geri çeker
create or replace function public.set_my_marketing(p_business uuid, p_value boolean, p_version text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_cid uuid := app.my_customer(p_business);
begin
  if v_cid is null or app.role_in(p_business) is distinct from 'musteri' then
    raise exception 'Bu işlem için yetkiniz yok' using errcode = '42501';
  end if;
  if length(coalesce(p_version, '')) not between 1 and 40 then raise exception 'Metin sürümü geçersiz' using errcode = '22023'; end if;
  perform app.set_marketing(v_cid, p_value, p_version, 'musteri');
end $$;

-- Personel / bayi: müşteriye ilk iletişimde aydınlatma yapıldığını kaydeder; müşteri telefonla bildirirse kampanya iznini işler.
-- Bayi yalnızca kendi müşterileri için.
create or replace function public.record_customer_privacy(p_customer uuid, p_kind text, p_version text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bid uuid; v_role public.member_role; v_channel text;
begin
  select business_id into v_bid from public.customers where id = p_customer;
  if v_bid is null then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
  v_role := app.role_in(v_bid);
  if v_role = 'bayi' then
    if app.customer_owner(p_customer) is distinct from app.my_customer(v_bid) or app.my_customer(v_bid) is null then
      raise exception 'Bu müşteri size ait değil' using errcode = '42501';
    end if;
    v_channel := 'bayi';
  elsif app.role_covers(v_role, array['yonetici', 'satis']::public.member_role[]) then
    v_channel := 'personel';
  else
    raise exception 'Bu işlem için yetkiniz yok' using errcode = '42501';
  end if;
  if length(coalesce(p_version, '')) not between 1 and 40 then raise exception 'Metin sürümü geçersiz' using errcode = '22023'; end if;
  if p_kind = 'aydinlatma' then
    perform app.privacy_log(v_bid, p_customer, 'aydinlatma', p_version, v_channel);
  elsif p_kind in ('kampanya_izni', 'kampanya_ret') then
    perform app.set_marketing(p_customer, p_kind = 'kampanya_izni', p_version, v_channel);
  else
    raise exception 'Geçersiz işlem' using errcode = '22023';
  end if;
end $$;

select app.apply_grants();
