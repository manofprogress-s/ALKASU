-- Saha geri bildirimi 21.10: sayım önizleme/tek onay, verilen/alınan kap-ambalaj, kurumsal sipariş devri (T-04, A-07, S-25)
begin;
select test.fixture();
create function test.u_sv() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000033'::uuid $$;
create function test.u_y2() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000034'::uuid $$;
grant execute on all functions in schema test to authenticated;
insert into auth.users(id, email) values (test.u_sv(), 'sv@t'), (test.u_y2(), 'y2@t');
select test.login(test.u_admin());
select public.add_member(test.biz(), test.u_sv(), 'sevkiyat', 'Selin');
select public.add_member(test.biz(), test.u_y2(), 'yonetici', 'Ayhan');

-- ---------------------------------------------------------------- sayım
select public.start_stock_count(test.biz(), jsonb_build_object('id', 'cccccccc-0000-0000-0000-000000000001',
  'product_ids', jsonb_build_array(test.pid('SU-005'))));
select test.login(test.u_sv());   -- sevkiyat sayımı girer (depo yetkisi kapsar)
select public.save_stock_count_lines('cccccccc-0000-0000-0000-000000000001', jsonb_build_array(
  jsonb_build_object('product_id', test.pid('SU-005'), 'counted_qty', test.stock('SU-005') - 5)));
select test.eq((public.stock_count_preview('cccccccc-0000-0000-0000-000000000001')->'lines'->0->>'diff')::int, -5, 'Önizleme farkı gösterir');
select test.throws($$select public.approve_stock_count('cccccccc-0000-0000-0000-000000000001')$$, '%yetkiniz yok%', 'Sevkiyat onaylayamaz (yönetici onayı)');
select test.login(test.u_admin());
select test.throws($$select public.approve_stock_count('cccccccc-0000-0000-0000-000000000001')$$, '%onaya gönderilmedi%', 'Onaya gönderilmeden onaylanamaz');
select test.login(test.u_sv());
select test.eq(public.submit_stock_count('cccccccc-0000-0000-0000-000000000001')->>'required', '2', 'İki yönetici varken iki onay gerekir');
select test.throws($$select public.save_stock_count_lines('cccccccc-0000-0000-0000-000000000001', '[]')$$, '%kapanmış%', 'Onaydaki sayım değiştirilemez');
select test.eq((select summary->0->>'diff' from public.stock_counts where id = 'cccccccc-0000-0000-0000-000000000001'), '-5', 'Gönderimde fark raporu saklanır');
select test.login(test.u_admin());
create temp table st0 on commit drop as select test.stock('SU-005') as q;
select test.eq(public.approve_stock_count('cccccccc-0000-0000-0000-000000000001')->>'applied', 'false', 'İlk onay stoğu değiştirmez');
select test.eq(test.stock('SU-005'), (select q from st0), 'Tek onayda stok aynı');
select test.throws($$select public.approve_stock_count('cccccccc-0000-0000-0000-000000000001')$$, '%zaten onayladınız%', 'Aynı yönetici iki kez onaylayamaz');
select test.login(test.u_y2());
select test.eq((public.approve_stock_count('cccccccc-0000-0000-0000-000000000001')->>'net_diff')::int, -5, 'İkinci yönetici onayıyla fark stoğa işlenir');
select test.eq(test.stock('SU-005'), (select q from st0) - 5, 'Stok sayılan miktara eşit');
select test.throws($$select public.approve_stock_count('cccccccc-0000-0000-0000-000000000001')$$, '%kapanmış%', 'Aynı sayım ikinci kez uygulanamaz');
select test.login(test.u_admin());
select test.eq(test.stock('SU-005'), (select q from st0) - 5, 'İkinci deneme stoğu değiştirmez');

