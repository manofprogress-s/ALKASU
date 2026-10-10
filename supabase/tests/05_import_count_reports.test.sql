-- İçe aktarma (E-*), sayım (T-04), raporlar (M-06, T-05, T-06, V-06)
begin;
select test.fixture();
select test.login(test.u_admin());

-- E-01: hatalı dosya hiçbir şey yazmaz
create temp table _bad as select public.import_products(test.biz(), '[
  {"row":2,"urun_kodu":"A-1","urun_adi":"Ürün A","marka":"Yeni Marka","kategori":"Meşrubat","temel_birim":"Adet","kdv_orani":"20","satis_fiyati":"25.5"},
  {"row":3,"urun_kodu":"A-1","urun_adi":"Kopya","marka":"Yeni Marka","kategori":"Meşrubat","temel_birim":"Adet","kdv_orani":"18"},
  {"row":4,"urun_kodu":"A-2","urun_adi":"","marka":"X","kategori":"Y","temel_birim":"Adet","kdv_orani":"1","paket_satis_fiyati":"10"},
  {"row":5,"urun_kodu":"DM-9","urun_adi":"Damacana","marka":"X","kategori":"Y","temel_birim":"Adet","kdv_orani":"1","depozitolu":"E","depozito_tutari":"200","bos_kap_urun_kodu":"YOK"}
]'::jsonb, false) as r;
select test.eq(((select r from _bad)->>'ok')::boolean, false, 'Hatalı dosya reddedilir');
select test.eq(((select r from _bad)->>'applied')::boolean, false, 'Hatalı dosyada hiçbir kayıt yapılmaz (E-01)');
select test.ok((select r from _bad)->'errors' @> '[{"row":3,"field":"urun_kodu"}]', 'Dosyada tekrar eden kod yakalanır');
select test.ok((select r from _bad)->'errors' @> '[{"row":3,"field":"kdv_orani"}]', 'Geçersiz KDV oranı yakalanır');
select test.ok((select r from _bad)->'errors' @> '[{"row":4,"field":"urun_adi"}]', 'Boş zorunlu alan yakalanır');
select test.ok((select r from _bad)->'errors' @> '[{"row":4,"field":"paket_icerik"}]', 'İçeriksiz paket fiyatı yakalanır');
select test.ok((select r from _bad)->'errors' @> '[{"row":5,"field":"bos_kap_urun_kodu"}]', 'Bulunamayan boş kap ürünü yakalanır');
select test.eq((select count(*) from public.products where code = 'A-1')::int, 0, 'Hatalı aktarımdan ürün oluşmaz');

-- Başarılı aktarım: boş kap + damacana + kolili ürün + mevcut ürün güncellemesi
create temp table _ok as select public.import_products(test.biz(), '[
  {"row":2,"urun_kodu":"DM-2","urun_adi":"Marka B 19 L","marka":"Marka B","kategori":"Damacana","temel_birim":"Damacana","kdv_orani":"1","satis_fiyati":"110","alis_fiyati":"75","acilis_stogu":"30","depozitolu":"E","depozito_tutari":"200","bos_kap_urun_kodu":"BK-2","barkod":"8691111111111"},
  {"row":3,"urun_kodu":"BK-2","urun_adi":"Marka B Boş","marka":"Marka B","kategori":"Boş kap","temel_birim":"Adet","kdv_orani":"20","bos_kap_mi":"E","acilis_stogu":"12"},
  {"row":4,"urun_kodu":"KL-1","urun_adi":"Kola 1 L","marka":"Marka C","kategori":"Meşrubat","temel_birim":"Şişe","kdv_orani":"20","satis_fiyati":"40","paket_icerik":"6","paket_satis_fiyati":"220","koli_icerik":"12","koli_satis_fiyati":"420","alis_fiyati":"30","acilis_stogu":"120","kritik_stok":"24"},
  {"row":5,"urun_kodu":"SU-005","urun_adi":"0,5 L Su (yeni ad)","marka":"Örnek Marka","kategori":"Su","temel_birim":"Şişe","kdv_orani":"1","satis_fiyati":"11","paket_icerik":"6","paket_satis_fiyati":"60","koli_icerik":"24","koli_satis_fiyati":"210","acilis_stogu":"999"}
]'::jsonb, false) as r;
select test.eq(((select r from _ok)->>'applied')::boolean, true, 'Geçerli dosya aktarılır');
select test.eq(((select r from _ok)->'summary'->>'new')::int, 3, '3 yeni ürün');
select test.eq(((select r from _ok)->'summary'->>'updated')::int, 1, '1 güncellenen ürün (E-02)');
select test.eq(test.stock('DM-2'), 30, 'Açılış stoğu uygulanır');
select test.eq(test.stock('BK-2'), 12, 'Boş kap açılış stoğu');
select test.eq(test.avg_cost('DM-2'), 75.0000::numeric, 'Açılış maliyeti uygulanır');
select test.eq((select empty_product_id from public.products where code = 'DM-2'), test.pid('BK-2'), 'Aynı dosyadaki boş kap bağlanır');
select test.eq((select price from public.product_units where id = test.unit('KL-1', 'Koli')), 420.00::numeric, 'Koli fiyatı');
select test.eq((select factor from public.product_units where id = test.unit('KL-1', 'Paket')), 6, 'Paket çarpanı');
select test.eq(test.stock('SU-005'), 240, 'Hareketi olan ürüne açılış stoğu uygulanmaz (E-03)');
select test.ok((select r from _ok)->'warnings' @> '[{"row":5,"field":"acilis_stogu"}]', 'Yok sayılan açılış stoğu için uyarı verilir');
select test.eq((select name from public.products where code = 'SU-005'), '0,5 L Su (yeni ad)', 'Mevcut ürün adı güncellenir');
select test.eq((select count(*) from public.product_prices where unit_id = test.unit('SU-005', 'Şişe'))::int, 2, 'Fiyat değişikliği geçmişe yazılır');
select test.ok(exists (select 1 from public.brands where name = 'Marka C'), 'Yeni marka otomatik oluşur (E-04)');
select test.ok(exists (select 1 from public.product_barcodes where barcode = '8691111111111'), 'Barkod aktarılır');
select test.eq((select count(*) from public.stock_consistency_check(test.biz()))::int, 0, 'Aktarım sonrası stok tutarlı');

