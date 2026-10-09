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