-- ---------------------------------------------------------------- mal kabul: verilen / alınan kap-ambalaj
select public.upsert_product(test.biz(), jsonb_build_object('code', 'AMB-VIYOL', 'name', 'Viyol', 'base_unit_name', 'Adet', 'is_container', true));
select public.receive_goods(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'empties', jsonb_build_array(
  jsonb_build_object('product_id', test.pid('AMB-VIYOL'), 'qty', 40, 'direction', 'alinan'))));
select test.eq(test.stock('AMB-VIYOL'), 40, 'Tedarikçiden alınan viyol stoğa girer');
select public.receive_goods(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'empties', jsonb_build_array(
  jsonb_build_object('product_id', test.pid('AMB-VIYOL'), 'qty', 15, 'direction', 'verilen'),
  jsonb_build_object('product_id', test.pid('BK-001'), 'qty', 2))));
select test.eq(test.stock('AMB-VIYOL'), 25, 'Tedarikçiye verilen viyol stoktan düşer');
select test.eq((select count(*) from public.purchase_empties where direction = 'verilen')::int, 2, 'Yön belirtilmezse "verilen"');
select test.throws($$select public.receive_goods(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'empties',
  jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'qty', 1, 'direction', 'alinan'))))$$,
  '%kap / ambalaj%', 'Satılan ürün bu bölüme eklenemez (stoklar karışmaz)');
select test.throws($$select public.receive_goods(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'empties',
  jsonb_build_array(jsonb_build_object('product_id', test.pid('AMB-VIYOL'), 'qty', 1, 'direction', 'x'))))$$,
  '%Yön%', 'Geçersiz yön reddedilir');

-- ---------------------------------------------------------------- kurumsal sipariş devri
select test.logout();
update public.customers set channel = 'kurumsal' where id = test.cust('M002');
select test.login(test.u_admin());
select public.save_order(test.biz(), jsonb_build_object('id', 'dddddddd-0000-0000-0000-000000000001', 'customer_id', test.cust('M002'),
  'assignee', test.u_admin(),
  'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005', 'Koli'), 'qty', 1))));
select test.login(test.u_sv());
select public.assign_order('dddddddd-0000-0000-0000-000000000001', test.u_sv());
select test.eq((select assignee from public.orders where id = 'dddddddd-0000-0000-0000-000000000001'), test.u_sv(), 'Kurumsal sipariş başka çalışana devredilir');
select test.eq((select channel from public.customers where id = test.cust('M002')), 'kurumsal', 'Müşterinin niteliği değişmez');
select test.eq((select default_assignee from public.customers where id = test.cust('M002')), null::uuid, 'Müşteri kartındaki varsayılan sorumlu değişmez');
select test.logout();
select test.ok(exists (select 1 from audit.log where action = 'siparis_devir'), 'Devir kayıt altına alınır');

-- Düzeltme için geri gönderme: onaylar silinir, girişler açılır
select test.login(test.u_admin());
select public.start_stock_count(test.biz(), jsonb_build_object('id', 'cccccccc-0000-0000-0000-000000000002', 'product_ids', jsonb_build_array(test.pid('SU-005'))));
select public.save_stock_count_lines('cccccccc-0000-0000-0000-000000000002', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'counted_qty', 1)));
select public.submit_stock_count('cccccccc-0000-0000-0000-000000000002');
select public.approve_stock_count('cccccccc-0000-0000-0000-000000000002');
select test.throws($$select public.start_stock_count(test.biz(), jsonb_build_object('id', gen_random_uuid()))$$, '%sayım var%', 'Onaydaki sayım varken yenisi açılamaz');
select public.reopen_stock_count('cccccccc-0000-0000-0000-000000000002', 'tekrar say');
select test.eq((select status from public.stock_counts where id = 'cccccccc-0000-0000-0000-000000000002'), 'acik', 'Geri gönderilen sayım tekrar açılır');
select test.eq((select count(*) from public.stock_count_approvals where count_id = 'cccccccc-0000-0000-0000-000000000002')::int, 0, 'Verilen onaylar silinir');
rollback;
