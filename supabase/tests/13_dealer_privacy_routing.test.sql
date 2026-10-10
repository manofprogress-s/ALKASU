-- Bayi listesi gizliliği (G-13..G-15) ve özel sevkiyat yönlendirme (G-16, G-17)
begin;
select test.fixture();

create function test.u_b1() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000041'::uuid $$;
create function test.u_b2() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000042'::uuid $$;
create function test.u_sv() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000043'::uuid $$;
create function test.ord(p_id uuid) returns public.orders language sql stable security definer as $$ select * from public.orders where id = p_id $$;
create function test.cust_by_name(p text) returns uuid language sql stable security definer as $$ select id from public.customers where name = p $$;
create function test.c(p_id uuid) returns public.customers language sql stable security definer as $$ select * from public.customers where id = p_id $$;
create function test.req(p_id uuid) returns public.customer_requests language sql stable security definer as $$ select * from public.customer_requests where id = p_id $$;
create function test.item(p_code text, p_unit text, p_qty int) returns jsonb language sql stable security definer as $$
  select jsonb_build_object('product_id', test.pid(p_code), 'unit_id', test.unit(p_code, p_unit), 'qty', p_qty)
$$;
create function test.logs() returns int language sql stable security definer as $$ select count(*)::int from public.order_routing_log $$;
grant execute on all functions in schema test to authenticated;
insert into auth.users(id, email) values (test.u_b1(), 'b1@t'), (test.u_b2(), 'b2@t'), (test.u_sv(), 'sv@t');

select test.login(test.u_admin());
select public.upsert_customer(test.biz(), '{"code":"B001","name":"Gürpınar Bayi","channel":"bayi","price_list":"bayi"}'::jsonb);
select public.upsert_customer(test.biz(), '{"code":"B002","name":"Fuska Bayi","channel":"bayi","price_list":"bayi"}'::jsonb);
select public.upsert_customer(test.biz(), '{"code":"K001","name":"Prometeon","channel":"kurumsal"}'::jsonb);
select public.add_member(test.biz(), test.u_b1(), 'bayi', 'Gürpınar', test.cust('B001'));
select public.add_member(test.biz(), test.u_b2(), 'bayi', 'Fuska', test.cust('B002'));
select public.add_member(test.biz(), test.u_sv(), 'sevkiyat', 'Hüseyin');

select test.login(test.u_b1());
select public.dealer_upsert_customer(test.biz(), '{"name":"Bayi Ev 1","phone":"05320000001","address":"Gürpınar Mah. 1"}'::jsonb);
select test.eq((select count(*) from public.customers)::int, 2, 'Bayi merkezin müşteri listesini görmez (yalnızca kendi kartı ve müşterisi)');

-- ---------------------------------------------------------------- merkez bayinin kartını değiştiremez
select test.login(test.u_admin());
select test.eq((select count(*) from public.customers where owner_dealer_id = test.cust('B001'))::int, 1, 'Merkez bayinin listesini görür');
select test.throws($$select public.upsert_customer(test.biz(), jsonb_build_object('id', test.cust_by_name('Bayi Ev 1'), 'name', 'Değişti'))$$,
  '%bayiye ait%', 'Yönetici bile bayinin müşteri kartını doğrudan değiştiremez');
select test.login(test.u_satis());
select test.throws($$select public.upsert_customer(test.biz(), jsonb_build_object('id', test.cust_by_name('Bayi Ev 1'), 'name', 'Değişti'))$$,
  '%bayiye ait%', 'Satış personeli bayinin müşteri kartını değiştiremez');

-- Değişiklik önerisi
select public.propose_dealer_customer(test.cust('B001'), test.cust_by_name('Bayi Ev 1'), '{"name":"Bayi Ev 1","address":"Gürpınar Mah. 1, Daire 3"}'::jsonb);
select test.eq((test.c(test.cust_by_name('Bayi Ev 1'))).address, 'Gürpınar Mah. 1', 'Öneri bayi onaylamadan uygulanmaz');
select test.throws($$select public.propose_dealer_customer(test.cust('B001'), test.cust_by_name('Bayi Ev 1'), '{"name":"X Y"}'::jsonb)$$,
  '%bekleyen bir öneri%', 'Aynı müşteriye ikinci bekleyen öneri açılamaz');
select test.throws($$select public.propose_dealer_customer(test.cust('B002'), test.cust_by_name('Bayi Ev 1'), '{"name":"X Y"}'::jsonb)$$,
  '%bu bayiye ait değil%', 'Müşteri öneride belirtilen bayiye ait olmalı');
-- Yeni müşteri önerisi
select public.propose_dealer_customer(test.cust('B001'), null, '{"name":"Önerilen Ev","phone":"05320000009","address":"Kartepe 5"}'::jsonb);
select test.ok(test.cust_by_name('Önerilen Ev') is null, 'Önerilen müşteri bayi onaylamadan listeye girmez');

-- Diğer bayi öneriyi görmez / sonuçlandıramaz
select test.login(test.u_b2());
select test.eq((select count(*) from public.customer_requests)::int, 0, 'Diğer bayi önerileri görmez');
select test.throws($$select public.decide_customer_request((select id from public.customer_requests limit 1), true)$$, '%', 'Diğer bayi öneri sonuçlandıramaz');

