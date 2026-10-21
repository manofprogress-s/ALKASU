-- ALKASU 0037 — Eve teslim ve kurumsal fiyat listeleri (kullanıcı 21.10)
-- Kural: BUSINESS_RULES F-14…F-16 (fiyat) · Karar: D-097
-- • Gel al (dükkân) fiyatı = perakende (product_units.price). Satış ekranında ev müşterisi gel al fiyatı öder.
-- • Eve teslim ('ev' listesi): ev müşterisinin TÜM siparişlerinde (müşteri, internet, personel, bayi) uygulanır.
--   Listede fiyat yoksa gel al + 40 TL (kullanıcı kararı). Müşteri ekranları yalnızca ev fiyatını görür.
-- • Kurumsal ('kurumsal' listesi): kurumsal kartların her yerde (sipariş + dükkân) fiyatı; listede yoksa gel al × 1,5.
--   Firmaya özel (anlaşmalı) fiyat varsa o geçer (F-13).
-- • Depozito: eve teslim siparişinde products.deposit_ev (yoksa normal depozito); kurumsal ve dükkân normal depozito.

alter table public.customers drop constraint if exists customers_price_list_check;
alter table public.customers add constraint customers_price_list_check check (price_list in ('perakende', 'bayi', 'palet', 'kurumsal'));
alter table public.product_list_prices drop constraint if exists product_list_prices_price_list_check;
alter table public.product_list_prices add constraint product_list_prices_price_list_check check (price_list in ('bayi', 'palet', 'ev', 'kurumsal'));
alter table public.products add column if not exists deposit_ev numeric(14,2) check (deposit_ev > 0);

-- Siparişte kullanılan liste: ev müşterisinin (perakende) siparişi eve teslim fiyatıyla
create or replace function app.order_list(p_list text) returns text
language sql immutable as $$ select case when coalesce(p_list, 'perakende') = 'perakende' then 'ev' else p_list end $$;

-- Listeye göre güncel fiyat (istemcideki lib/catalog.ts unitPrice ile aynı kural)
create or replace function app.unit_list_price(p_unit uuid, p_list text) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select case coalesce(p_list, 'perakende')
           when 'perakende' then u.price
           when 'ev' then coalesce(lp.price, u.price + 40)
           when 'kurumsal' then coalesce(lp.price, round(u.price * 1.5, 2))
           else coalesce(lp.price, u.price) end
    from public.product_units u
    left join public.product_list_prices lp on lp.unit_id = u.id and lp.price_list = p_list
   where u.id = p_unit
$$;

-- Belirli andaki liste fiyatı (çevrimdışı doğrulama): listede geçmiş kayıt yoksa aynı kural perakende geçmişine uygulanır
create or replace function app.unit_price_at(p_unit uuid, p_at timestamptz, p_list text) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(
    (select price from public.product_prices where unit_id = p_unit and price_list = coalesce(p_list, 'perakende')
       and valid_from <= p_at order by valid_from desc, id desc limit 1),
    case coalesce(p_list, 'perakende')
      when 'ev' then app.unit_price_at(p_unit, p_at) + 40
      when 'kurumsal' then round(app.unit_price_at(p_unit, p_at) * 1.5, 2)
      else app.unit_price_at(p_unit, p_at) end)
$$;

-- Kart kanalı ↔ fiyat listesi: kurumsal kart kurumsal listeye, kurumsaldan çıkan kart perakendeye
create or replace function app.tg_customer_channel_list() returns trigger language plpgsql as $$
begin
  if new.channel = 'kurumsal' and new.price_list = 'perakende' then new.price_list := 'kurumsal'; end if;
  if new.channel <> 'kurumsal' and new.price_list = 'kurumsal' then new.price_list := 'perakende'; end if;
  return new;
end $$;
drop trigger if exists customers_channel_list on public.customers;
create trigger customers_channel_list before insert or update of channel, price_list on public.customers
  for each row execute function app.tg_customer_channel_list();
update public.customers set price_list = 'kurumsal' where channel = 'kurumsal' and price_list = 'perakende';

