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
