-- Kasa günü, gider, gün sonu kapatma (K-01..K-10), çevrimdışı geç senkron (K-08)
begin;
select test.fixture();
select test.login(test.u_admin());

select test.eq(public.cash_session_summary(test.biz())->>'status', 'yok', 'Başlangıçta açık kasa günü yok');

-- Hareketler: 2 koli nakit (400), 1 koli POS (200), tahsilat 100, gider 50, kasadan çıkış 30
select test.sell('SU-005', 'Koli', 2);
select public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(),
  'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005','Koli'), 'qty', 1, 'unit_price', 200)),
  'payments', '[{"method":"pos","amount":200}]'::jsonb));
select public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'customer_id', test.cust('M001'),
  'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005','Koli'), 'qty', 1, 'unit_price', 200)),
  'payments', '[{"method":"veresiye","amount":200}]'::jsonb));
select public.record_customer_payment(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'customer_id', test.cust('M001'), 'method', 'nakit', 'amount', 100));
select public.add_expense(test.biz(), jsonb_build_object('id', gen_random_uuid(),
  'category_id', (select id from public.expense_categories where business_id = test.biz() and name = 'Yakıt'),
  'amount', 50, 'method', 'kasa', 'description', 'Araç yakıtı'));
select public.add_expense(test.biz(), jsonb_build_object('id', gen_random_uuid(),
  'category_id', (select id from public.expense_categories where business_id = test.biz() and name = 'Kira'),
  'amount', 5000, 'method', 'banka'));
select public.add_cash_movement(test.biz(), '{"type":"cikis","amount":30,"note":"Bankaya yatırıldı"}');
select test.eq((select count(*) from public.expense_categories where business_id = test.biz())::int, 9, 'Varsayılan gider kategorileri oluşur (K-10)');

-- K-03: beklenen nakit = 0 + 400 + 100 − 50 − 30 = 420
select test.eq((public.cash_session_summary(test.biz())->>'expected_cash')::numeric, 420.00::numeric, 'Beklenen nakit (K-03), banka gideri hariç');
select test.eq((public.cash_session_summary(test.biz())->>'pos_expected')::numeric, 200.00::numeric, 'Beklenen POS toplamı');
select test.eq((public.cash_session_summary(test.biz())->>'credit_sales')::numeric, 200.00::numeric, 'Günün veresiye satışı');

select test.login(test.u_satis());
select test.throws($$select public.cash_session_summary(test.biz())$$, '%yetkiniz yok%', 'Satış personeli kasa özetini göremez');
select test.throws($$select public.close_cash_session(test.biz(), jsonb_build_object('session_id', test.open_session(), 'counted_cash', 420, 'carry_over', 100))$$,
                   '%yetkiniz yok%', 'Kasayı yalnızca yönetici kapatır (K-06)');
select test.throws($$select public.add_expense(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'category_id', (select id from public.expense_categories limit 1), 'amount', 1, 'method', 'kasa'))$$,
                   '%yetkiniz yok%', 'Gideri yalnızca yönetici girer (K-09)');
select test.login(test.u_admin());

-- K-04: tolerans
select test.throws($$select public.close_cash_session(test.biz(), jsonb_build_object('session_id', test.open_session(), 'counted_cash', 300, 'carry_over', 100))$$,
                   '%açıklama zorunludur%', 'Tolerans üstü farkta açıklama zorunlu (K-04)');
select test.throws($$select public.close_cash_session(test.biz(), jsonb_build_object('session_id', test.open_session(), 'counted_cash', 420, 'carry_over', 500))$$,
                   '%Devreden nakit%', 'Devreden nakit sayılandan fazla olamaz');

create temp table _s as select test.open_session() as id;
select public.close_cash_session(test.biz(), jsonb_build_object('session_id', (select id from _s), 'counted_cash', 410, 'carry_over', 150, 'pos_slip', 200));
select test.eq((select cash_diff from public.cash_sessions where id = (select id from _s)), -10.00::numeric, 'Kasa farkı kaydedilir (tolerans içinde açıklamasız)');
select test.eq((select pos_diff from public.cash_sessions where id = (select id from _s)), 0.00::numeric, 'POS farkı kaydedilir');
select test.eq((select -amount from public.cash_movements where session_id = (select id from _s) and type = 'gun_sonu_teslim'), 260.00::numeric,
               'Sayılan − devreden = gün sonu teslim (K-05)');
select test.ok(test.open_session() is null, 'Kapanıştan sonra açık gün yok');

