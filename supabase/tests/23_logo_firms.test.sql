-- Logo İşbaşı cari listesi eşleştirme (F-28)
begin;
select test.fixture();
grant execute on all functions in schema test to authenticated;

select test.eq(app.firm_word('AKHAUS PVC PENCERE VE KAPI SİSTEMLERİ'), 'akhaus', 'İlk anlamlı kelime');
select test.eq(app.firm_word('ÖZEL ŞEHİR AĞIZ VE DİŞ'), 'sehir', 'Genel kelime atlanır');
select test.eq(app.firm_key('Limitsiz  Firma Ltd.Şti.'), 'limitsiz firma ltd sti', 'Karşılaştırma anahtarı');

-- Kartlar: M002 vergi no ile, M001 telefonla, "Akhause" isimle eşleşecek
update public.customers set tax_no = '1234567890' where id = test.cust('M002');
update public.customers set phone = '0532 111 22 33' where id = test.cust('M001');
select test.login(test.u_admin());
select public.upsert_customer(test.biz(), jsonb_build_object('code', 'M010', 'name', 'Akhause'));
select public.upsert_customer(test.biz(), jsonb_build_object('code', 'M011', 'name', 'Ahmet Usta'));

create temp table rows_in on commit drop as select '[
  {"row":2,"code":"0000000000000001","tip":"kurumsal","unvan":"LİMİTSİZ FİRMA TİCARET LTD","vkn":"1234567890","vd":"ALEMDAR","sehir":"Kocaeli","ilce":"Kartepe","adres":"Köseköy","eposta":"MUHASEBE@ornek.com"},
  {"row":3,"code":"0000000000000002","tip":"bireysel","unvan":"AHMET YILMAZ","vkn":"10000000146","telefon":"05321112233"},
  {"row":4,"code":"0000000000000003","tip":"kurumsal","unvan":"AKHAUS PVC PENCERE A.Ş.","vkn":"9876543217"},
  {"row":5,"code":"0000000000000004","tip":"kurumsal","unvan":"BAMBAŞKA FİRMA","vkn":"9876543217"},
  {"row":6,"code":"0000000000000005","tip":"bireysel","unvan":"AHMET KAYA","vkn":"10000000146"}
]'::jsonb as j;

create temp table pv on commit drop as select public.logo_firms_preview(test.biz(), (select j from rows_in)) as p;
select test.eq((select p->'results'->0->>'status' from pv), 'kesin', 'Vergi no ile kesin eşleşme');
select test.eq((select p->'results'->1->>'status' from pv), 'olasi', 'Telefonla olası eşleşme');
select test.eq((select p->'results'->1->'candidates'->0->>'code' from pv), 'M001', 'Telefon adayı doğru kart');
select test.eq((select p->'results'->2->>'status' from pv), 'olasi', 'İsim benzerliği (Akhaus ~ Akhause)');
select test.eq((select p->'results'->3->>'status' from pv), 'yok', 'Eşleşmeyen firma');
select test.eq((select p->'results'->4->>'status' from pv), 'yok', 'Bireyselde yalnızca ad benzerliği (Ahmet) eşleştirmez');
select test.eq((select jsonb_array_length(p->'duplicates') from pv), 2, 'Listede tekrar eden vergi numaraları bildirilir');

-- Bağla: boş alanlar dolar, dolu alan korunur
select test.logout();
update public.customers set address = 'Eski adres' where id = test.cust('M002');
select test.login(test.u_admin());
select test.eq((public.logo_firms_apply(test.biz(), jsonb_build_array(
  jsonb_build_object('customer', test.cust('M002'), 'firm', (select j->0 from rows_in)))))->>'linked', '1', 'Bağlandı');
select test.eq((select logo_code from public.customers where id = test.cust('M002')), '0000000000000001', 'İşbaşı kodu kaydedildi');
select test.eq((select tax_office from public.customers where id = test.cust('M002')), 'ALEMDAR', 'Boş vergi dairesi dolduruldu');
select test.eq((select address from public.customers where id = test.cust('M002')), 'Eski adres', 'Dolu adres değiştirilmedi');
select test.eq((select email from public.customers where id = test.cust('M002')), 'muhasebe@ornek.com', 'E-posta küçük harfle');
select test.eq((select legal_title from public.customers where id = test.cust('M002')), 'LİMİTSİZ FİRMA TİCARET LTD', 'Unvan dolduruldu');
select test.eq((select public.logo_firms_preview(test.biz(), (select j from rows_in))->'results'->0->>'status'), 'bagli', 'Tekrar yüklemede "zaten bağlı"');

-- Aynı kod ikinci karta bağlanamaz; farklı VKN değiştirilmez, uyarı verilir
select test.eq((public.logo_firms_apply(test.biz(), jsonb_build_array(
  jsonb_build_object('customer', test.cust('M003'), 'firm', (select j->0 from rows_in)))))->'errors'->0->>'message',
  'Bu İşbaşı kodu başka bir karta bağlı', 'Kod tek karta bağlanır');
select test.logout();
update public.customers set tax_no = '1234567890' where id = test.cust('M010');
select test.login(test.u_admin());
select test.ok((public.logo_firms_apply(test.biz(), jsonb_build_array(
  jsonb_build_object('customer', test.cust('M010'), 'firm', (select j->2 from rows_in)))))->'warnings'->0->>'message' like '%farklı vergi no%', 'Farklı VKN uyarısı');
select test.eq((select tax_no from public.customers where id = test.cust('M010')), '1234567890', 'Mevcut VKN korunur');

select public.logo_firm_unlink(test.biz(), test.cust('M010'));
select test.eq((select logo_code from public.customers where id = test.cust('M010')), null::text, 'Bağlantı kaldırılır');

select test.login(test.u_satis());
select test.throws($$select public.logo_firms_preview(test.biz(), '[{"code":"1","unvan":"x"}]')$$, '%yetkiniz yok%', 'Yalnızca yönetici');
rollback;
