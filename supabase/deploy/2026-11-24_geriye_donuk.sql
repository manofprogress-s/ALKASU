-- Canlı: geriye dönük sipariş/teslimat, başkası ve bayi adına kapatma (0049, O-30..O-33, D-111) + Hüseyin'e yetki
begin;
-- ALKASU 0049 — Geriye dönük sipariş ve teslimat kaydı, bayi adına kapatma (O-30..O-33, D-111)
-- Kullanıcı (24.11): gün içinde uygulamaya girilemeyen siparişler manuel formlardan en fazla 2 hafta geriye girilip
-- kapatılabilsin (Hüseyin ve yönetici); İbrahim'in (Sağlam Ticaret, bayi) bıraktığı ama kapatmayı unuttuğu siparişler
-- Hüseyin ve yönetici tarafından "İbrahim teslim etti" olarak kapatılabilsin.

-- Kullanıcıya özel yetki: geriye dönük kayıt (yönetici her zaman yetkili)
alter table public.memberships add column if not exists can_backdate boolean not null default false;
alter table public.orders add column if not exists recorded_by uuid;   -- başkası adına / geçmiş tarihli kaydı giren kişi

create or replace function app.can_backdate(p_business uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.memberships m
                  where m.business_id = p_business and m.user_id = auth.uid() and m.active
                    and (m.role = 'yonetici' or (m.can_backdate and m.role in ('satis', 'sevkiyat'))))
$$;

