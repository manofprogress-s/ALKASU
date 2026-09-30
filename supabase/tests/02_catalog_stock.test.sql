-- Katalog, birim dönüşümü, fiyat geçmişi, mal kabul, ortalama maliyet, fire (B-*, F-03, M-02, A-*, T-*)
begin;
select test.fixture();
select test.login(test.u_admin());

-- Açılış (fixture): 10 koli su (240 şişe) @144/koli, 50 damacana @80
select test.eq(test.stock('SU-005'), 240, 'Koli ile mal kabul temel birime çevrilir: 10 koli = 240 şişe (B-03)');
select test.eq(test.stock('DM-001'), 50, 'Damacana stoğu');
select test.eq(test.avg_cost('SU-005'), 6.0000::numeric, 'Koli alış fiyatı şişe maliyetine bölünür: 144/24 = 6');
select test.eq((select status from public.purchases order by no limit 1), 'onaylandi', 'Yönetici fiyatlı mal kabulü anında onaylanır');

-- Barkod
select test.eq((select p.code from public.product_barcodes b join public.products p on p.id = b.product_id
                 where b.barcode = '8690000000035'), 'SU-005', 'Barkod ürüne bağlı');
select test.eq((select u.name from public.product_barcodes b join public.product_units u on u.id = b.unit_id
                 where b.barcode = '8690000000035'), 'Koli', 'Koli barkodu koli birimine bağlı');
select test.throws($$select public.upsert_product(test.biz(), jsonb_build_object('code','X-1','name','X',
                     'barcodes', '[{"barcode":"8690000000028"}]'::jsonb))$$, '%başka bir üründe%', 'Aynı barkod iki üründe olamaz');
select test.throws($$select public.upsert_product(test.biz(), '{"code":"su-005","name":"Kopya"}')$$, '%kodu zaten%', 'Ürün kodu tekrar edemez (büyük/küçük harf duyarsız)');

-- B-06: çarpan değişmez; aynı adla farklı çarpan eski birimi pasife alır
select test.throws($$select public.upsert_product(test.biz(), jsonb_build_object('id', test.pid('SU-005'), 'code','SU-005','name','0,5 L Su',
                     'units', jsonb_build_array(jsonb_build_object('id', test.unit('SU-005','Koli'), 'name','Koli','factor',12,'price',100))))$$,
                   '%çarpanı değiştirilemez%', 'Mevcut birimin çarpanı değiştirilemez (B-06)');
select test.throws($$select public.upsert_product(test.biz(), jsonb_build_object('id', test.pid('SU-005'), 'code','SU-005','name','0,5 L Su',
                     'units', jsonb_build_array(jsonb_build_object('name','Paket','factor',6,'price',55),
                                                jsonb_build_object('name','Koli','factor',24,'price',200),
                                                jsonb_build_object('name','Palet','factor',960,'price',7000))))$$,
                   '%en fazla 2%', 'En fazla 2 ek birim (B-02)');
select test.throws($$select public.upsert_product(test.biz(), jsonb_build_object('code','Y-1','name','Y',
                     'units', '[{"name":"Paket","factor":1}]'::jsonb))$$, '%1''den büyük%', 'Ek birim çarpanı 1''den büyük olmalı');

-- Depozito kuralları
select test.throws($$select public.upsert_product(test.biz(), '{"code":"D-9","name":"D","deposit_amount":100}')$$,
                   '%boş kap ürünü seçilmelidir%', 'Depozitolu ürün boş kap ürünü ister (D-01)');
select test.throws($$select public.upsert_product(test.biz(), jsonb_build_object('code','D-9','name','D','deposit_amount',100,'empty_product_id', test.pid('SU-005')))$$,
                   '%boş kap%', 'Bağlı ürün "boş kap" olarak tanımlı olmalı');

-- F-03: fiyat geçmişi
select public.set_unit_price(test.unit('SU-005','Şişe'), 12);
select test.eq((select price from public.product_units where id = test.unit('SU-005','Şişe')), 12.00::numeric, 'Fiyat güncellendi');
select test.eq((select count(*) from public.product_prices where unit_id = test.unit('SU-005','Şişe'))::int, 2, 'Fiyat değişikliği geçmişe yazıldı');
select test.throws($$select public.set_unit_price(test.unit('BK-001','Adet'), 5)$$, '%Boş kap%', 'Boş kap ürününe fiyat verilemez');

-- A-01..A-03 + M-02: depo girer, stok artar, maliyet onayla değişir
select test.login(test.u_depo());
select public.upsert_supplier(test.biz(), '{"name":"Su Deposu A.Ş."}');
select public.receive_goods(test.biz(), jsonb_build_object('id', '22222222-0000-0000-0000-000000000001',
  'supplier_id', (select id from public.suppliers limit 1), 'doc_no', 'IRS-1',
  'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005','Koli'), 'qty', 5, 'unit_cost', 1))));
select test.eq(test.stock('SU-005'), 360, 'Mal kabul kaydıyla stok artar (A-02)');
select test.eq((select status from public.purchases where id = '22222222-0000-0000-0000-000000000001'), 'onay_bekliyor',
               'Depo personelinin girdiği fiyat dikkate alınmaz, onay bekler');
