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