-- K-06: kapalı gün
select test.throws($$select public.close_cash_session(test.biz(), jsonb_build_object('session_id', (select id from _s), 'counted_cash', 0, 'carry_over', 0))$$,
                   '%zaten kapalı%', 'Kapalı gün tekrar kapatılamaz');
select test.logout();
select test.throws($$update public.cash_sessions set counted_cash = 1 where id = (select id from _s)$$, '%değiştirilemez%', 'Kapalı gün veritabanında da kilitli');
select test.throws($$insert into public.cash_movements(business_id, session_id, type, amount) values (test.biz(), (select id from _s), 'giris', 1)$$,
                   '%Kapanmış kasa gününe%', 'Kapalı güne hareket yazılamaz');
select test.login(test.u_admin());
select test.throws($$select public.cancel_sale((select id from public.sales where session_id = (select id from _s) limit 1), 'geç')$$,
                   '%iade işlemi yapın%', 'Kapanmış günün satışı iptal edilemez, iade yapılır (I-01)');

-- K-02/K-07: yeni gün, devreden nakitle açılır
select test.sell('SU-005', 'Şişe', 1);
select test.eq((select opening_cash from public.cash_sessions where id = test.open_session()), 150.00::numeric, 'Yeni gün devreden nakitle açılır (K-02)');
select test.eq((select no from public.cash_sessions where id = test.open_session()), 2::bigint, 'Kasa günleri numaralanır');

-- I-06: eski günün satışının iadesi bugünün kasasına yazılır
select public.create_return(jsonb_build_object('id', gen_random_uuid(),
  'sale_id', (select s.id from public.sales s join public.sale_payments p on p.sale_id = s.id where s.session_id = (select id from _s) and p.method = 'nakit' limit 1),
  'reason', 'Geç iade', 'items', jsonb_build_array(jsonb_build_object(
    'sale_item_id', (select i.id from public.sale_items i join public.sales s on s.id = i.sale_id join public.sale_payments p on p.sale_id = s.id
                      where s.session_id = (select id from _s) and p.method = 'nakit' limit 1), 'qty', 1, 'condition', 'saglam'))));
select test.eq(test.cash_expected(), 150 + 10 - 200.00::numeric, 'İade bugünün kasasından çıkar (I-06)');

-- K-08: çevrimdışı satış, gün kapandıktan sonra gelirse açık güne yazılır ve işaretlenir
select public.complete_sale(test.biz(), jsonb_build_object('id', '99999999-0000-0000-0000-000000000001', 'offline', true,
  'client_created_at', (now() - interval '1 day')::text,
  'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005','Şişe'), 'qty', 1, 'unit_price', 10)),
  'payments', '[{"method":"nakit","amount":10}]'::jsonb));
select test.ok((select late_sync from public.sales where id = '99999999-0000-0000-0000-000000000001'), 'Geç senkron satış işaretlenir (K-08)');
select test.eq((select session_id from public.sales where id = '99999999-0000-0000-0000-000000000001'), test.open_session(), 'Geç senkron satış açık güne yazılır');
select test.ok((select sold_at < created_at - interval '23 hours' from public.sales where id = '99999999-0000-0000-0000-000000000001'),
               'Çevrimdışı satış orijinal saatini korur');

-- C-02: çevrimdışı satışta eski fiyat kabul edilir
select public.set_unit_price(test.unit('SU-005','Şişe'), 11);
select test.login(test.u_satis());
select test.throws($$select public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(),
  'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005','Şişe'), 'qty', 1, 'unit_price', 10)),
  'payments', '[{"method":"nakit","amount":10}]'::jsonb))$$, '%Fiyat güncel değil%', 'Çevrimiçi satışta eski fiyat reddedilir');
select test.lives($$select public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'offline', true,
  'client_created_at', (now() - interval '1 minute')::text,
  'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005','Şişe'), 'qty', 1, 'unit_price', 10)),
  'payments', '[{"method":"nakit","amount":10}]'::jsonb))$$, 'Çevrimdışı satışta satış anındaki fiyat kabul edilir (C-02)');

-- Gider iptali kasaya geri yazar
select test.login(test.u_admin());
select public.add_expense(test.biz(), jsonb_build_object('id', 'aaaaaaaa-0000-0000-0000-000000000001',
  'category_id', (select id from public.expense_categories where business_id = test.biz() and name = 'Yemek'), 'amount', 40, 'method', 'kasa'));
create temp table _e as select test.cash_expected() as v;
select public.cancel_expense('aaaaaaaa-0000-0000-0000-000000000001', 'Yanlış tutar');
select test.eq(test.cash_expected(), (select v from _e) + 40, 'Gider iptali kasaya geri yazılır');

rollback;
