-- 10.10.2026 yayını: bayi listesi gizliliği + özel yönlendirme (0019). Tek işlem.
begin;
-- ALKASU 0019 — Bayi listesi gizliliği ve sevkiyat yönlendirme
-- Kural: BUSINESS_RULES §24 (G-13..G-17) · Karar: D-072..D-075
-- 1) Bayinin müşteri kartını merkez doğrudan değiştiremez; değişiklik/yeni müşteri önerisi bayinin onayına gider.
-- 2) Özel yönlendirme (bayinin kendi sevkiyatını depoya/başka bayiye almak, kurumsal siparişi bayiye vermek)
--    yalnızca sevkiyat sorumlusu ve yönetici yapar; gerekçe zorunlu, kayıt yöneticiye görünür ve değiştirilemez.

-- ---------------------------------------------------------------- bayi müşteri kartı: ortak yazma çekirdeği
create or replace function app.dealer_customer_write(p_business uuid, p_dealer uuid, p_id uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id  uuid := p_id;
  v_lat numeric := app.coord(p, 'latitude', -90, 90);
  v_lng numeric := app.coord(p, 'longitude', -180, 180);
begin
  if length(coalesce(trim(p->>'name'), '')) < 2 then raise exception 'Müşteri adı zorunludur' using errcode = '22023'; end if;
  if (v_lat is null) <> (v_lng is null) then raise exception 'Konumun enlem ve boylamı birlikte girilmelidir' using errcode = '22023'; end if;
  if v_id is null then
    insert into public.customers(business_id, code, name, phone, address, note, channel, price_list, owner_dealer_id,
                                 latitude, longitude, credit_limit, unlimited_credit)
    values (p_business, 'B' || lpad(app.next_number(p_business, 'musteri')::text, 5, '0'), trim(p->>'name'),
            nullif(trim(p->>'phone'), ''), nullif(trim(p->>'address'), ''), nullif(trim(p->>'note'), ''),
            'perakende', 'perakende', p_dealer, v_lat, v_lng, 0, false)
    returning id into v_id;
  else
    update public.customers set name = trim(p->>'name'), phone = nullif(trim(p->>'phone'), ''),
           address = nullif(trim(p->>'address'), ''), note = nullif(trim(p->>'note'), ''),
           latitude = v_lat, longitude = v_lng,
           active = coalesce((p->>'active')::boolean, active)
     where id = v_id and business_id = p_business and owner_dealer_id = p_dealer;
    if not found then raise exception 'Bu müşteri size ait değil' using errcode = '42501'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.dealer_upsert_customer(p_business uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_me uuid;
begin
  perform app.require_role(p_business, 'bayi');
  v_me := app.my_customer(p_business);
  if v_me is null then raise exception 'Hesabınız bir bayi kartına bağlı değil' using errcode = '42501'; end if;
  return app.dealer_customer_write(p_business, v_me, nullif(p->>'id', '')::uuid, p);
end $$;

-- Merkez, bayiye ait kartı doğrudan değiştiremez (G-14)
create or replace function app.tg_dealer_card_guard() returns trigger language plpgsql as $$
begin
  if old.owner_dealer_id is not null and app.role_in(old.business_id) is distinct from 'bayi'
     and coalesce(auth.role(), '') <> 'service_role'
     and (new.name, new.phone, new.address, new.note, new.latitude, new.longitude, new.active, new.owner_dealer_id)
         is distinct from (old.name, old.phone, old.address, old.note, old.latitude, old.longitude, old.active, old.owner_dealer_id) then
    raise exception 'Bu müşteri bayiye ait. Değişiklik önerisi gönderin; bayi onaylarsa uygulanır.' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists customers_dealer_guard on public.customers;
create trigger customers_dealer_guard before update on public.customers
  for each row execute function app.tg_dealer_card_guard();

-- ---------------------------------------------------------------- öneriler
create table if not exists public.customer_requests (
  id                 uuid primary key default gen_random_uuid(),
  business_id        uuid not null references public.businesses(id),
  dealer_id          uuid not null references public.customers(id),
  customer_id        uuid references public.customers(id),          -- null: yeni müşteri önerisi
  data               jsonb not null,
  status             text not null default 'bekliyor' check (status in ('bekliyor', 'onaylandi', 'reddedildi', 'iptal')),
  requested_by       uuid,
  requested_at       timestamptz not null default now(),
  decided_by         uuid,
  decided_at         timestamptz,
  decision_note      text check (decision_note is null or length(decision_note) <= 300),
  result_customer_id uuid references public.customers(id)
);
create index if not exists customer_requests_dealer on public.customer_requests(dealer_id, status);
create index if not exists customer_requests_customer on public.customer_requests(customer_id);
alter table public.customer_requests enable row level security;
create policy customer_requests_select on public.customer_requests for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis') or dealer_id = app.my_customer(business_id));
create trigger customer_requests_audit after insert or update on public.customer_requests
  for each row execute function audit.tg_row();

create or replace function app.clean_customer_data(p jsonb) returns jsonb language sql immutable as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'name', nullif(trim(p->>'name'), ''), 'phone', nullif(trim(p->>'phone'), ''),
    'address', nullif(trim(p->>'address'), ''), 'note', nullif(trim(p->>'note'), ''),
    'latitude', p->'latitude', 'longitude', p->'longitude'))
