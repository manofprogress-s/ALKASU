-- Bayi sistemi, fiyat listeleri, siparişler ve teslimat (F-10..F-12, O-*, R-06..R-08)
begin;
select test.fixture();

create function test.u_sevk()  returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000010'::uuid $$;
create function test.u_bayi()  returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000011'::uuid $$;
create function test.u_bayi2() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000012'::uuid $$;
create function test.ord(p_id uuid) returns public.orders language sql stable security definer as $$
  select * from public.orders where id = p_id
$$;
create function test.lp(p_unit uuid, p_list text) returns numeric language sql stable security definer as $$
  select app.unit_list_price(p_unit, p_list) $$;
create function test.pat(p_unit uuid, p_at timestamptz) returns numeric language sql stable security definer as $$
  select app.unit_price_at(p_unit, p_at) $$;
grant execute on function test.lp(uuid, text), test.pat(uuid, timestamptz) to authenticated;
grant execute on function test.u_sevk(), test.u_bayi(), test.u_bayi2(), test.ord(uuid) to authenticated;

insert into auth.users(id, email) values (test.u_sevk(), 'htopal@test'), (test.u_bayi(), 'isaglam@test'), (test.u_bayi2(), 'hyildiz@test');

-- ---------------------------------------------------------------- kullanıcılar ve müşteriler
select test.login(test.u_admin());
select public.upsert_customer(test.biz(), jsonb_build_object('code', 'B001', 'name', 'Sağlam Ticaret', 'channel', 'bayi',
  'price_list', 'bayi', 'regions', 'Kartepe, Alikahya, Sapanca, Suadiye', 'credit_limit', 100000));
select public.upsert_customer(test.biz(), jsonb_build_object('code', 'B002', 'name', 'Yıldız Ticaret', 'channel', 'bayi',
  'price_list', 'bayi', 'regions', 'İzmit, Alikahya, Kartepe'));
select test.eq((select price_list from public.customers where id = test.cust('B001')), 'bayi', 'Yönetici müşteriye fiyat listesi atar');

select public.add_member(test.biz(), test.u_sevk(), 'sevkiyat', 'Hüseyin Topaloğlu', null, 'HTopal', true);
select public.upsert_customer(test.biz(), jsonb_build_object('code', 'K001', 'name', 'Çelik Halat', 'channel', 'kurumsal',
  'price_list', 'palet', 'default_assignee', test.u_sevk()));
select test.throws($$select public.add_member(test.biz(), test.u_bayi(), 'bayi', 'İbrahim Sağlam')$$,
  '%bayi müşteri kartına%', 'Bayi kullanıcısı müşteri kartı olmadan eklenemez');
select public.add_member(test.biz(), test.u_bayi(), 'bayi', 'İbrahim Sağlam', test.cust('B001'), 'isaglam', true);
select public.add_member(test.biz(), test.u_bayi2(), 'bayi', 'Hüseyin Yıldız', test.cust('B002'), 'hyildiz', false);
select test.eq((select username from public.memberships where user_id = test.u_sevk()), 'htopal', 'Kullanıcı adı küçük harfe çevrilerek saklanır');

select test.login(test.u_satis());
select public.upsert_customer(test.biz(), jsonb_build_object('code', 'M010', 'name', 'Satışçının Müşterisi', 'price_list', 'bayi'));
select test.eq((select price_list from public.customers where id = test.cust('M010')), 'perakende', 'Satış personeli fiyat listesi atayamaz');

-- ---------------------------------------------------------------- fiyat listeleri
select test.throws($$select public.set_list_price(test.unit('SU-005', 'Koli'), 'bayi', 150)$$, '%yetkiniz yok%',
  'Satış personeli liste fiyatı giremez');
select test.login(test.u_admin());
select public.set_list_price(test.unit('SU-005', 'Koli'), 'palet', 180);
select public.set_list_price(test.unit('DM-001', 'Damacana'), 'bayi', 100);
select test.throws($$select public.set_list_price(test.unit('SU-005', 'Koli'), 'toptan', 1)$$, '%geçersiz%', 'Bilinmeyen fiyat listesi reddedilir');
select test.eq(test.lp(test.unit('SU-005', 'Koli'), 'palet'), 180.00::numeric, 'Palet liste fiyatı');
select test.eq(test.lp(test.unit('SU-005', 'Koli'), 'bayi'), 200.00::numeric, 'Liste fiyatı yoksa perakende kullanılır');
select test.eq(test.lp(test.unit('SU-005', 'Koli'), 'perakende'), 200.00::numeric, 'Perakende fiyat değişmez');
select test.eq(test.pat(test.unit('SU-005', 'Koli'), now()), 200.00::numeric, 'Perakende fiyat geçmişi liste fiyatlarıyla karışmaz');
select test.eq((select count(*) from public.product_prices where unit_id = test.unit('SU-005', 'Koli') and price_list = 'palet')::int, 1,
  'Liste fiyatı değişikliği geçmişe yazılır (F-03)');