select test.login(test.u_satis());
select test.throws($$select public.import_products(test.biz(), '[{"row":2}]'::jsonb)$$, '%yetkiniz yok%', 'İçe aktarmayı yalnızca yönetici yapar');
select test.login(test.u_admin());

-- Müşteri aktarımı (D-09)
select public.import_customers(test.biz(),
  '[{"row":2,"musteri_kodu":"C-10","ad_unvan":"Yeni Market","kredi_limiti":"5000","acilis_bakiyesi":"1250.50"}]'::jsonb,
  '[{"row":2,"musteri_kodu":"C-10","dolu_urun_kodu":"DM-2","kap_adedi":"4","odenen_depozito":"800"}]'::jsonb, false);
select test.eq(test.balance('C-10'), 1250.50::numeric, 'Açılış veresiye bakiyesi aktarılır');
select test.eq((select qty from public.container_balances where customer_id = test.cust('C-10')), 4, 'Müşterideki kaplar aktarılır');
select test.eq((public.container_return(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'customer_id', test.cust('C-10'),
  'product_id', test.pid('DM-2'), 'qty', 1, 'refund_method', 'veresiye'))->>'amount')::numeric, 200.00::numeric,
  'Aktarılan kap iade edildiğinde ödenen depozito geri verilir');
select test.eq(test.balance('C-10'), 1050.50::numeric, 'Depozito veresiyeden mahsup edilir (D-05)');

-- Sayım (T-04): sayım sırasında satış olsa da fark doğru hesaplanır
select public.start_stock_count(test.biz(), jsonb_build_object('id', 'bbbbbbbb-0000-0000-0000-000000000001',
  'product_ids', jsonb_build_array(test.pid('SU-005'), test.pid('KL-1'))));
select test.throws($$select public.start_stock_count(test.biz(), jsonb_build_object('id', gen_random_uuid()))$$, '%Açık bir sayım%', 'Aynı anda tek sayım açık olabilir');
select test.sell('SU-005', 'Paket', 1);                       -- sayım sırasında 6 şişe satıldı
select test.login(test.u_depo());
select public.save_stock_count_lines('bbbbbbbb-0000-0000-0000-000000000001', jsonb_build_array(
  jsonb_build_object('product_id', test.pid('SU-005'), 'counted_qty', 230),   -- beklenen 234 → fark −4
  jsonb_build_object('product_id', test.pid('KL-1'), 'counted_qty', 120)));   -- fark 0
