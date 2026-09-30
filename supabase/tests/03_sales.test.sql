-- Satış, indirim, veresiye, depozito, iptal, iade, tahsilat (S-*, F-04..F-07, V-*, D-*, I-*)
begin;
select test.fixture();

create function test.line(p_code text, p_unit text, p_qty int, p_price numeric default null, p_disc numeric default 0)
returns jsonb language sql stable security definer as $$
  select jsonb_build_object('product_id', test.pid(p_code), 'unit_id', test.unit(p_code, p_unit), 'qty', p_qty,
    'unit_price', coalesce(p_price, (select price from public.product_units where id = test.unit(p_code, p_unit))),
    'line_discount', p_disc)
$$;
create function test.pay(p_method text, p_amount numeric) returns jsonb language sql immutable as $$
  select jsonb_build_object('method', p_method, 'amount', p_amount)
$$;
grant execute on function test.line(text, text, int, numeric, numeric), test.pay(text, numeric) to authenticated;

select test.login(test.u_satis());

-- S-01 / B-03: koli satışı
select public.complete_sale(test.biz(), jsonb_build_object('id', '44444444-0000-0000-0000-000000000001',
  'items', jsonb_build_array(test.line('SU-005', 'Koli', 1), test.line('SU-005', 'Şişe', 3)),
  'payments', jsonb_build_array(test.pay('nakit', 230)), 'cash_given', 250));
select test.eq(test.stock('SU-005'), 240 - 27, 'Koli + şişe satışı temel birimden düşer');
select test.eq((select change_given from public.sales where id = '44444444-0000-0000-0000-000000000001'), 20.00::numeric, 'Para üstü hesaplanır');
select test.eq(test.cash_expected(), 230.00::numeric, 'Nakit satış kasaya net tutarla yazılır (S-03)');
select test.ok(test.open_session() is not null, 'İlk satış kasa gününü otomatik açar (K-02)');

-- S-02: aynı kimlikle tekrar gönderim
select test.eq((public.complete_sale(test.biz(), jsonb_build_object('id', '44444444-0000-0000-0000-000000000001',
  'items', jsonb_build_array(test.line('SU-005', 'Koli', 1)), 'payments', jsonb_build_array(test.pay('nakit', 200))))->>'duplicate')::boolean,
  true, 'Tekrar gönderilen satış ikinci kez kaydedilmez (S-02)');
select test.eq(test.stock('SU-005'), 213, 'Tekrar gönderim stoğu etkilemez');

-- S-01: hatada yarım kayıt kalmaz
select test.throws($$select public.complete_sale(test.biz(), jsonb_build_object('id', '44444444-0000-0000-0000-000000000002',
  'items', jsonb_build_array(test.line('SU-005', 'Koli', 1)), 'payments', jsonb_build_array(test.pay('nakit', 199))))$$,
  '%eşit değil%', 'Ödeme toplamı tutmazsa satış reddedilir (S-03)');
select test.eq((select count(*) from public.sales where id = '44444444-0000-0000-0000-000000000002')::int, 0, 'Başarısız satış kayıt bırakmaz (S-01)');
select test.eq(test.stock('SU-005'), 213, 'Başarısız satış stoğu değiştirmez');

-- Fiyat ve indirim kuralları
select test.throws($$select public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(),
  'items', jsonb_build_array(test.line('SU-005', 'Koli', 1, 150)), 'payments', jsonb_build_array(test.pay('nakit', 150))))$$,
  '%Fiyat güncel değil%', 'Satış personeli fiyatı değiştiremez');
select test.throws($$select public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(),
  'items', jsonb_build_array(test.line('SU-005', 'Koli', 1, 200, 11)), 'payments', jsonb_build_array(test.pay('nakit', 189))))$$,
  '%İndirim limitinizi%', 'Satış personeli %5 üstü indirim yapamaz (F-06)');
select test.lives($$select public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(),
  'items', jsonb_build_array(test.line('SU-005', 'Koli', 1, 200, 10)), 'payments', jsonb_build_array(test.pay('nakit', 190))))$$,
  'Satış personeli %5''e kadar indirim yapabilir');
select test.throws($$select public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(),
  'items', jsonb_build_array(test.line('BK-001', 'Adet', 1, 0)), 'payments', '[]'::jsonb))$$,
  '%Boş kap ürünü satılamaz%', 'Boş kap ürünü satılamaz');