$$;

-- Personel: bayinin listesine müşteri önerir veya bayinin müşterisinde değişiklik önerir
create or replace function public.propose_dealer_customer(p_dealer uuid, p_customer uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bid uuid; v_id uuid; v_d jsonb := app.clean_customer_data(p);
begin
  select business_id into v_bid from public.customers where id = p_dealer and channel = 'bayi' and active;
  if v_bid is null then raise exception 'Bayi bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(v_bid, 'yonetici', 'satis');
  if p_customer is not null and not exists (select 1 from public.customers where id = p_customer and owner_dealer_id = p_dealer) then
    raise exception 'Bu müşteri bu bayiye ait değil' using errcode = '22023';
  end if;
  if length(coalesce(v_d->>'name', '')) < 2 then raise exception 'Müşteri adı zorunludur' using errcode = '22023'; end if;
  perform app.coord(v_d, 'latitude', -90, 90), app.coord(v_d, 'longitude', -180, 180);
  if (v_d ? 'latitude') <> (v_d ? 'longitude') then raise exception 'Konumun enlem ve boylamı birlikte girilmelidir' using errcode = '22023'; end if;
  if p_customer is not null and exists (select 1 from public.customer_requests where customer_id = p_customer and status = 'bekliyor') then
    raise exception 'Bu müşteri için bayinin onayını bekleyen bir öneri zaten var' using errcode = 'P0001';
  end if;
  insert into public.customer_requests(business_id, dealer_id, customer_id, data, requested_by)
  values (v_bid, p_dealer, p_customer, v_d, auth.uid()) returning id into v_id;
  return v_id;
end $$;

-- Bayi: öneriyi onaylar (uygulanır) veya reddeder
create or replace function public.decide_customer_request(p_request uuid, p_approve boolean, p_note text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.customer_requests; v_cid uuid; v_data jsonb;
begin
  select * into r from public.customer_requests where id = p_request for update;
  if r.id is null then raise exception 'Öneri bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(r.business_id, 'bayi');
  if app.my_customer(r.business_id) is distinct from r.dealer_id then raise exception 'Bu öneri size ait değil' using errcode = '42501'; end if;
  if r.status <> 'bekliyor' then raise exception 'Bu öneri zaten sonuçlandı' using errcode = 'P0001'; end if;
  if p_approve then
    v_data := r.data;
    if r.customer_id is not null then
      -- Önerilmeyen alanlar mevcut değerinde kalır
      select jsonb_build_object('name', name, 'phone', phone, 'address', address, 'note', note, 'latitude', latitude, 'longitude', longitude)
             || r.data into v_data from public.customers where id = r.customer_id;
    end if;
    v_cid := app.dealer_customer_write(r.business_id, r.dealer_id, r.customer_id, v_data);
  end if;
  update public.customer_requests set status = case when p_approve then 'onaylandi' else 'reddedildi' end,
         decided_by = auth.uid(), decided_at = now(), decision_note = nullif(left(trim(coalesce(p_note, '')), 300), ''),
         result_customer_id = v_cid
   where id = p_request;
  return v_cid;
end $$;

-- Personel: kendi önerisini (yönetici: herhangi birini) geri çeker
create or replace function public.cancel_customer_request(p_request uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.customer_requests;
begin
  select * into r from public.customer_requests where id = p_request for update;
  if r.id is null then raise exception 'Öneri bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(r.business_id, 'yonetici', 'satis');
  if r.requested_by is distinct from auth.uid() and not app.has_role(r.business_id, 'yonetici') then
    raise exception 'Yalnızca kendi önerinizi geri çekebilirsiniz' using errcode = '42501';
  end if;
  if r.status <> 'bekliyor' then raise exception 'Bu öneri zaten sonuçlandı' using errcode = 'P0001'; end if;
  update public.customer_requests set status = 'iptal', decided_by = auth.uid(), decided_at = now() where id = p_request;
end $$;

-- ---------------------------------------------------------------- sevkiyat yönlendirme kaydı
create table if not exists public.order_routing_log (
  id           bigserial primary key,
  business_id  uuid not null references public.businesses(id),
  order_id     uuid not null references public.orders(id),
  from_dealer  uuid references public.customers(id),
  to_dealer    uuid references public.customers(id),
  special      boolean not null,
  note         text check (note is null or length(note) <= 500),
  created_by   uuid,
  created_at   timestamptz not null default now()
);
create index if not exists order_routing_log_business on public.order_routing_log(business_id, created_at desc);
create index if not exists order_routing_log_order on public.order_routing_log(order_id);
alter table public.order_routing_log enable row level security;
-- Yalnızca yönetici görür (G-17)
create policy order_routing_log_select on public.order_routing_log for select to authenticated
  using (app.has_role(business_id, 'yonetici'));
drop trigger if exists order_routing_log_immutable on public.order_routing_log;
create trigger order_routing_log_immutable before update or delete on public.order_routing_log
  for each row execute function app.tg_immutable();

-- Bayiye ver / bayiden al. Özel durumlar: kurumsal/bayi kanalı sipariş bayiye, bayinin kendi müşterisinin
-- sevkiyatı başkasına → yalnızca sevkiyat sorumlusu veya yönetici, gerekçe zorunlu.
drop function if exists public.assign_order_dealer(uuid, uuid);
create or replace function public.assign_order_dealer(p_order uuid, p_dealer uuid, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders; v_channel text; v_owner uuid; v_role public.member_role; v_special boolean; v_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  select * into o from public.orders where id = p_order for update;
  if o.id is null then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
  v_role := app.require_role(o.business_id, 'yonetici', 'satis');
  if o.status <> 'acik' then raise exception 'Yalnızca açık (onaylanmış) sipariş yönlendirilebilir' using errcode = 'P0001'; end if;
  if o.dealer_customer_id is not distinct from p_dealer then return; end if;
  if p_dealer is not null and not exists (select 1 from public.customers where id = p_dealer and business_id = o.business_id
                                            and channel = 'bayi' and active) then
    raise exception 'Bayi bulunamadı' using errcode = '22023';
  end if;
  if p_dealer is not null and p_dealer = o.customer_id then raise exception 'Bayinin kendi alımı kendisine verilemez' using errcode = 'P0001'; end if;
  select channel, owner_dealer_id into v_channel, v_owner from public.customers where id = o.customer_id;
  v_special := (p_dealer is not null and v_channel <> 'perakende')
            or (v_owner is not null and o.dealer_customer_id is not distinct from v_owner);
  if v_special then
    if v_role not in ('yonetici', 'sevkiyat') then
      raise exception 'Bu özel yönlendirmeyi yalnızca sevkiyat sorumlusu veya yönetici yapabilir' using errcode = '42501';
    end if;
    if length(coalesce(v_note, '')) < 3 then
      raise exception 'Özel yönlendirme için gerekçe yazın' using errcode = '22023';
    end if;
  end if;
  update public.orders set dealer_customer_id = p_dealer, requested_dealer_id = null,
         assignee = case when p_dealer is not null then null else assignee end,
         route_seq = null, dealer_note = null
   where id = p_order;
  insert into public.order_routing_log(business_id, order_id, from_dealer, to_dealer, special, note, created_by)
  values (o.business_id, o.id, o.dealer_customer_id, p_dealer, v_special, left(v_note, 500), auth.uid());
end $$;

select app.apply_grants();
insert into supabase_migrations.schema_migrations(version, name) values ('20261010001900', 'dealer_privacy_routing') on conflict do nothing;
commit;
select (select count(*) from pg_trigger where tgname='customers_dealer_guard') as koruma, (select count(*) from pg_proc where proname in ('propose_dealer_customer','decide_customer_request','cancel_customer_request','assign_order_dealer')) as fonk, (select max(version) from supabase_migrations.schema_migrations) as surum;