-- İçe aktarma
select test.eq((public.import_prices(test.biz(), '[{"row":2,"urun_kodu":"YOK-1","bayi_fiyati":"5"}]'::jsonb, true)->>'ok')::boolean, false,
  'Bilinmeyen ürün kodu hata verir');
select test.eq((public.import_prices(test.biz(), '[{"row":2,"urun_kodu":"SU-005","bayi_fiyati":"abc"}]'::jsonb, true)->>'ok')::boolean, false,
  'Geçersiz tutar hata verir');
select public.import_prices(test.biz(), '[{"row":2,"urun_kodu":"su-005","bayi_fiyati":"190","palet_fiyati":""}]'::jsonb, false);
select test.eq(test.lp(test.unit('SU-005', 'Koli'), 'bayi'), 190.00::numeric, 'Birim boşsa fiyatlı en büyük birime yazılır');
select test.eq(test.lp(test.unit('SU-005', 'Koli'), 'palet'), 180.00::numeric, 'Boş hücre mevcut fiyatı silmez');
select public.import_prices(test.biz(), '[{"row":2,"urun_kodu":"SU-005","birim":"Paket","bayi_fiyati":"50"}]'::jsonb, false);
select test.eq(test.lp(test.unit('SU-005', 'Paket'), 'bayi'), 50.00::numeric, 'Birim belirtilirse o birime yazılır');

-- ---------------------------------------------------------------- satışta liste fiyatı (F-10)
select test.login(test.u_satis());
select test.throws($$select public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'customer_id', test.cust('B001'),
  'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005', 'Koli'), 'qty', 1, 'unit_price', 200)),
  'payments', jsonb_build_array(jsonb_build_object('method', 'nakit', 'amount', 200))))$$,
  '%Fiyat güncel değil%', 'Bayi müşterisine perakende fiyatla satılamaz');
select test.lives($$select public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'customer_id', test.cust('B001'),
  'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005', 'Koli'), 'qty', 1, 'unit_price', 190)),
  'payments', jsonb_build_array(jsonb_build_object('method', 'nakit', 'amount', 190))))$$,
  'Bayi müşterisine bayi fiyatıyla satılır');
select test.lives($$select test.sell('SU-005', 'Koli', 1)$$, 'Müşterisiz satış perakende fiyatla devam eder');

-- ---------------------------------------------------------------- roller
select test.login(test.u_sevk());
select test.ok(app.has_role(test.biz(), 'depo') and app.has_role(test.biz(), 'satis'), 'Sevkiyat rolü depo ve satış yetkilerini kapsar');
select test.ok(not app.has_role(test.biz(), 'yonetici'), 'Sevkiyat yönetici değildir');
select test.lives($$select test.sell('SU-005', 'Şişe', 2)$$, 'Sevkiyat satış yapabilir');
select test.eq((select count(*) from public.product_costs)::int, 0, 'Sevkiyat maliyetleri göremez');

select test.login(test.u_bayi());
select test.eq((public.my_context()->0->>'customer_id')::uuid, test.cust('B001'), 'Bayi oturumunda bağlı müşteri döner');
select test.eq((public.my_context()->0->>'must_change_password')::boolean, true, 'İlk girişte şifre değiştirme zorunlu');
select public.password_changed();
select test.eq((public.my_context()->0->>'must_change_password')::boolean, false, 'Şifre değişince zorunluluk kalkar');
select test.eq((select count(*) from public.customers)::int, 1, 'Bayi yalnızca kendi müşteri kartını görür');
select test.eq((select count(*) from public.sales)::int, 1, 'Bayi yalnızca kendisine yapılan satışları görür');
select test.eq((select count(*) from public.sale_items)::int, 1, 'Bayi yalnızca kendi satış kalemlerini görür');
select test.eq((select count(*) from public.product_costs)::int, 0, 'Bayi maliyetleri göremez');
select test.throws($$select test.sell('SU-005', 'Koli', 1)$$, '%yetkiniz yok%', 'Bayi satış yapamaz');
select test.throws($$select public.customer_summary(test.cust('K001'))$$, '%yetkiniz yok%', 'Bayi başka müşterinin özetini göremez');
select test.lives($$select public.customer_summary(test.cust('B001'))$$, 'Bayi kendi cari özetini görür');
select test.eq((select count(*) from public.customer_statement(test.cust('B001')))::int, 0, 'Bayi kendi ekstresini görür');