select test.login(test.u_admin());
-- F-05: fiş indirimi satırlara oranla dağıtılır: 200 + 55 + 10 = 265, indirim 10
select public.complete_sale(test.biz(), jsonb_build_object('id', '44444444-0000-0000-0000-000000000003',
  'items', jsonb_build_array(test.line('SU-005', 'Koli', 1), test.line('SU-005', 'Paket', 1), test.line('SU-005', 'Şişe', 1)),
  'bill_discount', 10, 'payments', jsonb_build_array(test.pay('pos', 255))));
select test.eq((select sum(bill_discount_share) from public.sale_items where sale_id = '44444444-0000-0000-0000-000000000003'), 10.00::numeric,
  'Fiş indirimi paylarının toplamı indirime eşit');
select test.eq((select bill_discount_share from public.sale_items where sale_id = '44444444-0000-0000-0000-000000000003' and line_no = 1),
  7.55::numeric, 'Koli satırının payı 10 × 200/265 = 7,55');
select test.eq((select sum(line_net) from public.sale_items where sale_id = '44444444-0000-0000-0000-000000000003'), 255.00::numeric,
  'Satır netleri fiş toplamına eşit');
select test.lives($$select public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(),
  'items', jsonb_build_array(test.line('SU-005', 'Şişe', 1, 0)), 'payments', '[]'::jsonb))$$, 'Yönetici sıfır fiyatlı satış yapabilir (F-07)');

-- F-04: fiyat ve maliyet anlık görüntüsü
select public.set_unit_price(test.unit('SU-005', 'Koli'), 220);
select test.eq((select unit_price from public.sale_items where sale_id = '44444444-0000-0000-0000-000000000001' and line_no = 1),
  200.00::numeric, 'Sonradan fiyat değişse de geçmiş satış fiyatı değişmez (F-04)');
select test.eq((select c.unit_cost from public.sale_item_costs c join public.sale_items i on i.id = c.sale_item_id
                 where i.sale_id = '44444444-0000-0000-0000-000000000001' and i.line_no = 1), 6.0000::numeric,
  'Satış anındaki maliyet saklanır (M-04)');

-- Veresiye (V-01, V-02)
select test.login(test.u_satis());
select test.throws($$select public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(),
  'items', jsonb_build_array(test.line('SU-005', 'Koli', 1)), 'payments', jsonb_build_array(test.pay('veresiye', 220))))$$,
  '%müşteri seçilmelidir%', 'Müşterisiz veresiye yapılamaz (V-01)');
select test.throws($$select public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'customer_id', test.cust('M003'),
  'items', jsonb_build_array(test.line('SU-005', 'Koli', 1)), 'payments', jsonb_build_array(test.pay('veresiye', 220))))$$,
  '%limiti aşılıyor%', 'Limiti 0 olan müşteriye veresiye verilmez');
select public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'customer_id', test.cust('M001'),
  'items', jsonb_build_array(test.line('SU-005', 'Koli', 4)), 'payments', jsonb_build_array(test.pay('veresiye', 800), test.pay('nakit', 80))));
select test.eq(test.balance('M001'), 800.00::numeric, 'Bölünmüş ödemede veresiye kısmı bakiyeye yazılır (D-015)');
select test.throws($$select public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'customer_id', test.cust('M001'),
  'items', jsonb_build_array(test.line('SU-005', 'Koli', 1)), 'payments', jsonb_build_array(test.pay('veresiye', 220))))$$,
  '%limiti aşılıyor%', 'Limit aşımı engellenir (V-02)');
select test.throws($$select public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'customer_id', test.cust('M001'),
  'limit_override', true, 'items', jsonb_build_array(test.line('SU-005', 'Koli', 1)), 'payments', jsonb_build_array(test.pay('veresiye', 220))))$$,
  '%limiti aşılıyor%', 'Satış personeli limit aşımını onaylayamaz');
select test.lives($$select public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'customer_id', test.cust('M002'),
  'items', jsonb_build_array(test.line('SU-005', 'Koli', 10)), 'payments', jsonb_build_array(test.pay('veresiye', 2200))))$$,
  'Limitsiz müşteriye veresiye verilir');
select test.login(test.u_admin());
select test.eq((public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'customer_id', test.cust('M001'),
  'limit_override', true, 'items', jsonb_build_array(test.line('SU-005', 'Koli', 1)), 'payments', jsonb_build_array(test.pay('veresiye', 220))))->>'limit_override')::boolean,
  true, 'Yönetici limit aşımını onaylayabilir');
