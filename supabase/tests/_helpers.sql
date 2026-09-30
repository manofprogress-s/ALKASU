-- Test yardımcıları ve ortak test verisi (yalnızca test veritabanında)
create schema if not exists test;
grant usage on schema test to authenticated, anon;

create or replace function test.ok(p boolean, p_desc text) returns void language plpgsql as $$
begin
  if p is distinct from true then raise exception 'not ok - %', p_desc; end if;
  raise notice 'ok - %', p_desc;
end $$;

create or replace function test.eq(p_got anycompatible, p_want anycompatible, p_desc text) returns void language plpgsql as $$
begin
  if p_got is distinct from p_want then
    raise exception 'not ok - % (beklenen: %, gelen: %)', p_desc, p_want, p_got;
  end if;
  raise notice 'ok - %', p_desc;
end $$;

-- SQL hata vermeli; mesaj p_like'a (ILIKE) uymalı
create or replace function test.throws(p_sql text, p_like text, p_desc text) returns void language plpgsql as $$
declare v_msg text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if p_like is not null and v_msg not ilike p_like then
      raise exception 'not ok - % (beklenen hata: %, gelen: %)', p_desc, p_like, v_msg;
    end if;
    raise notice 'ok - %', p_desc;
    return;
  end;
  raise exception 'not ok - % (hata bekleniyordu, gelmedi)', p_desc;
end $$;

create or replace function test.lives(p_sql text, p_desc text) returns void language plpgsql as $$
begin
  execute p_sql;
  raise notice 'ok - %', p_desc;
end $$;