-- Müşteri/bayi: eve teslim fiyatları herkese açık (müşteri ekranı), kendi listesi ayrıca
create or replace function app.my_price_list(p_business uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select case when c.price_list = 'perakende' then 'ev' else c.price_list end
    from public.customers c where c.id = app.my_customer(p_business)
$$;
drop policy if exists list_prices_select on public.product_list_prices;
create policy list_prices_select on public.product_list_prices for select to authenticated
  using (app.is_staff(business_id) or price_list = 'ev' or price_list = app.my_price_list(business_id));

-- Müşteri mağazası ve "Hızlı sipariş": yalnızca eve teslim fiyatı (gel al fiyatı gösterilmez)
create or replace function public.public_catalog()
returns table(product_id uuid, product_name text, unit_id uuid, unit_name text, factor integer, price numeric, has_deposit boolean,
              product_code text, brand_name text, category_name text, image_path text, popularity integer,
              sort integer, section text, section_rank integer, top_rank integer)
language sql stable security definer set search_path = public, pg_temp as $$
  select product_id, product_name, unit_id, unit_name, factor, app.unit_list_price(unit_id, 'ev'), has_deposit, product_code, brand_name,
         category_name, image_path, popularity, sort, section, section_rank, top_rank
    from app.shop_catalog(app.public_business(), false)
   where app.unit_list_price(unit_id, 'ev') is not null
$$;

-- Mağaza düzeni ekranı müşterinin gördüğünü gösterir
create or replace function public.shop_catalog_admin(p_business uuid)
returns table(product_id uuid, product_name text, unit_id uuid, unit_name text, factor integer, price numeric, has_deposit boolean,
              product_code text, brand_name text, category_name text, image_path text, popularity integer,
              hidden boolean, sort integer, section text, section_rank integer, top_rank integer)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform app.require_role(p_business, 'yonetici');
  return query select s.product_id, s.product_name, s.unit_id, s.unit_name, s.factor, app.unit_list_price(s.unit_id, 'ev'), s.has_deposit,
                      s.product_code, s.brand_name, s.category_name, s.image_path, s.popularity, s.hidden, s.sort, s.section,
                      s.section_rank, s.top_rank
                 from app.shop_catalog(p_business, true) s;
end $$;

create or replace function public.set_list_price(p_unit uuid, p_list text, p_price numeric) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bid uuid; v_old numeric;
begin
  select business_id into v_bid from public.product_units where id = p_unit;
  if v_bid is null then raise exception 'Birim bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(v_bid, 'yonetici');
  if p_list = 'perakende' then perform public.set_unit_price(p_unit, p_price); return; end if;
  if p_list not in ('bayi', 'palet', 'ev', 'kurumsal') then raise exception 'Fiyat listesi geçersiz' using errcode = '22023'; end if;
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
    foreach f in array array['perakende_fiyati', 'bayi_fiyati', 'palet_fiyati', 'ev_fiyati', 'kurumsal_fiyati'] loop
      if not app.blank(r->>f) and coalesce(app.num(r->>f), -1) < 0 then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'field', f, 'message', 'Geçerli bir tutar değil');
      end if;
    end loop;
    if not p_dry_run and jsonb_array_length(v_errs) = 0 then
      if not app.blank(r->>'perakende_fiyati') then perform public.set_list_price(v_unit, 'perakende', app.num(r->>'perakende_fiyati')); end if;
      if not app.blank(r->>'bayi_fiyati') then perform public.set_list_price(v_unit, 'bayi', app.num(r->>'bayi_fiyati')); end if;
      if not app.blank(r->>'palet_fiyati') then perform public.set_list_price(v_unit, 'palet', app.num(r->>'palet_fiyati')); end if;
      if not app.blank(r->>'ev_fiyati') then perform public.set_list_price(v_unit, 'ev', app.num(r->>'ev_fiyati')); end if;
      if not app.blank(r->>'kurumsal_fiyati') then perform public.set_list_price(v_unit, 'kurumsal', app.num(r->>'kurumsal_fiyati')); end if;
    end if;
    v_n := v_n + 1;
  end loop;
  if jsonb_array_length(v_errs) > 0 and not p_dry_run then
    raise exception 'Fiyat listesinde hata var: %', v_errs using errcode = '22023';
  end if;
  return jsonb_build_object('ok', jsonb_array_length(v_errs) = 0, 'applied', not p_dry_run, 'errors', v_errs,
                            'warnings', '[]'::jsonb, 'summary', jsonb_build_object('rows', v_n));
