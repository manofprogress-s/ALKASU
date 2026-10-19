-- Abone listesi içe aktarma + müşteri durum raporu + arama kaydı (M-20…M-26)
begin;
select test.fixture();
create function test.u_b1() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000051'::uuid $$;
grant execute on all functions in schema test to authenticated;
insert into auth.users(id, email) values (test.u_b1(), 'ibrahim@t');

-- Telefon normalleştirme
select test.eq(app.norm_phone('05063029835'), '05063029835', 'Cep telefonu');
select test.eq(app.norm_phone('+90 506 302 98 35'), '05063029835', '+90 ile');
select test.eq(app.norm_phone('0262 331 22 11'), '02623312211', 'Sabit hat');
select test.ok(app.norm_phone('01010101010') is null and app.norm_phone('00000000000') is null and app.norm_phone('02222222222') is null
               and app.norm_phone('09876543212') is null and app.norm_phone('3731034') is null, 'Sahte numaralar atılır');

update public.customers set phone = '0532 111 22 33' where id = test.cust('M002');

select test.login(test.u_admin());
create temp table rows on commit drop as select $$[
  {"row":2,"abone":333,"tur":"EV","tip":"Normal","ad":"Ayşe Kaya","adres":"Köseköy Mah.","ilce":"KARTEPE","saha":"KÖSEKÖY","marka":"GURPINAR",
   "son_satis":"__D10__","telefonlar":["05063029835","0","05063029835","05551112233"],"kayit":"2023-09-18","periyot":25,"siparis_sayisi":34,
   "toplam_satis":12920,"borc":0,"konum":"40.737824,30.005943","tercih":"GURPINAR-19 LT DAMACANA"},
  {"row":3,"abone":945,"tur":"EV","tip":"Normal","ad":"17 Ağustos İlkokulu","son_satis":"__D400__","telefonlar":["05376118342"],
   "periyot":0,"siparis_sayisi":0,"toplam_satis":0,"borc":0,"konum":"0,0"},
  {"row":4,"abone":730,"tur":"İŞYERİ","tip":"Kurumsal","ad":"Antrepo AŞ","son_satis":"__D34__","telefonlar":["05321112233"],
   "periyot":16,"siparis_sayisi":27,"toplam_satis":28695,"borc":6120},
  {"row":5,"abone":12,"ad":"Hiç Almamış","telefonlar":["01010101010"],"siparis_sayisi":0},
  {"row":6,"abone":13,"ad":"Düzenli Müşteri","son_satis":"__D3__","telefonlar":["05440000001"],"periyot":20,"siparis_sayisi":9},
  {"row":7,"abone":14,"ad":"PEŞİNCİ  MÜŞTERİ SAN.","telefonlar":[]}
]$$::text as j;
update rows set j = replace(replace(replace(replace(j,
  '__D10__', (now() - interval '10 days')::text), '__D400__', (now() - interval '400 days')::text),
  '__D34__', (now() - interval '34 days')::text), '__D3__', (now() - interval '3 days')::text);

select test.eq((public.import_subscribers(test.biz(), (select j::jsonb from rows), true))->'summary'->>'new', '4', 'Ön kontrol: 4 yeni');
select test.eq((public.import_subscribers(test.biz(), (select j::jsonb from rows), true))->'summary'->>'phone_match', '2', 'Telefon ve ad başıyla mevcut kartlar eşleşir');
select test.eq((select count(*) from public.customers where legacy_no is not null)::int, 0, 'Ön kontrol hiçbir şey yazmaz');
select test.eq((public.import_subscribers(test.biz(), (select j::jsonb from rows), false))->>'applied', 'true', 'Aktarım uygulanır');
select test.eq((select legacy_no from public.customers where id = test.cust('M002')), 730, 'Mevcut müşteri abone numarasına bağlandı (çift kayıt yok)');
select test.eq((select name from public.customers where id = test.cust('M002')), 'Limitsiz Firma', 'Elle girilmiş ad korunur');
select test.eq((select code from public.customers where legacy_no = 333 and business_id = test.biz()), 'A333', 'Yeni müşteri kodu A + abone no');
select test.eq((select extra_phones from public.customers where legacy_no = 333), array['05551112233'], 'Ek telefonlar tekrarsız, geçersizler atılır');
select test.ok((select latitude is not null and area = 'Köseköy' and brand_pref = 'Gurpinar' from public.customers where legacy_no = 333), 'Konum, saha, marka');
select test.ok((select latitude is null and phone = '05376118342' from public.customers where legacy_no = 945), '0,0 konumu atılır');
select test.ok((select phone is null from public.customers where legacy_no = 12), 'Sahte telefon kaydedilmez');
select test.eq((select legacy_debt from public.customers where legacy_no = 730), 6120.00, 'Eski borç bilgi olarak saklanır');
select test.eq((select count(*) from public.customer_ledger where customer_id = test.cust('M002'))::int, 0, 'Eski borç cariye işlenmez');
select test.eq((select count(*) from audit.log where action = 'abone_ice_aktarma')::int, 1, 'Aktarım işlem geçmişine yazılır');

-- Tekrar yükleme: güncellenir, yeni kayıt açılmaz
select test.eq((public.import_subscribers(test.biz(), (select j::jsonb from rows), false))->'summary'->>'new', '0', 'Aynı dosya tekrar: yeni kayıt yok');
select test.eq((select count(*) from public.customers where legacy_no is not null)::int, 6, 'Toplam 6 abone');
select test.eq((select legacy_no from public.customers where id = test.cust('M003')), 14, 'Adın başı tutan elle açılmış kart bağlandı');
select test.eq((public.import_subscribers(test.biz(), '[{"row":2,"abone":99,"ad":"ahmet bakkal"},{"row":3,"abone":98,"ad":"Ahmet Bakkal"}]', true))->'summary'->>'phone_match', '0',
               'Dosyada aynı ad iki kez geçerse adla bağlanmaz');
