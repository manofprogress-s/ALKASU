-- Depozito senaryoları (D-03, D-07): müşteri 1 boşla 2 dolu, bayi 20 boş/30 dolu ve 30 boş/20 dolu
begin;
select test.fixture();
create function test.dm(p_qty int, p_price numeric) returns jsonb language sql stable security definer as $$
  select jsonb_build_object('product_id', test.pid('DM-001'), 'unit_id', test.unit('DM-001', 'Damacana'), 'qty', p_qty, 'unit_price', p_price)
$$;
create function test.ret(p_n int) returns jsonb language sql stable security definer as $$
  select jsonb_build_array(jsonb_build_object('product_id', test.pid('DM-001'), 'empty_returned', p_n))
$$;
create function test.kap(p_code text) returns int language sql stable security definer as $$
  select coalesce(sum(qty), 0)::int from public.container_balances where customer_id = test.cust(p_code)
$$;
grant execute on all functions in schema test to authenticated;

select test.login(test.u_admin());
select public.upsert_customer(test.biz(), '{"code":"B001","name":"Yıldız Ticaret","channel":"bayi","price_list":"bayi","unlimited_credit":true}'::jsonb);
select public.set_list_price(test.unit('DM-001', 'Damacana'), 'bayi', 60);

select test.login(test.u_satis());
-- Müşteri 1 boş getirip 2 dolu alır: 2 × 120 + 1 depozito (250)
select public.complete_sale(test.biz(), jsonb_build_object('id', 'dddddddd-0000-0000-0000-000000000001', 'customer_id', test.cust('M003'),
  'items', jsonb_build_array(test.dm(2, 120)), 'deposits', test.ret(1),
  'payments', jsonb_build_array(jsonb_build_object('method', 'nakit', 'amount', 490))));
select test.eq((select grand_total from public.sales where id = 'dddddddd-0000-0000-0000-000000000001'), 490.00::numeric, '1 boşla 2 dolu: 1 depozito satılır');
select test.eq(test.kap('M003'), 1, 'Müşteride 1 kap görünür');

-- Bayi 20 boş bırakıp 30 dolu alır: 10 depozito veresiyeye
select public.complete_sale(test.biz(), jsonb_build_object('id', 'dddddddd-0000-0000-0000-000000000002', 'customer_id', test.cust('B001'),
  'items', jsonb_build_array(test.dm(30, 60)), 'deposits', test.ret(20),
  'payments', jsonb_build_array(jsonb_build_object('method', 'veresiye', 'amount', 30 * 60 + 10 * 250))));
select test.eq(test.balance('B001'), 4300.00::numeric, 'Bayinin 10 depozitosu cariye (veresiye) yazılır');
select test.eq(test.kap('B001'), 10, 'Bayide 10 kap görünür');

-- Bayi 30 boş getirip 20 dolu alır: 10 depozito iadesi ürün tutarını aşar → fark bayinin carisine alacak
select test.throws($$select public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'customer_id', test.cust('B001'),
  'items', jsonb_build_array(test.dm(20, 60)), 'deposits', test.ret(30),
  'payments', jsonb_build_array(jsonb_build_object('method', 'nakit', 'amount', 1))))$$, '%ödeme girilmez%', 'Eksi fişte ödeme girilmez');
select public.complete_sale(test.biz(), jsonb_build_object('id', 'dddddddd-0000-0000-0000-000000000003', 'customer_id', test.cust('B001'),
  'items', jsonb_build_array(test.dm(20, 60)), 'deposits', test.ret(30), 'payments', '[]'::jsonb));
select test.eq((select grand_total from public.sales where id = 'dddddddd-0000-0000-0000-000000000003'), -1300.00::numeric, 'Fiş: 1200 − 2500 = −1300');
select test.eq(test.balance('B001'), 3000.00::numeric, 'Fark bayinin carisine alacak yazılır (4300 − 1300)');
select test.eq(test.kap('B001'), 0, 'Bayideki kap sayısı düşer');
select test.ok(exists (select 1 from public.customer_ledger where ref_id = 'dddddddd-0000-0000-0000-000000000003' and type = 'depozito_mahsup'),
  'Cari harekette "depozito mahsup" görünür');

-- Fiş iptali her şeyi geri alır
select test.login(test.u_admin());
select public.cancel_sale('dddddddd-0000-0000-0000-000000000003', 'Yanlış giriş');
select test.eq(test.balance('B001'), 4300.00::numeric, 'İptal: cari geri döner');
select test.eq(test.kap('B001'), 10, 'İptal: kap sayısı geri döner');

-- Kap kaydı yoksa fazla boş kabul edilmez (yanlış iade önlenir)
select test.login(test.u_satis());
select test.throws($$select public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'customer_id', test.cust('M001'),
  'items', jsonb_build_array(test.dm(1, 120)), 'deposits', test.ret(3), 'payments', '[]'::jsonb))$$, '%elinde bu kadar kap%',
  'Elinde kap görünmeyen müşteriden fazla boş alınamaz');
rollback;
