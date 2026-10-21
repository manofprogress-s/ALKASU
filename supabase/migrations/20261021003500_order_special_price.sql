-- ALKASU 0035 — Siparişte özel fiyat (kullanıcı isteği 21.10)
-- Kural: BUSINESS_RULES O-20 · Karar: D-094
-- Personel (yönetici, satış, sevkiyat) sipariş kalemine özel birim fiyat girebilir; liste fiyatı ayrıca saklanır,
-- siparişte "Özel fiyat" olarak görünür ve denetim kaydına yazılır. Bayi ve müşteri fiyat değiştiremez.

alter table public.order_items add column if not exists list_price numeric(14,2);

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
    -- O-20: personel (yönetici, satış, sevkiyat) siparişte özel fiyat verebilir; bayi/müşteri veremez.
    v_list := app.customer_unit_price(c.id, u.id, c.price_list);   -- F-13
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

select app.apply_grants();