create or replace function public.set_member_backdate(p_membership uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare m public.memberships;
begin
  select * into m from public.memberships where id = p_membership;
  if m.id is null then raise exception 'Kullanıcı bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(m.business_id, 'yonetici');
  if m.role not in ('satis', 'sevkiyat', 'yonetici') then raise exception 'Bu yetki yalnızca personele verilir' using errcode = '22023'; end if;
  update public.memberships set can_backdate = coalesce(p_on, false) where id = p_membership;
  perform app.audit(m.business_id, 'yetki_geriye_donuk', 'memberships', p_membership::text,
                    jsonb_build_object('can_backdate', m.can_backdate), jsonb_build_object('can_backdate', coalesce(p_on, false)));
end $$;

-- Hareketlerin tarihi: geçmiş tarihli teslimatta işlem süresince 'alkasu.effective_at' ayarlanır, yoksa şimdi
create or replace function app.effective_now() returns timestamptz
language sql stable set search_path = pg_catalog, pg_temp as $$
  select coalesce(nullif(current_setting('alkasu.effective_at', true), '')::timestamptz, now())
$$;
alter table public.customer_ledger  alter column created_at set default app.effective_now();
alter table public.container_ledger alter column created_at set default app.effective_now();
alter table public.stock_movements  alter column created_at set default app.effective_now();

-- O-30: geçmiş tarihli sipariş (save_order: 0037 gövdesi + tarih kontrolü)
create or replace function public.save_order(p_business uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  -- O-30: personel geçmiş tarihli siparişi yalnızca geriye dönük kayıt yetkisiyle ve en fazla 14 gün geriye girer
  if not v_self and v_date < app.local_date(now())
     and v_date is distinct from (select x.delivery_date from public.orders x where x.id = v_id) then
    if not app.can_backdate(p_business) then
      raise exception 'Geçmiş tarihli siparişi yalnızca geriye dönük kayıt yetkisi olan kişi girebilir (O-30)' using errcode = '42501';
    end if;
    if v_date < app.local_date(now()) - 14 then
      raise exception 'En fazla 14 gün geriye sipariş girilebilir (O-30)' using errcode = '22023';
    end if;
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
end $function$;

-- O-31/O-32: geçmiş tarihli teslimat ve başkası adına kapatma (deliver_order: 0037 gövdesi + tarih/teslim eden)
create or replace function public.deliver_order(p_business uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_role public.member_role := app.require_role(p_business, 'yonetici', 'satis');
  o      public.orders;
  v_items jsonb := '[]';
  oi     record;
  v_qty  int;
  v_res  jsonb;
  v_at   timestamptz := coalesce(nullif(p->>'delivered_at', '')::timestamptz, now());   -- O-31: teslim zamanı
  v_back boolean;
  v_behalf boolean;
  v_by   uuid;
begin
  select * into o from public.orders where id = (p->>'order_id')::uuid and business_id = p_business for update;
  if o.id is null then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
  if o.status = 'teslim_edildi' and o.sale_id = (p->>'sale_id')::uuid then
    return jsonb_build_object('order_id', o.id, 'sale_id', o.sale_id, 'duplicate', true);
  end if;
  if o.status = 'onay_bekliyor' then raise exception 'Sipariş henüz onaylanmadı' using errcode = 'P0001'; end if;
  if o.status <> 'acik' then raise exception 'Sipariş açık değil' using errcode = 'P0001'; end if;
  if o.dealer_customer_id is not null then raise exception 'Bu sipariş bayiye atanmış; teslimatı bayi kaydeder' using errcode = 'P0001'; end if;
  -- O-32: atanan kişi, yönetici veya geriye dönük kayıt yetkilisi kapatır; başkası adına kapatılırsa teslim eden atanan kişidir
  if v_role <> 'yonetici' and o.assignee is distinct from auth.uid() and not app.can_backdate(p_business) then
    raise exception 'Bu siparişi yalnızca atanan kişi veya yönetici kapatabilir' using errcode = '42501';
  end if;
  v_behalf := o.assignee is not null and o.assignee <> auth.uid();
  v_by := case when v_behalf then o.assignee else auth.uid() end;
  -- O-31: geçmiş tarihli teslim (en fazla 14 gün), yalnızca geriye dönük kayıt yetkisiyle
  if v_at > now() + interval '5 minutes' then raise exception 'Teslim zamanı ileri bir tarih olamaz' using errcode = '22023'; end if;
  v_back := v_at < now() - interval '10 minutes';
  if v_back then
    if not app.can_backdate(p_business) then
      raise exception 'Geçmiş tarihli teslimatı yalnızca geriye dönük kayıt yetkisi olan kişi girebilir (O-31)' using errcode = '42501';
    end if;
    if v_at < now() - interval '14 days' then raise exception 'En fazla 14 gün geriye teslimat girilebilir (O-31)' using errcode = '22023'; end if;
    perform set_config('alkasu.effective_at', v_at::text, true);   -- cari/kap/stok hareketleri teslim tarihiyle yazılır
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
  perform set_config('alkasu.effective_at', '', true);
  if v_back or v_behalf then
    -- Satış teslim tarihinde ve teslim edenin adına; para kasaya bugün girdiğinden kasa açılışından önceyse "geç kayıt"
    update public.sales s set sold_at = v_at, created_by = v_by,
           late_sync = v_back and v_at < (select cs.opened_at from public.cash_sessions cs where cs.id = s.session_id)
     where s.id = (v_res->>'id')::uuid;
  end if;

  update public.orders set status = 'teslim_edildi', delivered_by = v_by, delivered_at = v_at,
         recorded_by = case when v_back or v_behalf then auth.uid() end,
         sale_id = (v_res->>'id')::uuid where id = o.id;
  perform app.audit(p_business, 'siparis_teslim', 'orders', o.id::text, null,
                    v_res || jsonb_build_object('teslim_zamani', v_at, 'teslim_eden', v_by, 'kaydeden', auth.uid(), 'gecmis_tarihli', v_back));
  return v_res || jsonb_build_object('order_id', o.id, 'order_no', o.no);
end $function$;

-- O-33: bayiye verilmiş siparişi bayi adına "teslim edildi" kapatma (bayinin teslimatı bayinin kendi satışıdır, D-054:
-- bizde stok/kasa/cari hareketi oluşmaz). Teslim eden bayi kullanıcısı, kaydeden giriş yapan kişi.
create or replace function public.complete_dealer_order_for(p_order uuid, p_note text default null, p_delivered_at timestamptz default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders; v_at timestamptz := coalesce(p_delivered_at, now()); v_dealer_user uuid;
begin
  select * into o from public.orders where id = p_order for update;
  if o.id is null then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(o.business_id, 'yonetici', 'satis');
  if not app.can_backdate(o.business_id) then
    raise exception 'Bayi adına kapatmayı yalnızca geriye dönük kayıt yetkisi olan kişi yapabilir (O-33)' using errcode = '42501';
  end if;
  if o.dealer_customer_id is null then raise exception 'Bu sipariş bayiye verilmemiş' using errcode = 'P0001'; end if;
  if o.status <> 'acik' then raise exception 'Sipariş açık değil' using errcode = 'P0001'; end if;
  if v_at > now() + interval '5 minutes' then raise exception 'Teslim zamanı ileri bir tarih olamaz' using errcode = '22023'; end if;
  if v_at < now() - interval '14 days' then raise exception 'En fazla 14 gün geriye teslimat girilebilir (O-31)' using errcode = '22023'; end if;
  select m.user_id into v_dealer_user from public.memberships m
   where m.business_id = o.business_id and m.customer_id = o.dealer_customer_id and m.role = 'bayi' and m.active
   order by m.created_at limit 1;
  update public.orders set status = 'teslim_edildi', delivered_by = v_dealer_user, delivered_at = v_at,
         recorded_by = auth.uid(), dealer_note = coalesce(nullif(trim(p_note), ''), 'Bayi adına kapatıldı')
   where id = p_order;
  perform app.audit(o.business_id, 'bayi_adina_teslim', 'orders', o.id::text, null,
                    jsonb_build_object('teslim_zamani', v_at, 'bayi', o.dealer_customer_id, 'teslim_eden', v_dealer_user, 'kaydeden', auth.uid()));
end $$;

select app.apply_grants();

-- Kullanıcı isteği: Hüseyin'e geriye dönük kayıt yetkisi (yönetici zaten yetkili)
update public.memberships set can_backdate = true where username = 'htopal' and role = 'sevkiyat';
select 'SONUC: yetkili=' || (select string_agg(display_name, ',') from public.memberships where can_backdate)
    || ' | fonksiyon=' || (select count(*) from pg_proc where proname in ('complete_dealer_order_for','set_member_backdate','can_backdate','effective_now'))
    || ' | varsayilan=' || (select column_default from information_schema.columns where table_name = 'customer_ledger' and column_name = 'created_at') as sonuc;
commit;