select test.ok(exists (select 1 from audit.log where action = 'satis_limit_asimi'), 'Limit aşımı denetim kaydına yazılır');
select test.login(test.u_satis());
select test.eq((public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'customer_id', test.cust('M001'), 'offline', true,
  'items', jsonb_build_array(test.line('SU-005', 'Şişe', 1)), 'payments', jsonb_build_array(test.pay('veresiye', 10))))->>'offline_limit_exceeded')::boolean,
  true, 'Çevrimdışı satış limit aşsa da kaydedilir ve işaretlenir (C-03)');
select test.eq(test.balance('M001'), 1030.00::numeric, 'Veresiye bakiyesi');

-- Depozito (D-03..D-06)
select public.complete_sale(test.biz(), jsonb_build_object('id', '44444444-0000-0000-0000-000000000010', 'customer_id', test.cust('M003'),
  'items', jsonb_build_array(test.line('DM-001', 'Damacana', 3)),
  'deposits', jsonb_build_array(jsonb_build_object('product_id', test.pid('DM-001'), 'empty_returned', 1)),
  'payments', jsonb_build_array(test.pay('nakit', 360 + 500))));
select test.eq((select deposit_total from public.sales where id = '44444444-0000-0000-0000-000000000010'), 500.00::numeric,
  '2 eksik boş için depozito alınır (D-03)');
select test.eq((select goods_net from public.sales where id = '44444444-0000-0000-0000-000000000010'), 360.00::numeric,
  'Depozito ciroya dahil değildir (D-04)');
select test.eq((select qty from public.container_balances where customer_id = test.cust('M003')), 2, 'Müşterinin elinde 2 kap görünür');
select test.eq(test.stock('BK-001'), 1, 'Getirilen boş kap stoğa girer');
select test.eq(test.stock('DM-001'), 47, 'Dolu damacana stoktan düşer');
-- Fazla boş getirme: 3 dolu alır, 4 boş getirir → 1 kap depozitosu iade edilir
select public.complete_sale(test.biz(), jsonb_build_object('id', '44444444-0000-0000-0000-000000000011', 'customer_id', test.cust('M003'),
  'items', jsonb_build_array(test.line('DM-001', 'Damacana', 3)),
  'deposits', jsonb_build_array(jsonb_build_object('product_id', test.pid('DM-001'), 'empty_returned', 4)),
  'payments', jsonb_build_array(test.pay('nakit', 360 - 250))));
select test.eq((select deposit_total from public.sales where id = '44444444-0000-0000-0000-000000000011'), -250.00::numeric,
  'Fazla getirilen boşun depozitosu fişten düşülür');
select test.eq((select qty from public.container_balances where customer_id = test.cust('M003')), 1, 'Müşterideki kap sayısı azalır');
select test.throws($$select public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'customer_id', test.cust('M001'),
  'items', jsonb_build_array(test.line('DM-001', 'Damacana', 1)),
  'deposits', jsonb_build_array(jsonb_build_object('product_id', test.pid('DM-001'), 'empty_returned', 2)),
  'payments', jsonb_build_array(test.pay('nakit', 120))))$$, '%elinde bu kadar kap%', 'Elinde kap olmayan müşteriye depozito iadesi yapılamaz');
-- Kayıtsız müşteri (D-06)
select public.complete_sale(test.biz(), jsonb_build_object('id', gen_random_uuid(),
  'items', jsonb_build_array(test.line('DM-001', 'Damacana', 1)),
  'deposits', jsonb_build_array(jsonb_build_object('product_id', test.pid('DM-001'), 'empty_returned', 0)),
  'payments', jsonb_build_array(test.pay('nakit', 370))));
select test.eq((select qty from public.container_balances where customer_id is null), 1, 'Kayıtsız müşterinin kabı perakende havuzunda izlenir (D-06)');
-- Depozito iadesi (D-05)
select public.container_return(test.biz(), jsonb_build_object('id', '55555555-0000-0000-0000-000000000001',
  'product_id', test.pid('DM-001'), 'qty', 1, 'refund_method', 'nakit'));