select test.login(test.u_admin());
select test.eq(test.avg_cost('SU-005'), 6.0000::numeric, 'Onaysız alış ortalama maliyeti değiştirmez (A-03)');
select public.approve_purchase('22222222-0000-0000-0000-000000000001',
  jsonb_build_array(jsonb_build_object('item_id', (select id from public.purchase_items where purchase_id = '22222222-0000-0000-0000-000000000001'), 'unit_cost', 168)));
-- (240×6 + 120×7) / 360 = 6,3333
select test.eq(test.avg_cost('SU-005'), 6.3333::numeric, 'Ağırlıklı ortalama maliyet (M-02)');
select test.throws($$select public.approve_purchase('22222222-0000-0000-0000-000000000001', '[]')$$, '%zaten onaylanmış%', 'Onaylı mal kabul tekrar onaylanamaz (A-04)');
select test.ok((select count(*) from public.cost_history where product_id = test.pid('SU-005')) = 2, 'Maliyet geçmişi tutulur');

-- A-05: bedelsiz ürün ortalamayı düşürür. 1 koli @144 + 1 koli bedelsiz: (360×6,3333 + 24×6)/(360+48)
select public.receive_goods(test.biz(), jsonb_build_object('id', gen_random_uuid(),
  'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005','Koli'),
                                                'qty', 1, 'free_qty', 1, 'unit_cost', 144))));
select test.eq(test.stock('SU-005'), 408, 'Bedelsiz miktar stoğa girer');
select test.eq(test.avg_cost('SU-005'), round((360 * 6.3333 + 24 * 6.0) / 408, 4), 'Bedelsiz miktar ortalama maliyeti düşürür (A-05)');

-- Negatif stok varken mal kabul: yeni maliyet doğrudan alınır (M-02 son cümle)
select test.sell('DM-001', 'Damacana', 60);   -- boşlar getirildi (varsayılan), depozito yok
select test.eq(test.stock('DM-001'), -10, 'Stok yetersizliği satışı engellemez, stok negatife düşer (S-05)');
select public.receive_goods(test.biz(), jsonb_build_object('id', gen_random_uuid(),
  'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('DM-001'), 'unit_id', test.unit('DM-001','Damacana'), 'qty', 20, 'unit_cost', 90))));
select test.eq(test.avg_cost('DM-001'), 90.0000::numeric, 'Eldeki ≤ 0 iken ortalama = yeni alış maliyeti');

-- A-06: tedarikçiye boş kap iadesi
select public.receive_goods(test.biz(), jsonb_build_object('id', gen_random_uuid(),
  'empties', jsonb_build_array(jsonb_build_object('product_id', test.pid('BK-001'), 'qty', 30))));
select test.eq(test.stock('BK-001'), 60 - 30, 'Satışta gelen 60 boş, tedarikçiye 30 iade');
select test.throws($$select public.receive_goods(test.biz(), jsonb_build_object('id', gen_random_uuid(),
  'empties', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'qty', 1))))$$, '%boş kap%', 'Yalnızca boş kap ürünü iade edilir');

-- Idempotency
select test.eq((public.receive_goods(test.biz(), jsonb_build_object('id', '22222222-0000-0000-0000-000000000001', 'items', '[]'::jsonb))->>'duplicate')::boolean,
               true, 'Aynı mal kabul iki kez kaydedilmez');

-- Fire
select test.login(test.u_depo());
select public.record_waste(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'product_id', test.pid('SU-005'),
  'unit_id', test.unit('SU-005','Paket'), 'qty', 2, 'reason', 'kirik'));
select test.eq(test.stock('SU-005'), 396, 'Fire paket biriminde girilir, temel birimden düşer (2×6)');
select test.throws($$select public.record_waste(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'product_id', test.pid('SU-005'), 'qty', 1, 'reason', 'bilinmeyen'))$$,
                   '%reason_check%', 'Fire nedeni listeden seçilir');
select test.login(test.u_admin());
select test.eq(public.record_waste(test.biz(), jsonb_build_object('id', '33333333-0000-0000-0000-000000000001', 'product_id', test.pid('SU-005'), 'qty', 1, 'reason', 'kayip')),
               public.record_waste(test.biz(), jsonb_build_object('id', '33333333-0000-0000-0000-000000000001', 'product_id', test.pid('SU-005'), 'qty', 1, 'reason', 'kayip')),
               'Fire kaydı idempotent');
select test.eq(test.stock('SU-005'), 395, 'Tekrarlanan fire stoğu iki kez düşürmez');

-- Tutarlılık ve değiştirilemezlik
select test.eq((select count(*) from public.stock_consistency_check(test.biz()))::int, 0, 'Stok seviyesi = hareket toplamı (T-007)');
select test.logout();
select test.throws($$update public.stock_movements set qty = 1$$, '%değiştirilemez%', 'Stok hareketi değiştirilemez (G-04)');
select test.throws($$delete from public.stock_movements$$, '%değiştirilemez%', 'Stok hareketi silinemez (G-04)');

rollback;
