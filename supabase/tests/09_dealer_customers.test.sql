-- Bayinin kendi müşterileri ve sipariş girişi; başka bayiye / merkeze açılan sipariş onay bekler (D-059..D-062)
begin;
select test.fixture();

create function test.u_b1() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000031'::uuid $$;
create function test.u_b2() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000032'::uuid $$;
create function test.u_sv() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000033'::uuid $$;
create function test.ord(p_id uuid) returns public.orders language sql stable security definer as $$ select * from public.orders where id = p_id $$;
create function test.cust_by_name(p text) returns uuid language sql stable security definer as $$ select id from public.customers where name = p $$;
create function test.item(p_code text, p_unit text, p_qty int) returns jsonb language sql stable security definer as $$
  select jsonb_build_object('product_id', test.pid(p_code), 'unit_id', test.unit(p_code, p_unit), 'qty', p_qty)
$$;
grant execute on all functions in schema test to authenticated;
insert into auth.users(id, email) values (test.u_b1(), 'b1@t'), (test.u_b2(), 'b2@t'), (test.u_sv(), 'sv@t');

select test.login(test.u_admin());
select public.upsert_customer(test.biz(), '{"code":"B001","name":"Sağlam Ticaret","channel":"bayi","price_list":"bayi"}'::jsonb);
select public.upsert_customer(test.biz(), '{"code":"B002","name":"Yıldız Ticaret","channel":"bayi","price_list":"bayi"}'::jsonb);
select public.add_member(test.biz(), test.u_b1(), 'bayi', 'İbrahim', test.cust('B001'));
select public.add_member(test.biz(), test.u_b2(), 'bayi', 'Hüseyin Y', test.cust('B002'));
select public.add_member(test.biz(), test.u_sv(), 'sevkiyat', 'Hüseyin T');

-- ---------------------------------------------------------------- bayinin müşteri listesi
select test.login(test.u_b1());
select public.dealer_upsert_customer(test.biz(), '{"name":"Kartepe Ev 1","phone":"05320000001","address":"Kartepe Mah.","latitude":40.75,"longitude":30.02}'::jsonb);
select public.dealer_upsert_customer(test.biz(), '{"name":"Sapanca Ev 2","address":"Sapanca"}'::jsonb);
select test.eq((select count(*) from public.customers where owner_dealer_id = test.cust('B001'))::int, 2, 'Bayi kendi müşterilerini ekler ve görür');
select test.eq((select channel || '/' || price_list from public.customers where name = 'Kartepe Ev 1'), 'perakende/perakende', 'Bayi müşterisi ev müşterisidir');
select test.eq((select count(*) from public.customers)::int, 3, 'Bayi yalnızca kendi kartını ve müşterilerini görür');
select test.throws($$select public.dealer_upsert_customer(test.biz(), jsonb_build_object('id', test.cust('M001'), 'name', 'Xyz'))$$, '%size ait değil%',
  'Bayi başkasının müşteri kartını değiştiremez');
select test.throws($$select public.dealer_upsert_customer(test.biz(), '{"name":" "}'::jsonb)$$, '%zorunlu%', 'Müşteri adı zorunlu');
select public.dealer_upsert_customer(test.biz(), jsonb_build_object('id', test.cust_by_name('Sapanca Ev 2'), 'name', 'Sapanca Ev 2', 'phone', '05320000002'));
select test.eq((select phone from public.customers where name = 'Sapanca Ev 2'), '05320000002', 'Bayi kendi müşterisini düzenler');
select test.eq((select count(*) from public.dealer_list(test.biz()))::int, 2, 'Bayi teslim eden seçimi için bayi listesini görür');

select test.login(test.u_b2());
select test.eq((select count(*) from public.customers)::int, 1, 'Diğer bayi bu müşterileri görmez');
select test.throws($$select public.save_order(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'customer_id', test.cust_by_name('Kartepe Ev 1'), 'items', jsonb_build_array(test.item('SU-005', 'Koli', 1))))$$,
  '%size ait değil%', 'Diğer bayi bu müşteriye sipariş açamaz');

select test.login(test.u_satis());
select test.throws($$select public.dealer_upsert_customer(test.biz(), '{"name":"X"}'::jsonb)$$, '%yetkiniz yok%', 'Bayi müşteri fonksiyonu yalnızca bayi içindir');
select test.ok((select count(*) from public.customers where owner_dealer_id is not null) = 2, 'Personel bayi müşterilerini görür');

-- ---------------------------------------------------------------- bayinin kendi teslimatı: onaysız
select test.login(test.u_b1());
select public.save_order(test.biz(), jsonb_build_object('id', '99999999-0000-0000-0000-000000000001', 'customer_id', test.cust_by_name('Kartepe Ev 1'),
  'deliver_by', 'self', 'items', jsonb_build_array(test.item('SU-005', 'Koli', 2))));