-- ---------------------------------------------------------------- siparişler
select test.login(test.u_admin());
select public.save_order(test.biz(), jsonb_build_object('id', '66666666-0000-0000-0000-000000000001', 'customer_id', test.cust('K001'),
  'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005', 'Koli'), 'qty', 2),
                             jsonb_build_object('product_id', test.pid('DM-001'), 'unit_id', test.unit('DM-001', 'Damacana'), 'qty', 3))));
select test.eq((test.ord('66666666-0000-0000-0000-000000000001')).assignee, test.u_sevk(), 'Sipariş müşterinin varsayılan sorumlusuna atanır');
select test.eq((select unit_price from public.order_items where order_id = '66666666-0000-0000-0000-000000000001' and line_no = 1),
  180.00::numeric, 'Sipariş fiyatı müşterinin listesinden gelir (palet)');
select test.eq((select unit_price from public.order_items where order_id = '66666666-0000-0000-0000-000000000001' and line_no = 2),
  120.00::numeric, 'Listede fiyat yoksa perakende');
select test.eq((test.ord('66666666-0000-0000-0000-000000000001')).no, 1::bigint, 'Sipariş numarası verilir');
select test.eq(test.stock('SU-005'), 240 - 48 - 2, 'Sipariş stoğu değiştirmez (yalnızca teslimat)');

select test.login(test.u_satis());
select test.throws($$select public.save_order(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'customer_id', test.cust('K001'),
  'assignee', test.u_bayi(), 'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005', 'Koli'), 'qty', 1))))$$,
  '%Atanan kişi geçersiz%', 'Sipariş bayi kullanıcısına atanamaz');
select test.throws($$select public.save_order(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'customer_id', test.cust('K001'),
  'items', '[]'::jsonb))$$, '%ürün yok%', 'Boş sipariş kaydedilmez');
select test.eq((select count(*) from public.assignable_users(test.biz()))::int, 3, 'Atanabilir kişiler: yönetici, satış, sevkiyat');

-- Teslimat yetkisi
select test.throws($$select public.deliver_order(test.biz(), jsonb_build_object('order_id', '66666666-0000-0000-0000-000000000001',
  'sale_id', gen_random_uuid(), 'payments', jsonb_build_array(jsonb_build_object('method', 'nakit', 'amount', 720))))$$,
  '%yalnızca atanan kişi%', 'Atanmamış satış personeli siparişi kapatamaz');
select test.login(test.u_bayi());
select test.throws($$select public.deliver_order(test.biz(), jsonb_build_object('order_id', '66666666-0000-0000-0000-000000000001',
  'sale_id', gen_random_uuid(), 'payments', '[]'::jsonb))$$, '%yetkiniz yok%', 'Bayi teslimat kaydedemez');
select test.eq((select count(*) from public.orders)::int, 0, 'Bayi başkasının siparişini görmez');

-- Teslimat: 2 koli yerine 1 koli, 3 damacana (2 boş alındı) — veresiye; limit aşımı uyarı olarak işaretlenir
select test.login(test.u_sevk());
select test.throws($$select public.deliver_order(test.biz(), jsonb_build_object('order_id', '66666666-0000-0000-0000-000000000001',
  'sale_id', gen_random_uuid(), 'items', jsonb_build_array(
     jsonb_build_object('order_item_id', (select id from public.order_items where order_id = '66666666-0000-0000-0000-000000000001' and line_no = 1), 'qty', 0),
     jsonb_build_object('order_item_id', (select id from public.order_items where order_id = '66666666-0000-0000-0000-000000000001' and line_no = 2), 'qty', 0)),
  'payments', '[]'::jsonb))$$, '%Teslim edilen ürün yok%', 'Hiç ürün teslim edilmediyse kapatılamaz');
select public.deliver_order(test.biz(), jsonb_build_object('order_id', '66666666-0000-0000-0000-000000000001',
  'sale_id', '77777777-0000-0000-0000-000000000001',
  'items', jsonb_build_array(jsonb_build_object('order_item_id',
     (select id from public.order_items where order_id = '66666666-0000-0000-0000-000000000001' and line_no = 1), 'qty', 1)),
  'deposits', jsonb_build_array(jsonb_build_object('product_id', test.pid('DM-001'), 'empty_returned', 2)),
  'payments', jsonb_build_array(jsonb_build_object('method', 'veresiye', 'amount', 180 + 360 + 250))));