end $$;

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
  v_list  numeric;
  v_special int := 0;
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
            coalesce(nullif(trim(p->>'address'), ''), c.address), nullif(trim(p->>'note'), ''), app.order_list(c.price_list), auth.uid(),
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
    update public.orders set customer_id = c.id, price_list = app.order_list(c.price_list), delivery_date = v_date,
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
    -- O-20: personel (yönetici, satış, sevkiyat) siparişte özel fiyat verebilir; bayi/müşteri veremez.
    v_list := app.customer_unit_price(c.id, u.id, app.order_list(c.price_list));   -- F-13
    v_price := case when not v_self and nullif(it->>'unit_price', '') is not null
                    then round((it->>'unit_price')::numeric, 2) else v_list end;
    if v_price is null then raise exception 'Bu birimin fiyatı tanımlı değil: % %', pr.name, u.name using errcode = 'P0001'; end if;
    if v_price < 0 or v_price > 1000000 then raise exception 'Fiyat geçersiz: %', pr.name using errcode = '22023'; end if;
    if v_price is distinct from v_list then v_special := v_special + 1; end if;
    insert into public.order_items(order_id, business_id, line_no, product_id, unit_id, qty, unit_price, list_price)
    values (v_id, p_business, v_line, pr.id, u.id, (it->>'qty')::int, v_price, v_list);
  end loop;

  if v_special > 0 then
    perform app.audit(p_business, 'siparis_ozel_fiyat', 'orders', o.id::text, null,
                      jsonb_build_object('kalem', v_special, 'kalemler',
                        (select jsonb_agg(jsonb_build_object('urun', p2.name, 'liste', oi.list_price, 'ozel', oi.unit_price))
                           from public.order_items oi join public.products p2 on p2.id = oi.product_id
                          where oi.order_id = o.id and oi.unit_price is distinct from oi.list_price)));
  end if;
  return jsonb_build_object('id', o.id, 'no', o.no, 'status', o.status, 'special_prices', v_special);
end $$;

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
    'cash_given', p->'cash_given', 'note', coalesce(nullif(trim(p->>'note'), ''), 'Sipariş #' || o.no),
    'deposit_list', o.price_list), v_role, true);

  update public.orders set status = 'teslim_edildi', delivered_by = auth.uid(), delivered_at = now(),
         sale_id = (v_res->>'id')::uuid where id = o.id;
  perform app.audit(p_business, 'siparis_teslim', 'orders', o.id::text, null, v_res);
  return v_res || jsonb_build_object('order_id', o.id, 'order_no', o.no);
end $$;

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
      v_cur := app.customer_unit_price(v_cust.id, u.id, v_list);   -- F-13: firmaya özel fiyat önce
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
      round(v_qty * v_price, 2), v_ldisc, 0, null, pr.vat_rate,
      case when p->>'deposit_list' = 'ev' then coalesce(pr.deposit_ev, pr.deposit_amount) else pr.deposit_amount end,   -- F-16: eve teslim depozitosu
      pr.empty_product_id);
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
  -- D-07: fazla boş kap iadesi ürün tutarını aşarsa fark müşterinin cari hesabına ALACAK yazılır (ödeme alınmaz)
  if v_grand < 0 and v_cust.id is null then
    raise exception 'Fazla boş kap iadesi için müşteri seçilmelidir' using errcode = '22023';
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
  if v_grand < 0 then
    if v_pay_total <> 0 then
      raise exception 'Fiş toplamı eksi: ödeme girilmez, fark müşterinin hesabına alacak yazılır' using errcode = '22023';
    end if;
    insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, ref_id, created_by)
    values (p_business, v_cust.id, 'depozito_mahsup', v_grand, 'sale', v_id, auth.uid());
  elsif v_pay_total <> v_grand then
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

select app.apply_grants();