-- Kullanıcı olarak oturum aç / kapat
create or replace function test.login(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create or replace function test.logout() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

-- Sabit kullanıcılar
create or replace function test.u_admin()    returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-00000000000a'::uuid $$;
create or replace function test.u_satis()    returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-00000000000b'::uuid $$;
create or replace function test.u_depo()     returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-00000000000c'::uuid $$;
create or replace function test.u_izleyici() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-00000000000d'::uuid $$;
create or replace function test.u_admin_b()  returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-00000000000e'::uuid $$;
create or replace function test.u_outsider() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-00000000000f'::uuid $$;

create or replace function test.biz() returns uuid language sql stable security definer as $$
  select business_id from public.memberships where user_id = test.u_admin()
$$;
create or replace function test.biz_b() returns uuid language sql stable security definer as $$
  select business_id from public.memberships where user_id = test.u_admin_b()
$$;
create or replace function test.pid(p_code text) returns uuid language sql stable security definer as $$
  select id from public.products where business_id = test.biz() and code = p_code
$$;
create or replace function test.unit(p_code text, p_unit text) returns uuid language sql stable security definer as $$
  select u.id from public.product_units u join public.products p on p.id = u.product_id
   where p.business_id = test.biz() and p.code = p_code and u.name = p_unit and u.active
$$;
create or replace function test.stock(p_code text) returns int language sql stable security definer as $$
  select coalesce((select qty from public.stock_levels where product_id = test.pid(p_code)), 0)
$$;
create or replace function test.cust(p_code text) returns uuid language sql stable security definer as $$
  select id from public.customers where business_id = test.biz() and code = p_code
$$;
create or replace function test.balance(p_code text) returns numeric language sql stable security definer as $$
  select coalesce(sum(amount), 0) from public.customer_ledger where customer_id = test.cust(p_code)
$$;
create or replace function test.avg_cost(p_code text) returns numeric language sql stable security definer as $$
  select avg_cost from public.product_costs where product_id = test.pid(p_code)
$$;
create or replace function test.open_session() returns uuid language sql stable security definer as $$
  select id from public.cash_sessions where business_id = test.biz() and status = 'acik'
$$;
create or replace function test.cash_expected() returns numeric language sql stable security definer as $$
  select s.opening_cash + coalesce((select sum(amount) from public.cash_movements m
                                     where m.session_id = s.id and m.type <> 'gun_sonu_teslim'), 0)
    from public.cash_sessions s where s.business_id = test.biz() and s.status = 'acik'
$$;
grant execute on all functions in schema test to authenticated;

-- Basit satış: tek kalem, nakit
create or replace function test.sell(p_code text, p_unit text, p_qty int, p_extra jsonb default '{}') returns jsonb
language plpgsql as $$
declare v_price numeric; v_total numeric;
begin
  select price into v_price from public.product_units where id = test.unit(p_code, p_unit);
  v_total := v_price * p_qty;
  return public.complete_sale(test.biz(), jsonb_build_object(
    'id', gen_random_uuid(),
    'items', jsonb_build_array(jsonb_build_object('product_id', test.pid(p_code), 'unit_id', test.unit(p_code, p_unit),
                                                  'qty', p_qty, 'unit_price', v_price)),
    'payments', jsonb_build_array(jsonb_build_object('method', 'nakit', 'amount', v_total))) || p_extra);
end $$;
grant execute on function test.sell(text, text, int, jsonb) to authenticated;

-- Ortak veri: işletme A (4 rol), işletme B (ayrı yönetici), ürünler, müşteri
create or replace function test.fixture() returns void language plpgsql as $$
declare b uuid; bb uuid; v_brand uuid; v_cat uuid; v_empty uuid;
begin
  insert into auth.users(id, email) values
    (test.u_admin(), 'yonetici@test'), (test.u_satis(), 'satis@test'), (test.u_depo(), 'depo@test'),
    (test.u_izleyici(), 'izleyici@test'), (test.u_admin_b(), 'yonetici-b@test'), (test.u_outsider(), 'yabanci@test');
  b  := public.create_business('Test İşletmesi', test.u_admin(), 'Yönetici A');
  bb := public.create_business('Diğer İşletme', test.u_admin_b(), 'Yönetici B');
  insert into public.memberships(business_id, user_id, role, display_name) values
    (b, test.u_satis(), 'satis', 'Satış A'), (b, test.u_depo(), 'depo', 'Depo A'), (b, test.u_izleyici(), 'izleyici', 'İzleyici A');

  perform test.login(test.u_admin());
  v_brand := public.upsert_brand(b, 'Örnek Marka');
  v_cat   := public.upsert_category(b, 'Su');
  v_empty := public.upsert_product(b, jsonb_build_object('code', 'BK-001', 'name', 'Boş Damacana', 'brand_id', v_brand,
             'category_id', v_cat, 'base_unit_name', 'Adet', 'vat_rate', 20, 'is_container', true));
  perform public.upsert_product(b, jsonb_build_object('code', 'DM-001', 'name', '19 L Damacana', 'brand_id', v_brand,
             'category_id', v_cat, 'base_unit_name', 'Damacana', 'base_price', 120, 'vat_rate', 1,
             'deposit_amount', 250, 'empty_product_id', v_empty, 'critical_level', 10));
  perform public.upsert_product(b, jsonb_build_object('code', 'SU-005', 'name', '0,5 L Su', 'brand_id', v_brand,
             'category_id', v_cat, 'base_unit_name', 'Şişe', 'base_price', 10, 'vat_rate', 1, 'critical_level', 48,
             'units', jsonb_build_array(jsonb_build_object('name', 'Paket', 'factor', 6, 'price', 55),
                                        jsonb_build_object('name', 'Koli', 'factor', 24, 'price', 200)),
             'barcodes', jsonb_build_array(jsonb_build_object('barcode', '8690000000028'),
                                           jsonb_build_object('barcode', '8690000000035', 'unit_name', 'Koli'))));
  perform public.upsert_customer(b, jsonb_build_object('code', 'M001', 'name', 'Ahmet Bakkal', 'credit_limit', 1000));
  perform public.upsert_customer(b, jsonb_build_object('code', 'M002', 'name', 'Limitsiz Firma', 'unlimited_credit', true));
  perform public.upsert_customer(b, jsonb_build_object('code', 'M003', 'name', 'Peşinci Müşteri'));
  -- Açılış stoğu: mal kabul (maliyet: su 6,00 / damacana 80,00)
  perform public.receive_goods(b, jsonb_build_object('id', gen_random_uuid(), 'items', jsonb_build_array(
    jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005', 'Koli'), 'qty', 10, 'unit_cost', 144),
    jsonb_build_object('product_id', test.pid('DM-001'), 'unit_id', test.unit('DM-001', 'Damacana'), 'qty', 50, 'unit_cost', 80))));
  perform test.logout();
end $$;