select test.eq((test.ord('66666666-0000-0000-0000-000000000001')).status, 'teslim_edildi', 'Teslimat siparişi kapatır');
select test.eq((test.ord('66666666-0000-0000-0000-000000000001')).sale_id, '77777777-0000-0000-0000-000000000001'::uuid, 'Sipariş satışa bağlanır');
select test.eq(test.stock('SU-005'), 240 - 48 - 2 - 24, 'Teslim edilen miktar stoktan düşer');
select test.eq(test.stock('DM-001'), 50 - 3, 'Damacana stoktan düşer');
select test.eq(test.stock('BK-001'), 2, 'Alınan boşlar stoğa girer');
select test.eq(test.balance('K001'), 790.00::numeric, 'Veresiye tutarı müşteri carisine yazılır');
select test.eq((select qty from public.container_balances where customer_id = test.cust('K001')), 1, 'Müşteride kalan kap izlenir');
select test.ok((select offline_limit_exceeded from public.sales where id = '77777777-0000-0000-0000-000000000001'),
  'Teslimatta limit aşımı reddedilmez, yöneticiye işaretlenir');
select test.eq((select created_by from public.sales where id = '77777777-0000-0000-0000-000000000001'), test.u_sevk(), 'Satışı teslim eden kişi kaydeder');
select test.eq((public.deliver_order(test.biz(), jsonb_build_object('order_id', '66666666-0000-0000-0000-000000000001',
  'sale_id', '77777777-0000-0000-0000-000000000001', 'payments', '[]'::jsonb))->>'duplicate')::boolean, true,
  'Aynı teslimat tekrar gönderilirse ikinci kez işlenmez');
select test.throws($$select public.deliver_order(test.biz(), jsonb_build_object('order_id', '66666666-0000-0000-0000-000000000001',
  'sale_id', gen_random_uuid(), 'payments', '[]'::jsonb))$$, '%açık değil%', 'Kapanmış sipariş tekrar teslim edilemez');
select test.throws($$select public.save_order(test.biz(), jsonb_build_object('id', '66666666-0000-0000-0000-000000000001',
  'customer_id', test.cust('K001'), 'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005', 'Koli'), 'qty', 1))))$$,
  '%Kapanmış sipariş%', 'Kapanmış sipariş değiştirilemez');
select test.eq((public.dashboard(test.biz())->>'my_open_orders')::int, 0, 'Sevkiyat özetinde açık siparişlerim');

-- Bayi sipariş verir: müşteri zorla kendisi, atama yapılamaz
select test.login(test.u_bayi());
select public.save_order(test.biz(), jsonb_build_object('id', '66666666-0000-0000-0000-000000000002', 'customer_id', test.cust('K001'),
  'assignee', test.u_sevk(), 'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005', 'Koli'), 'qty', 5, 'unit_price', 1))));
select test.eq((test.ord('66666666-0000-0000-0000-000000000002')).customer_id, test.cust('B001'), 'Bayinin siparişi kendi carisine açılır');
select test.eq((test.ord('66666666-0000-0000-0000-000000000002')).assignee, null::uuid, 'Bayi sipariş ataması yapamaz');
select test.eq((select unit_price from public.order_items where order_id = '66666666-0000-0000-0000-000000000002'), 190.00::numeric,
  'Bayi fiyat belirleyemez, bayi listesi uygulanır');
select test.eq((select count(*) from public.orders)::int, 1, 'Bayi kendi siparişini görür');
select test.eq((public.dashboard(test.biz())->>'open_orders')::int, 1, 'Bayi özetinde açık siparişler');

select test.login(test.u_bayi2());
select test.eq((select count(*) from public.orders)::int, 0, 'Diğer bayi bu siparişi göremez');
select test.throws($$select public.cancel_order('66666666-0000-0000-0000-000000000002', 'vazgeçtim')$$, '%size ait değil%',
  'Bayi başka bayinin siparişini iptal edemez');

select test.login(test.u_admin());
select test.eq((public.dashboard(test.biz())->>'unassigned_orders')::int, 1, 'Yönetici atanmamış siparişleri görür');
select public.assign_order('66666666-0000-0000-0000-000000000002', test.u_sevk());
select test.eq((test.ord('66666666-0000-0000-0000-000000000002')).assignee, test.u_sevk(), 'Yönetici siparişi atar');
select test.throws($$select public.cancel_order('66666666-0000-0000-0000-000000000002', ' ')$$, '%nedeni zorunlu%', 'İptal nedeni zorunlu');

select test.login(test.u_bayi());
select public.cancel_order('66666666-0000-0000-0000-000000000002', 'Bayi vazgeçti');
select test.eq((test.ord('66666666-0000-0000-0000-000000000002')).status, 'iptal', 'Bayi kendi açık siparişini iptal eder');

select test.logout();
select test.eq((select count(*) from audit.log where table_name = 'orders' and record_id = '66666666-0000-0000-0000-000000000002')::int >= 3,
  true, 'Sipariş değişiklikleri denetime yazılır');
select test.login(test.u_admin());
select test.eq((select count(*) from public.stock_consistency_check(test.biz()))::int, 0, 'Stok tutarlılığı korunur');

rollback;