select test.login(test.u_b1());
select test.eq((select count(*) from public.customer_requests where status = 'bekliyor')::int, 2, 'Bayi kendisine gelen önerileri görür');
select public.decide_customer_request((select id from public.customer_requests where customer_id is not null), true, 'Tamam');
select test.eq((test.c(test.cust_by_name('Bayi Ev 1'))).address, 'Gürpınar Mah. 1, Daire 3', 'Bayi onaylayınca değişiklik uygulanır');
select test.eq((test.c(test.cust_by_name('Bayi Ev 1'))).phone, '05320000001', 'Öneride olmayan alan korunur');
select public.decide_customer_request((select id from public.customer_requests where customer_id is null), false, 'Tanımıyorum');
select test.ok(test.cust_by_name('Önerilen Ev') is null, 'Reddedilen müşteri eklenmez');
select test.throws($$select public.decide_customer_request((select id from public.customer_requests where customer_id is null), true)$$,
  '%sonuçlandı%', 'Sonuçlanan öneri tekrar karara bağlanamaz');

select test.login(test.u_satis());
select public.propose_dealer_customer(test.cust('B001'), null, '{"name":"İkinci Öneri","address":"Kartepe 7"}'::jsonb);
select test.login(test.u_b1());
select public.decide_customer_request((select id from public.customer_requests where status = 'bekliyor'), true);
select test.eq((test.c(test.cust_by_name('İkinci Öneri'))).owner_dealer_id, test.cust('B001'), 'Onaylanan yeni müşteri bayinin listesine girer');

select test.login(test.u_satis());
select public.propose_dealer_customer(test.cust('B001'), test.cust_by_name('İkinci Öneri'), '{"name":"İkinci Öneri 2"}'::jsonb);
select test.login(test.u_admin());
select test.lives($$select public.cancel_customer_request((select id from public.customer_requests where status = 'bekliyor'))$$, 'Yönetici bekleyen öneriyi geri çeker');

-- ---------------------------------------------------------------- yönlendirme
-- Bayinin kendi müşterisine kendi teslimatı
select test.login(test.u_b1());
select public.save_order(test.biz(), jsonb_build_object('id', 'aaaaaaaa-1900-0000-0000-000000000001', 'customer_id', test.cust_by_name('Bayi Ev 1'),
  'deliver_by', 'self', 'items', jsonb_build_array(test.item('SU-005', 'Koli', 1))));
-- Merkezin kurumsal siparişi
select test.login(test.u_satis());
select public.save_order(test.biz(), jsonb_build_object('id', 'aaaaaaaa-1900-0000-0000-000000000002', 'customer_id', test.cust('K001'),
  'items', jsonb_build_array(test.item('SU-005', 'Koli', 2))));
-- Merkezin ev müşterisi siparişi
select public.save_order(test.biz(), jsonb_build_object('id', 'aaaaaaaa-1900-0000-0000-000000000003', 'customer_id', test.cust('M001'),
  'items', jsonb_build_array(test.item('SU-005', 'Koli', 1))));

select test.throws($$select public.assign_order_dealer('aaaaaaaa-1900-0000-0000-000000000001', null, 'Depodan gidecek')$$,
  '%sevkiyat sorumlusu veya yönetici%', 'Satış personeli bayinin sevkiyatını depoya çekemez');
select test.throws($$select public.assign_order_dealer('aaaaaaaa-1900-0000-0000-000000000002', test.cust('B001'), 'Yakın')$$,
  '%sevkiyat sorumlusu veya yönetici%', 'Satış personeli kurumsal siparişi bayiye veremez');
select public.assign_order_dealer('aaaaaaaa-1900-0000-0000-000000000003', test.cust('B002'));
select test.eq((test.ord('aaaaaaaa-1900-0000-0000-000000000003')).dealer_customer_id, test.cust('B002'), 'Ev müşterisi siparişi normal yolla bayiye verilir');

select test.login(test.u_sv());
select test.throws($$select public.assign_order_dealer('aaaaaaaa-1900-0000-0000-000000000001', null)$$, '%gerekçe%', 'Özel yönlendirmede gerekçe zorunlu');
select public.assign_order_dealer('aaaaaaaa-1900-0000-0000-000000000001', null, 'Bayinin aracı arızalı, depodan gidecek');
select test.ok((test.ord('aaaaaaaa-1900-0000-0000-000000000001')).dealer_customer_id is null, 'Sevkiyat sorumlusu bayinin sevkiyatını depoya çeker');
select public.assign_order_dealer('aaaaaaaa-1900-0000-0000-000000000002', test.cust('B001'), 'Bayiye daha yakın');
select test.eq((test.ord('aaaaaaaa-1900-0000-0000-000000000002')).dealer_customer_id, test.cust('B001'), 'Sevkiyat sorumlusu kurumsal siparişi bayiye verir');
select test.eq((select count(*) from public.order_routing_log)::int, 0, 'Sevkiyat sorumlusu yönlendirme kayıtlarını görmez (yalnızca yönetici)');

-- Bayi, kendisine verilen kurumsal siparişin müşterisini görür; diğer bayi görmez
select test.login(test.u_b1());
select test.eq((select name from public.customers where id = test.cust('K001')), 'Prometeon', 'Yönlendirilen siparişin müşterisi bayiye görünür');
select test.login(test.u_b2());
select test.ok((select count(*) from public.customers where id = test.cust('K001')) = 0, 'Diğer bayi o müşteriyi görmez');
select test.ok((select count(*) from public.customers where id = test.cust('M001')) = 1, 'Ev siparişi verilen bayi o müşteriyi görür');

select test.login(test.u_admin());
select test.eq(test.logs(), 3, 'Her yönlendirme kaydedilir');
select test.eq((select count(*) from public.order_routing_log where special)::int, 2, 'Özel yönlendirmeler işaretlenir');
select test.eq((select note from public.order_routing_log where order_id = 'aaaaaaaa-1900-0000-0000-000000000001'), 'Bayinin aracı arızalı, depodan gidecek', 'Gerekçe yöneticiye görünür');
reset role;
select test.throws($$update public.order_routing_log set note = 'x' where true$$, '%değiştirilemez%', 'Yönlendirme kaydı değiştirilemez');
rollback;
