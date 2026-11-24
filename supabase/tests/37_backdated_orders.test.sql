-- Geriye dönük sipariş/teslimat ve bayi adına kapatma (O-30..O-33)
begin;
select test.fixture();
create function test.u_huseyin() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-0000000000d1'::uuid $$;
create function test.u_selin()   returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-0000000000d2'::uuid $$;
create function test.u_ibrahim() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-0000000000d3'::uuid $$;
create function test.ord(p_id uuid) returns public.orders language sql stable security definer as $$ select * from public.orders where id = p_id $$;
create function test.sale(p_id uuid) returns public.sales language sql stable security definer as $$ select * from public.sales where id = p_id $$;
create function test.ledger_at(p_sale uuid) returns timestamptz language sql stable security definer as $$ select min(created_at) from public.customer_ledger where ref_id = p_sale $$;
create function test.stock_at(p_sale uuid) returns timestamptz language sql stable security definer as $$ select min(created_at) from public.stock_movements where ref_id = p_sale $$;
create function test.new_order(p_id uuid, p_date date, p_assignee uuid) returns jsonb language sql as $$
  select public.save_order(test.biz(), jsonb_build_object('id', p_id, 'customer_id', test.cust('M001'), 'delivery_date', p_date, 'assignee', p_assignee,
    'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005', 'Koli'), 'qty', 1)))) $$;
create function test.deliver(p_order uuid, p_sale uuid, p_at timestamptz) returns jsonb language sql as $$
  select public.deliver_order(test.biz(), jsonb_build_object('order_id', p_order, 'sale_id', p_sale, 'delivered_at', p_at,
    'payments', jsonb_build_array(jsonb_build_object('method', 'veresiye', 'amount', (select sum(qty * unit_price) from public.order_items where order_id = p_order))))) $$;
create function test.mid(p_user uuid) returns uuid language sql stable security definer as $$ select id from public.memberships where user_id = p_user $$;
grant execute on all functions in schema test to authenticated;

insert into auth.users(id, email) values (test.u_huseyin(), 'h@test'), (test.u_selin(), 's@test'), (test.u_ibrahim(), 'i@test');
select test.login(test.u_admin());
select public.upsert_customer(test.biz(), '{"code":"B001","name":"Sağlam Ticaret","channel":"bayi","price_list":"bayi"}'::jsonb);
select public.add_member(test.biz(), test.u_huseyin(), 'sevkiyat', 'Hüseyin', null, null, false);
select public.add_member(test.biz(), test.u_selin(), 'sevkiyat', 'Selin', null, null, false);
select public.add_member(test.biz(), test.u_ibrahim(), 'bayi', 'İbrahim', test.cust('B001'), null, false);

-- Yetki: yalnızca yönetici verir
select test.login(test.u_selin());
select test.throws($$select public.set_member_backdate(test.mid(test.u_huseyin()), true)$$, '%yetkiniz yok%', 'Yetkiyi yalnızca yönetici verir');
select test.login(test.u_admin());
select public.set_member_backdate(test.mid(test.u_huseyin()), true);
select test.throws($$select public.set_member_backdate(test.mid(test.u_ibrahim()), true)$$, '%personele%', 'Bayiye geriye dönük yetki verilmez');

-- O-30: geçmiş tarihli sipariş
select test.login(test.u_selin());
select test.throws($$select test.new_order(gen_random_uuid(), current_date - 3, null)$$, '%geriye dönük kayıt yetkisi%', 'Yetkisiz personel geçmiş tarihli sipariş giremez');
select test.lives($$select test.new_order(gen_random_uuid(), current_date, null)$$, 'Yetkisiz personel bugünün siparişini girer');
select test.login(test.u_huseyin());
select test.throws($$select test.new_order(gen_random_uuid(), current_date - 15, null)$$, '%14 gün%', '15 gün geriye girilemez');
select test.new_order('aaaaaaaa-0000-0000-0000-000000000001', current_date - 5, test.u_selin());
select test.eq((test.ord('aaaaaaaa-0000-0000-0000-000000000001')).delivery_date, current_date - 5, 'Yetkili kişi 5 gün geriye sipariş girer');