select test.eq((test.ord('99999999-0000-0000-0000-000000000001')).status, 'acik', 'Bayi kendi müşterisine kendisi teslim edecekse onaysız açılır');
select test.eq((test.ord('99999999-0000-0000-0000-000000000001')).dealer_customer_id, test.cust('B001'), 'Teslim eden bayinin kendisi');
select test.eq((select unit_price from public.order_items where order_id = '99999999-0000-0000-0000-000000000001'), 200.00::numeric, 'Bayi müşterisine perakende liste fiyatı yazılır');
select public.save_order(test.biz(), jsonb_build_object('id', '99999999-0000-0000-0000-000000000001', 'customer_id', test.cust_by_name('Kartepe Ev 1'),
  'deliver_by', 'merkez', 'items', jsonb_build_array(test.item('SU-005', 'Koli', 3))));
select test.eq((test.ord('99999999-0000-0000-0000-000000000001')).status, 'acik', 'Bayi kendi teslimatını düzenler; teslim eden ve durum değişmez');
select test.eq((select qty from public.order_items where order_id = '99999999-0000-0000-0000-000000000001'), 3, 'Miktar güncellenir');
select public.dealer_complete_order('99999999-0000-0000-0000-000000000001', 'teslim');
select test.eq((test.ord('99999999-0000-0000-0000-000000000001')).status, 'teslim_edildi', 'Bayi kendi teslimatını kapatır');
select test.eq(test.stock('SU-005'), 240, 'Bayinin kendi satışı bizim stoğu değiştirmez');

-- ---------------------------------------------------------------- başka bayiye ve merkeze: onay
select public.save_order(test.biz(), jsonb_build_object('id', '99999999-0000-0000-0000-000000000002', 'customer_id', test.cust_by_name('Sapanca Ev 2'),
  'deliver_by', test.cust('B002'), 'items', jsonb_build_array(test.item('SU-005', 'Koli', 1))));
select test.eq((test.ord('99999999-0000-0000-0000-000000000002')).status, 'onay_bekliyor', 'Başka bayiye açılan sipariş onay bekler');
select test.eq((test.ord('99999999-0000-0000-0000-000000000002')).dealer_customer_id, null::uuid, 'Onaydan önce hedef bayiye atanmaz');
select public.save_order(test.biz(), jsonb_build_object('id', '99999999-0000-0000-0000-000000000003', 'customer_id', test.cust_by_name('Sapanca Ev 2'),
  'deliver_by', 'merkez', 'items', jsonb_build_array(test.item('DM-001', 'Damacana', 2))));
select test.eq((test.ord('99999999-0000-0000-0000-000000000003')).status, 'onay_bekliyor', 'Merkeze (Hüseyin) açılan sipariş onay bekler');
select test.throws($$select public.save_order(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'customer_id', test.cust_by_name('Sapanca Ev 2'),
  'deliver_by', test.cust('M001'), 'items', jsonb_build_array(test.item('SU-005', 'Koli', 1))))$$, '%bayi bulunamadı%', 'Teslim eden bayi olmalı');
select test.throws($$select public.approve_order('99999999-0000-0000-0000-000000000002')$$, '%yetkiniz yok%', 'Bayi kendi talebini onaylayamaz');
select test.eq((select count(*) from public.orders)::int, 3, 'Bayi kendi müşterilerinin siparişlerini görür');

select test.login(test.u_b2());
select test.eq((select count(*) from public.orders)::int, 0, 'Hedef bayi onaydan önce siparişi görmez');

select test.login(test.u_sv());
select test.lives($$select public.approve_order('99999999-0000-0000-0000-000000000002')$$, 'Sevkiyat (Hüseyin) onaylayabilir');
select test.eq((test.ord('99999999-0000-0000-0000-000000000002')).dealer_customer_id, test.cust('B002'), 'Onayla sipariş talep edilen bayiye geçer');
select test.eq((test.ord('99999999-0000-0000-0000-000000000002')).requested_dealer_id, null::uuid, 'Talep alanı temizlenir');
select test.login(test.u_satis());
select public.approve_order('99999999-0000-0000-0000-000000000003');
select test.eq((test.ord('99999999-0000-0000-0000-000000000003')).status, 'acik', 'Merkez siparişi onayla açılır');
select test.eq((test.ord('99999999-0000-0000-0000-000000000003')).dealer_customer_id, null::uuid, 'Merkez siparişi bayiye gitmez');

select test.login(test.u_b2());
select test.eq((select count(*) from public.orders)::int, 1, 'Hedef bayi onaydan sonra siparişi görür');
select test.eq((select count(*) from public.customers where name = 'Sapanca Ev 2')::int, 1, 'Hedef bayi teslim edeceği müşteriyi görür');
select public.dealer_complete_order('99999999-0000-0000-0000-000000000002');

select test.login(test.u_b1());
select public.cancel_order('99999999-0000-0000-0000-000000000003', 'Müşteri vazgeçti');
select test.eq((test.ord('99999999-0000-0000-0000-000000000003')).status, 'iptal', 'Bayi kendi müşterisinin açık siparişini iptal eder');

select test.login(test.u_admin());
select test.eq((select count(*) from public.stock_consistency_check(test.biz()))::int, 0, 'Stok tutarlılığı korunur');
rollback;