select test.throws($$select public.approve_stock_count('bbbbbbbb-0000-0000-0000-000000000001')$$, '%yetkiniz yok%', 'Sayımı depo onaylayamaz');
select test.login(test.u_admin());
select test.eq((public.approve_stock_count('bbbbbbbb-0000-0000-0000-000000000001')->>'net_diff')::int, -4, 'Fark = sayılan − (görüntü + sayım sırasındaki hareket)');
select test.eq(test.stock('SU-005'), 230, 'Onaydan sonra stok sayılan miktara eşit');
select test.throws($$select public.save_stock_count_lines('bbbbbbbb-0000-0000-0000-000000000001', '[]')$$, '%kapanmış%', 'Onaylı sayım değiştirilemez');

-- Raporlar
select test.sell('KL-1', 'Koli', 1);                           -- 420 ciro, maliyet 12×30 = 360
create temp table _ps as select * from public.report_product_sales(test.biz(), app.local_date(now()), app.local_date(now()));
select test.eq((select revenue from _ps where key_name = 'Kola 1 L'), 420.00::numeric, 'Ürün cirosu');
select test.eq((select gross_profit from _ps where key_name = 'Kola 1 L'), 60.00::numeric, 'Brüt kâr = ciro − satılan malın maliyeti (M-06)');
select test.eq((select net_revenue from public.report_daily_sales(test.biz(), app.local_date(now()), app.local_date(now()))), 480.00::numeric,
               'Günlük net ciro (paket 60 + koli 420)');
select test.eq((select status from public.report_stock(test.biz()) where code = 'KL-1'), 'normal', 'Stok durumu hesaplanır');
select test.eq((select suggested_critical from public.report_stock(test.biz()) where code = 'KL-1'), 3, 'Kritik stok önerisi = günlük ort. × 7 (T-05)');
select test.eq((select balance from public.report_receivables(test.biz()) where code = 'C-10'), 1050.50::numeric, 'Veresiye raporu bakiyesi');
select test.eq((select d0_30 from public.report_receivables(test.biz()) where code = 'C-10'), 1050.50::numeric, 'Yaşlandırma (V-06)');
select test.eq((select count(*) from public.customer_statement(test.cust('C-10')))::int, 2, 'Cari ekstre hareketleri');
select test.ok((public.dashboard(test.biz())->>'critical_count') is not null, 'Ana sayfa özeti');

select test.login(test.u_izleyici());
select test.throws($$select * from public.report_product_sales(test.biz(), current_date, current_date)$$, '%yetkiniz yok%',
               'İzleyici ürün satış/kâr raporunu göremez (G-18)');
select test.throws($$select * from public.report_daily_sales(test.biz(), current_date, current_date)$$, '%yetkiniz yok%',
               'İzleyici dönemsel satış raporunu göremez (G-18)');
select test.eq((public.dashboard(test.biz())->>'net_revenue')::numeric, 480.00::numeric, 'İzleyici bugünkü satışı ana sayfada görür (G-18)');
select test.ok((public.dashboard(test.biz())->>'gross_profit') is null, 'İzleyici kârı görmez (G-18)');
select test.ok((select stock_value from public.report_stock(test.biz()) where code = 'KL-1') is null, 'İzleyici stok değerini göremez');
select test.throws($$select * from public.report_receivables(test.biz())$$, '%yetkiniz yok%', 'İzleyici veresiye raporunu göremez');
select test.login(test.u_satis());
select test.throws($$select * from public.report_daily_sales(test.biz(), current_date, current_date)$$, '%yetkiniz yok%', 'Satış personeli genel satış raporunu göremez');
select test.ok((public.dashboard(test.biz())->>'my_sales_count') is not null, 'Satış personeli kendi günlük özetini görür');
select test.ok((public.dashboard(test.biz())->>'gross_profit') is null, 'Satış personelinin özetinde kâr yok');
select test.eq((public.dashboard(test.biz())->>'net_revenue')::numeric, 480.00::numeric, 'Satış personeli bugünkü toplam satışı görür (G-18)');
select test.ok((public.dashboard(test.biz())->>'credit') is not null, 'Satış personeli bugünkü veresiye satışını görür (G-18)');
select test.ok((public.dashboard(test.biz())->>'receivables_total') is null, 'Satış personeli toplam veresiye alacağını görmez (G-18)');
select test.login(test.u_depo());
select test.eq((public.dashboard(test.biz())->>'net_revenue')::numeric, 480.00::numeric, 'Depo personeli bugünkü satışı görür (G-18)');
select test.ok((public.dashboard(test.biz())->>'gross_profit') is null, 'Depo personeli kârı görmez (G-18)');
select test.login(test.u_admin());
select test.ok((public.dashboard(test.biz())->>'gross_profit') is not null, 'Yönetici brüt kârı görür');

rollback;
