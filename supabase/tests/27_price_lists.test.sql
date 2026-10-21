-- Eve teslim ve kurumsal fiyat listeleri (F-14…F-16, D-097)
begin;
select test.fixture();
grant execute on all functions in schema test to authenticated;
select test.login(test.u_admin());
select public.set_list_price(test.unit('DM-001', 'Damacana'), 'ev', 160);
select test.logout();
update public.products set deposit_ev = 270 where id = test.pid('DM-001');
update public.businesses set public_ordering = true where id = test.biz();
select test.login(test.u_admin());

-- Kanal → liste
select public.upsert_customer(test.biz(), '{"code":"KR1","name":"Firma A","channel":"kurumsal","unlimited_credit":true}'::jsonb);
select test.eq((select price_list from public.customers where id = test.cust('KR1')), 'kurumsal', 'Kurumsal kart kurumsal listeye geçer');
select test.logout();
select test.eq(app.unit_list_price(test.unit('DM-001', 'Damacana'), 'kurumsal'), 180.00::numeric, 'Kurumsal: gel al × 1,5');
select test.eq(app.unit_list_price(test.unit('SU-005', 'Koli'), 'ev'), 240.00::numeric, 'Ev fiyatı yoksa gel al + 40');
select test.eq(app.unit_list_price(test.unit('DM-001', 'Damacana'), 'ev'), 160.00::numeric, 'Ev listesindeki fiyat');
set local role anon;
select test.eq((select price from public.public_catalog() where unit_id = test.unit('DM-001', 'Damacana')), 160.00::numeric, 'Müşteri ekranı gel al fiyatını görmez');
reset role;

-- Dükkân satışı: ev müşterisi gel al, kurumsal 1,5 kat (satış personeli fiyatı değiştiremez)
select test.login(test.u_satis());
select test.lives($$select test.sell('DM-001', 'Damacana', 1, jsonb_build_object('customer_id', test.cust('M001'),
  'deposits', jsonb_build_array(jsonb_build_object('product_id', test.pid('DM-001'), 'empty_returned', 1))))$$, 'Ev müşterisi dükkânda gel al fiyatı öder');
select test.throws($$select test.sell('DM-001', 'Damacana', 1, jsonb_build_object('customer_id', test.cust('KR1'),
  'deposits', jsonb_build_array(jsonb_build_object('product_id', test.pid('DM-001'), 'empty_returned', 1))))$$, '%Fiyat güncel değil%', 'Kurumsal dükkânda gel al fiyatıyla satılamaz');

-- Sipariş: ev müşterisi eve teslim fiyatı ve depozitosu
select test.login(test.u_admin());
select public.save_order(test.biz(), jsonb_build_object('id', 'abababab-0000-0000-0000-000000000001', 'customer_id', test.cust('M001'),
  'assignee', test.u_admin(),
  'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('DM-001'), 'unit_id', test.unit('DM-001', 'Damacana'), 'qty', 2))));
select test.logout();
select test.eq((select price_list from public.orders where id = 'abababab-0000-0000-0000-000000000001'), 'ev', 'Ev müşterisi siparişi eve teslim listesinde');
select test.eq((select unit_price from public.order_items where order_id = 'abababab-0000-0000-0000-000000000001'), 160.00::numeric, 'Siparişte eve teslim fiyatı');
select test.login(test.u_admin());
select public.deliver_order(test.biz(), jsonb_build_object('order_id', 'abababab-0000-0000-0000-000000000001', 'sale_id', 'cdcdcdcd-0000-0000-0000-000000000001',
  'deposits', jsonb_build_array(jsonb_build_object('product_id', test.pid('DM-001'), 'empty_returned', 1)),
  'payments', jsonb_build_array(jsonb_build_object('method', 'nakit', 'amount', 2 * 160 + 270))));
select test.logout();
select test.eq((select deposit_total from public.sales where id = 'cdcdcdcd-0000-0000-0000-000000000001'), 270.00::numeric, 'Eve teslimde eve teslim depozitosu');

-- Kurumsal sipariş: 1,5 kat, normal depozito
select test.login(test.u_admin());
select public.save_order(test.biz(), jsonb_build_object('id', 'abababab-0000-0000-0000-000000000002', 'customer_id', test.cust('KR1'),
  'assignee', test.u_admin(),
  'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('DM-001'), 'unit_id', test.unit('DM-001', 'Damacana'), 'qty', 1))));
select public.deliver_order(test.biz(), jsonb_build_object('order_id', 'abababab-0000-0000-0000-000000000002', 'sale_id', 'cdcdcdcd-0000-0000-0000-000000000002',
  'deposits', jsonb_build_array(jsonb_build_object('product_id', test.pid('DM-001'), 'empty_returned', 0)),
  'payments', jsonb_build_array(jsonb_build_object('method', 'veresiye', 'amount', 180 + 250))));
select test.logout();
select test.eq((select unit_price from public.order_items where order_id = 'abababab-0000-0000-0000-000000000002'), 180.00::numeric, 'Kurumsal siparişte 1,5 kat');
select test.eq((select deposit_total from public.sales where id = 'cdcdcdcd-0000-0000-0000-000000000002'), 250.00::numeric, 'Kurumsalda normal depozito');
rollback;
