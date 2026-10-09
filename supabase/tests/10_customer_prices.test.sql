-- Firmaya özel fiyat (F-13): sipariş ve satışta öncelik, yetki, görünürlük
begin;
select test.fixture();
create function test.ord(p_id uuid) returns public.orders language sql stable security definer as $$ select * from public.orders where id = p_id $$;
grant execute on all functions in schema test to authenticated;

select test.login(test.u_admin());
select public.upsert_customer(test.biz(), '{"code":"K100","name":"Crawler","channel":"kurumsal","credit_limit":100000}'::jsonb);
select public.upsert_customer(test.biz(), '{"code":"K101","name":"Çekok","channel":"kurumsal","price_list":"palet"}'::jsonb);
select public.set_list_price(test.unit('SU-005', 'Koli'), 'palet', 180);
select public.set_customer_price(test.cust('K100'), test.unit('SU-005', 'Koli'), 170.5);
select public.set_customer_price(test.cust('K100'), test.unit('DM-001', 'Damacana'), 100);
select test.eq((select price from public.customer_prices where customer_id = test.cust('K100') and unit_id = test.unit('SU-005', 'Koli')), 170.50::numeric,
  'Firmaya özel fiyat kaydedilir');
select public.set_customer_price(test.cust('K100'), test.unit('SU-005', 'Koli'), 175);
select test.eq((select price from public.customer_prices where customer_id = test.cust('K100') and unit_id = test.unit('SU-005', 'Koli')), 175.00::numeric,
  'Özel fiyat güncellenir');
select test.throws($$select public.set_customer_price(test.cust('K100'), test.unit('SU-005', 'Koli'), -1)$$, '%negatif%', 'Negatif fiyat reddedilir');

-- Sipariş fiyatı: özel fiyat > liste > perakende
select test.login(test.u_satis());
select public.save_order(test.biz(), jsonb_build_object('id', 'aaaaaaaa-0000-0000-0000-000000000001', 'customer_id', test.cust('K100'),
  'items', jsonb_build_array(
    jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005', 'Koli'), 'qty', 1),
    jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005', 'Paket'), 'qty', 1))));
select test.eq((select unit_price from public.order_items where order_id = 'aaaaaaaa-0000-0000-0000-000000000001' and line_no = 1), 175.00::numeric,
  'Siparişte firmaya özel fiyat uygulanır');
select test.eq((select unit_price from public.order_items where order_id = 'aaaaaaaa-0000-0000-0000-000000000001' and line_no = 2), 55.00::numeric,
  'Özel fiyatı olmayan birimde normal fiyat');
select public.save_order(test.biz(), jsonb_build_object('id', 'aaaaaaaa-0000-0000-0000-000000000002', 'customer_id', test.cust('K101'),
  'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005', 'Koli'), 'qty', 1))));
select test.eq((select unit_price from public.order_items where order_id = 'aaaaaaaa-0000-0000-0000-000000000002'), 180.00::numeric,
  'Özel fiyatı olmayan firmada fiyat listesi geçerli');

-- Satışta doğrulama: satış personeli özel fiyatla satar, perakende fiyatla satamaz
select test.lives($$select public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'customer_id', test.cust('K100'),
  'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005', 'Koli'), 'qty', 1, 'unit_price', 175)),
  'payments', jsonb_build_array(jsonb_build_object('method', 'nakit', 'amount', 175))))$$, 'Satışta firmaya özel fiyat kabul edilir');
select test.throws($$select public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'customer_id', test.cust('K100'),
  'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005', 'Koli'), 'qty', 1, 'unit_price', 200)),
  'payments', jsonb_build_array(jsonb_build_object('method', 'nakit', 'amount', 200))))$$, '%Fiyat güncel değil%', 'Özel fiyatlı firmaya perakende fiyatla satılamaz');
select test.lives($$select test.sell('SU-005', 'Koli', 1)$$, 'Müşterisiz satış perakende kalır');

-- Yetki ve görünürlük
select test.throws($$select public.set_customer_price(test.cust('K100'), test.unit('SU-005', 'Koli'), 1)$$, '%yetkiniz yok%', 'Özel fiyatı yalnızca yönetici girer');
select test.eq((select count(*) from public.customer_prices)::int, 2, 'Satış personeli özel fiyatları görür');
select test.login(test.u_depo());
select test.eq((select count(*) from public.customer_prices)::int, 0, 'Depo personeli özel fiyatları görmez');

select test.login(test.u_admin());
select public.set_customer_price(test.cust('K100'), test.unit('DM-001', 'Damacana'), null);
select test.eq((select count(*) from public.customer_prices where customer_id = test.cust('K100'))::int, 1, 'Özel fiyat kaldırılır');
select test.ok((select count(*) from audit.log where action = 'ozel_fiyat') >= 4, 'Özel fiyat değişiklikleri işlem geçmişine yazılır');
rollback;