-- O-31/O-32: Hüseyin, Selin'e atanmış siparişi 5 gün önceki tarihle kapatır → teslim eden Selin, kaydeden Hüseyin
select test.throws($$select test.deliver('aaaaaaaa-0000-0000-0000-000000000001', gen_random_uuid(), now() - interval '15 days')$$, '%14 gün%', '15 gün önceki teslimat girilemez');
select test.throws($$select test.deliver('aaaaaaaa-0000-0000-0000-000000000001', gen_random_uuid(), now() + interval '1 day')$$, '%ileri bir tarih%', 'İleri tarihli teslimat girilemez');
select test.deliver('aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001', date_trunc('day', now()) - interval '5 days' + interval '14 hours');
select test.eq((test.ord('aaaaaaaa-0000-0000-0000-000000000001')).delivered_by, test.u_selin(), 'Teslim eden atanan kişi (Selin)');
select test.eq((test.ord('aaaaaaaa-0000-0000-0000-000000000001')).recorded_by, test.u_huseyin(), 'Kaydeden Hüseyin');
select test.eq((test.ord('aaaaaaaa-0000-0000-0000-000000000001')).delivered_at, date_trunc('day', now()) - interval '5 days' + interval '14 hours', 'Teslim zamanı geçmiş tarih');
select test.eq((test.sale('bbbbbbbb-0000-0000-0000-000000000001')).sold_at, date_trunc('day', now()) - interval '5 days' + interval '14 hours', 'Satış tarihi teslim tarihi');
select test.eq((test.sale('bbbbbbbb-0000-0000-0000-000000000001')).created_by, test.u_selin(), 'Satış teslim eden adına');
select test.eq(test.ledger_at('bbbbbbbb-0000-0000-0000-000000000001'), date_trunc('day', now()) - interval '5 days' + interval '14 hours', 'Cari hareketi teslim tarihiyle');
select test.eq(test.stock_at('bbbbbbbb-0000-0000-0000-000000000001'), date_trunc('day', now()) - interval '5 days' + interval '14 hours', 'Stok hareketi teslim tarihiyle');
select test.ok((select current_setting('alkasu.effective_at', true)) = '', 'Tarih ayarı işlemden sonra temizlenir');

-- Yetkisiz personel geçmiş tarihli kapatamaz, başkasının siparişini kapatamaz
select test.login(test.u_admin());
select test.new_order('aaaaaaaa-0000-0000-0000-000000000002', current_date, test.u_huseyin());
select test.login(test.u_selin());
select test.throws($$select test.deliver('aaaaaaaa-0000-0000-0000-000000000002', gen_random_uuid(), now())$$, '%yalnızca atanan kişi%', 'Yetkisiz personel başkasının siparişini kapatamaz');
select test.login(test.u_huseyin());
-- Kendi siparişini bugün kapatma: kaydeden boş, satış normal
select test.deliver('aaaaaaaa-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000002', null);
select test.eq((test.ord('aaaaaaaa-0000-0000-0000-000000000002')).recorded_by, null::uuid, 'Kendi siparişini bugün kapatınca kaydeden boş');
select test.eq((test.sale('bbbbbbbb-0000-0000-0000-000000000002')).late_sync, false, 'Bugünkü teslimat geç kayıt değil');

-- O-33: bayiye verilmiş sipariş bayi adına kapatılır (stok/kasa/cari hareketi yok)
select test.login(test.u_admin());
select test.new_order('aaaaaaaa-0000-0000-0000-000000000003', current_date - 2, null);
select public.assign_order_dealer('aaaaaaaa-0000-0000-0000-000000000003', test.cust('B001'), null);
select test.login(test.u_selin());
select test.throws($$select public.complete_dealer_order_for('aaaaaaaa-0000-0000-0000-000000000003')$$, '%geriye dönük kayıt yetkisi%', 'Yetkisiz personel bayi adına kapatamaz');
select test.login(test.u_huseyin());
select test.throws($$select public.complete_dealer_order_for('aaaaaaaa-0000-0000-0000-000000000003', null, now() - interval '20 days')$$, '%14 gün%', 'Bayi adına 14 günden eski kapatılamaz');
select public.complete_dealer_order_for('aaaaaaaa-0000-0000-0000-000000000003', 'Hüseyin teyit etti', now() - interval '1 day');
select test.eq((test.ord('aaaaaaaa-0000-0000-0000-000000000003')).status, 'teslim_edildi', 'Bayi siparişi teslim edildi');
select test.eq((test.ord('aaaaaaaa-0000-0000-0000-000000000003')).delivered_by, test.u_ibrahim(), 'Teslim eden İbrahim (bayi)');
select test.eq((test.ord('aaaaaaaa-0000-0000-0000-000000000003')).recorded_by, test.u_huseyin(), 'Kaydeden Hüseyin');
select test.eq((test.ord('aaaaaaaa-0000-0000-0000-000000000003')).sale_id, null::uuid, 'Bayi teslimatında bizde satış oluşmaz');
select test.throws($$select public.complete_dealer_order_for('aaaaaaaa-0000-0000-0000-000000000003')$$, '%açık değil%', 'Kapanmış sipariş tekrar kapatılamaz');
select test.throws($$select public.complete_dealer_order_for('aaaaaaaa-0000-0000-0000-000000000002')$$, '%bayiye verilmemiş%', 'Bayiye verilmemiş sipariş bu yolla kapatılamaz');
-- Bayi kendi siparişini görmeye devam eder
select test.login(test.u_ibrahim());
select test.eq((select count(*)::int from public.orders where id = 'aaaaaaaa-0000-0000-0000-000000000003'), 1, 'Bayi kapatılan siparişi görür');
rollback;