select test.eq((select amount from public.container_returns where id = '55555555-0000-0000-0000-000000000001'), 250.00::numeric, 'Ödenen depozito iade edilir');
select test.eq((select coalesce(sum(qty), 0)::int from public.container_balances where customer_id is null), 0, 'Havuzdaki kap düşer');
select test.throws($$select public.container_return(test.biz(), jsonb_build_object('id', gen_random_uuid(),
  'customer_id', test.cust('M003'), 'product_id', test.pid('DM-001'), 'qty', 1, 'kind', 'kayip'))$$,
  '%yalnızca yönetici%', 'Kap kaybını satış personeli işleyemez');

-- Tahsilat (V-04)
select public.record_customer_payment(test.biz(), jsonb_build_object('id', '66666666-0000-0000-0000-000000000001',
  'customer_id', test.cust('M001'), 'method', 'nakit', 'amount', 300));
select test.eq(test.balance('M001'), 730.00::numeric, 'Tahsilat bakiyeyi düşürür');
select test.eq(public.record_customer_payment(test.biz(), jsonb_build_object('id', '66666666-0000-0000-0000-000000000001',
  'customer_id', test.cust('M001'), 'method', 'nakit', 'amount', 300)), '66666666-0000-0000-0000-000000000001'::uuid, 'Tahsilat idempotent');
select test.eq(test.balance('M001'), 730.00::numeric, 'Tekrar gönderilen tahsilat bakiyeyi etkilemez');
select test.throws($$select public.cancel_customer_payment('66666666-0000-0000-0000-000000000001', 'hata')$$, '%yetkiniz yok%', 'Tahsilat iptalini satış personeli yapamaz (V-05)');

-- İptal (I-01)
select test.throws($$select public.cancel_sale('44444444-0000-0000-0000-000000000010', 'deneme')$$, '%yetkiniz yok%', 'Satış personeli iptal yapamaz (I-05)');
select public.request_return(jsonb_build_object('id', '77777777-0000-0000-0000-000000000001', 'sale_id', '44444444-0000-0000-0000-000000000001',
  'reason', 'Müşteri vazgeçti', 'items', '[]'::jsonb));
select test.eq((select count(*) from public.return_requests)::int, 1, 'Satış personeli iade talebi açabilir');
select test.throws($$select public.request_return(jsonb_build_object('id', gen_random_uuid(), 'sale_id', '44444444-0000-0000-0000-000000000003', 'reason', 'x'))$$,
  '%', 'Başkasının satışı için talep açılamaz');

select test.login(test.u_admin());
select test.eq(public.cancel_customer_payment('66666666-0000-0000-0000-000000000001', 'Yanlış müşteri')::text, '', 'Yönetici tahsilatı iptal eder');
select test.eq(test.balance('M001'), 1030.00::numeric, 'Tahsilat iptali bakiyeyi geri yükler');

select test.throws($$select public.cancel_sale('44444444-0000-0000-0000-000000000010', '')$$, '%nedeni zorunludur%', 'İptal nedeni zorunlu');
select public.cancel_sale('44444444-0000-0000-0000-000000000010', 'Yanlış giriş');
select test.eq((select status from public.sales where id = '44444444-0000-0000-0000-000000000010'), 'iptal', 'Satış iptal edildi, silinmedi (G-04)');
select test.eq(test.stock('DM-001'), 50 - 3 - 1 + 3 - 3 + 0, 'İptal dolu stoğu geri alır');   -- 50 −3 −3 −1 +3
select test.eq((select coalesce(sum(qty), 0)::int from public.container_balances where customer_id = test.cust('M003')), -1,
  'İptal müşterinin kap hareketini ters çevirir');
select test.eq((select count(*) from public.cash_movements where ref_id = '44444444-0000-0000-0000-000000000010')::int, 2, 'Kasa hareketi ters kayıtla kapanır');
select test.eq((select sum(amount) from public.cash_movements where ref_id = '44444444-0000-0000-0000-000000000010'), 0.00::numeric, 'Ters kayıt toplamı sıfır');
select test.throws($$select public.cancel_sale('44444444-0000-0000-0000-000000000010', 'tekrar')$$, '%zaten iptal%', 'İptal edilen satış tekrar iptal edilemez');
select test.throws($$select public.create_return(jsonb_build_object('id', gen_random_uuid(), 'sale_id', '44444444-0000-0000-0000-000000000010',
  'reason', 'x', 'items', '[]'::jsonb))$$, '%İptal edilmiş%', 'İptal edilmiş satış iade edilemez');

