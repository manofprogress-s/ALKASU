-- Siparişte özel fiyat (O-20)
begin;
select test.fixture();
grant execute on all functions in schema test to authenticated;
select test.login(test.u_satis());
select test.eq((public.save_order(test.biz(), jsonb_build_object('id', 'eeeeeeee-0000-0000-0000-000000000001', 'customer_id', test.cust('M002'),
  'items', jsonb_build_array(
    jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005', 'Koli'), 'qty', 75, 'unit_price', 150.5),
    jsonb_build_object('product_id', test.pid('DM-001'), 'unit_id', test.unit('DM-001', 'Damacana'), 'qty', 15)))))->>'special_prices', '1',
  'Personel özel fiyat verir');
select test.logout();
select test.eq((select unit_price from public.order_items where order_id = 'eeeeeeee-0000-0000-0000-000000000001' and line_no = 1), 150.50::numeric, 'Özel fiyat kaydedilir');
select test.eq((select list_price from public.order_items where order_id = 'eeeeeeee-0000-0000-0000-000000000001' and line_no = 1),
  (select price from public.product_units where id = test.unit('SU-005', 'Koli')), 'Liste fiyatı ayrıca saklanır');
select test.eq((select unit_price = list_price from public.order_items where order_id = 'eeeeeeee-0000-0000-0000-000000000001' and line_no = 2), true, 'Fiyat verilmeyen kalem liste fiyatından');
select test.eq((select qty from public.order_items where order_id = 'eeeeeeee-0000-0000-0000-000000000001' and line_no = 1), 75, 'Büyük miktar (75) tek seferde girilir');
select test.ok(exists (select 1 from audit.log where action = 'siparis_ozel_fiyat'), 'Özel fiyat denetim kaydına yazılır');
select test.login(test.u_satis());
select test.throws($$select public.save_order(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'customer_id', test.cust('M002'),
  'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005', 'Koli'), 'qty', 1, 'unit_price', -1))))$$,
  '%Fiyat geçersiz%', 'Negatif fiyat reddedilir');
rollback;