select test.eq((public.import_subscribers(test.biz(), '[{"row":2,"abone":99,"ad":"ahmet  bakkal"}]', true))->'matched'->0->>'nasil', 'ad', 'Ad (büyük/küçük harf, boşluk farkı) eşleşir');
select test.eq(jsonb_array_length(public.import_subscribers(test.biz(), '[{"row":2,"abone":1,"ad":"a"},{"row":3,"abone":1,"ad":"b"},{"row":4,"ad":"c"}]', true)->'errors'), 2,
               'Tekrar eden ve numarasız abone hata');

-- Durum
select test.logout();
select test.eq((select bucket from app.customer_status(test.biz(), null) where name = 'Ayşe Kaya'), 'duzenli', '10 gün önce, 25 günlük periyot: düzenli');
select test.eq((select bucket from app.customer_status(test.biz(), null) where name = 'Limitsiz Firma'), 'gecikti', '34 gün, 16 günlük periyot (2 katını aştı): gecikti');
select test.eq((select bucket from app.customer_status(test.biz(), null) where name = '17 Ağustos İlkokulu'), 'uyuyan', '400 gün: uyuyan');
select test.eq((select bucket from app.customer_status(test.biz(), null) where name = 'Hiç Almamış'), 'hic', 'Alımı yok');
select test.eq((select bucket from app.customer_status(test.biz(), null) where name = 'Ahmet Bakkal'), 'hic', 'Elle açılmış, satışı yok');

select test.login(test.u_satis());
select test.eq((public.customer_status_summary(test.biz()))->>'active30', '2', 'Son 30 günde alan: 2');
select test.eq((public.customer_status_summary(test.biz()))->>'call_now', '1', 'Aranacak: 1');
select test.eq((select name from public.customer_status_list(test.biz(), 'ara') limit 1), 'Limitsiz Firma', 'Arama listesi');
select test.ok((select legacy_debt is null and total is null from public.customer_status_list(test.biz(), 'ara') limit 1), 'Satış personeli tutar/eski borç görmez');
select test.eq((select count(*) from public.customer_status_list(test.biz(), 'tumu', '0506 302'))::int, 1, 'Telefonla arama');
select test.eq((select count(*) from public.customer_status_list(test.biz(), 'tumu', null, 'Köseköy'))::int, 1, 'Bölge filtresi');

-- Arama kaydı: listeden düşer, tabloda görünür
select test.lives($$select public.log_customer_call(test.biz(), (select id from public.customers where legacy_no = 730), 'sonra', 'Perşembe arayın')$$, 'Arama sonucu kaydedilir');
select test.eq((public.customer_status_summary(test.biz()))->>'call_now', '0', 'Ertelenen müşteri listeden düşer');
select test.eq((public.customer_status_summary(test.biz()))->>'snoozed', '1', 'Ertelenenler sayılır');
select test.eq((public.customer_status_summary(test.biz()))->'callers'->0->>'today', '1', 'Bugünkü arama sayısı');
select test.throws($$select public.log_customer_call(test.biz(), test.cust('M001'), 'bilinmez')$$, '%Geçersiz%', 'Geçersiz sonuç');
select test.throws($$update public.customer_calls set note = 'x'$$, '%', 'Arama kaydı değiştirilemez');

select test.login(test.u_admin());
select test.eq((select legacy_debt from public.customer_status_list(test.biz(), 'tumu', 'Limitsiz')), 6120.00, 'Yönetici eski borcu görür');

-- Yetki
select test.login(test.u_satis());
select test.throws($$select public.import_subscribers(test.biz(), '[]', true)$$, '%yetkiniz yok%', 'Satış personeli aktarım yapamaz');
select test.login(test.u_depo());
select test.throws($$select public.customer_status_summary(test.biz())$$, '%yetkiniz yok%', 'Depo raporu göremez');
select test.login(test.u_outsider());
select test.throws($$select * from public.customer_status_list(test.biz(), 'ara')$$, '%yetkiniz yok%', 'Dışarıdan erişilemez');

-- Bayi yalnızca kendi müşterilerini görür; bizimkiler görünmez
select test.login(test.u_admin());
select public.upsert_customer(test.biz(), '{"code":"B001","name":"Sağlam Ticaret","channel":"bayi","price_list":"bayi"}'::jsonb);
select public.add_member(test.biz(), test.u_b1(), 'bayi', 'İbrahim', test.cust('B001'));
select test.logout();
update public.customers set owner_dealer_id = test.cust('B001') where legacy_no = 13;
select test.login(test.u_b1());
select test.eq((public.customer_status_summary(test.biz()))->>'total', '1', 'Bayi yalnızca kendi müşterisini sayar');
select test.eq((select name from public.customer_status_list(test.biz(), 'tumu')), 'Düzenli Müşteri', 'Bayi kendi müşterisini görür');
select test.throws($$select public.log_customer_call(test.biz(), test.cust('M001'), 'sonra')$$, '%bulunamadı%', 'Bayi bizim müşterimizi arama kaydına yazamaz');
select test.login(test.u_satis());
select test.eq((select count(*) from public.customer_status_list(test.biz(), 'tumu', 'Düzenli'))::int, 0, 'Bayi müşterisi bizim arama listemizde yok');
rollback;