-- İade (I-02..I-04). Satış 1: 1 koli + 3 şişe, 230 nakit
select public.create_return(jsonb_build_object('id', '88888888-0000-0000-0000-000000000001', 'sale_id', '44444444-0000-0000-0000-000000000001',
  'reason', 'Hasarlı', 'request_id', '77777777-0000-0000-0000-000000000001',
  'items', jsonb_build_array(
    jsonb_build_object('sale_item_id', (select id from public.sale_items where sale_id = '44444444-0000-0000-0000-000000000001' and line_no = 2), 'qty', 2, 'condition', 'saglam'),
    jsonb_build_object('sale_item_id', (select id from public.sale_items where sale_id = '44444444-0000-0000-0000-000000000001' and line_no = 1), 'qty', 1, 'condition', 'kusurlu'))));
select test.eq((select total_refund from public.returns where id = '88888888-0000-0000-0000-000000000001'), 220.00::numeric, 'İade tutarı satış fiyatından hesaplanır');
select test.eq((select amount from public.return_payments where return_id = '88888888-0000-0000-0000-000000000001'), 220.00::numeric, 'Nakit ödenen satış nakit iade edilir (I-04)');
select test.eq((select count(*) from public.waste_records where reason = 'iade_kusurlu')::int, 1, 'Kusurlu iade fire kaydı oluşturur (I-03)');
select test.eq((select sum(qty)::int from public.stock_movements where ref_id = '88888888-0000-0000-0000-000000000001'), 2,
  'Sağlam iade stoğa döner, kusurlu iade döner ve fire olur');
select test.eq((select status from public.return_requests where id = '77777777-0000-0000-0000-000000000001'), 'onaylandi', 'İade talebi kapanır');
select test.throws($$select public.create_return(jsonb_build_object('id', gen_random_uuid(), 'sale_id', '44444444-0000-0000-0000-000000000001', 'reason', 'x',
  'items', jsonb_build_array(jsonb_build_object('sale_item_id', (select id from public.sale_items where sale_id = '44444444-0000-0000-0000-000000000001' and line_no = 2), 'qty', 2, 'condition', 'saglam'))))$$,
  '%kalan miktarı aşıyor%', 'Satılandan fazla iade edilemez (I-02)');
select public.create_return(jsonb_build_object('id', gen_random_uuid(), 'sale_id', '44444444-0000-0000-0000-000000000001', 'reason', 'x',
  'items', jsonb_build_array(jsonb_build_object('sale_item_id', (select id from public.sale_items where sale_id = '44444444-0000-0000-0000-000000000001' and line_no = 2), 'qty', 1, 'condition', 'saglam'))));
select test.eq((select sum(refund_amount) from public.return_items ri join public.sale_items si on si.id = ri.sale_item_id
                 where si.sale_id = '44444444-0000-0000-0000-000000000001'), 230.00::numeric, 'Parça parça iadelerin toplamı satış tutarını aşmaz');
select test.throws($$select public.cancel_sale('44444444-0000-0000-0000-000000000001', 'x')$$, '%İadesi yapılmış%', 'İadesi olan satış iptal edilemez');

-- Veresiye satış iadesi önce bakiyeden düşer (I-04)
select public.complete_sale(test.biz(), jsonb_build_object('id', '44444444-0000-0000-0000-000000000020', 'customer_id', test.cust('M002'),
  'items', jsonb_build_array(test.line('SU-005', 'Paket', 2)), 'payments', jsonb_build_array(test.pay('veresiye', 60), test.pay('nakit', 50))));
select public.create_return(jsonb_build_object('id', '88888888-0000-0000-0000-000000000002', 'sale_id', '44444444-0000-0000-0000-000000000020', 'reason', 'x',
  'items', jsonb_build_array(jsonb_build_object('sale_item_id', (select id from public.sale_items where sale_id = '44444444-0000-0000-0000-000000000020'), 'qty', 2, 'condition', 'saglam'))));
select test.eq((select method || ':' || amount from public.return_payments where return_id = '88888888-0000-0000-0000-000000000002' order by method limit 1),
  'nakit:50.00', 'Veresiye kısmı aşıldıktan sonra kalan nakit iade edilir');
select test.eq((select -amount from public.customer_ledger where ref_id = '88888888-0000-0000-0000-000000000002'), 60.00::numeric, 'Veresiye kısmı bakiyeden düşülür');

select test.eq((select count(*) from public.stock_consistency_check(test.biz()))::int, 0, 'Tüm işlemlerden sonra stok tutarlı');
rollback;
