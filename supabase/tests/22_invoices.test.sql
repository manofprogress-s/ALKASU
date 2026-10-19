-- Fatura arayüzü (Logo bağlantısız): fatura bilgileri, önizleme, taslak, mükerrer engeli (F-20…F-27)
begin;
select test.fixture();
grant execute on all functions in schema test to authenticated;

select test.eq(app.tax_id_kind('1234567890'), 'vkn', 'Geçerli VKN');
select test.eq(app.tax_id_kind('1234567891'), null::text, 'Doğrulama hanesi tutmayan VKN');
select test.eq(app.tax_id_kind('10000000146'), 'tckn', 'Geçerli TCKN');
select test.eq(app.tax_id_kind('10000000147'), null::text, 'Geçersiz TCKN');
select test.eq(app.tax_id_kind('01234567890'), null::text, 'TCKN 0 ile başlayamaz');

update public.products set vat_rate = 20 where id = test.pid('SU-005');
update public.customers set channel = 'kurumsal' where id = test.cust('M002');
select test.login(test.u_admin());
-- %20 KDV'li bir ürünü veresiye müşteriye sat
create temp table sale on commit drop as select (test.sell('SU-005', 'Koli', 2, jsonb_build_object('customer_id', test.cust('M002'))))->>'id' as id;
select test.ok((select id from sale) is not null, 'Satış oluştu');

-- Önizleme: KDV ayrımı ve eksik bilgi uyarıları
select test.eq((select (public.invoice_preview((select id::uuid from sale))->'lines'->0->>'vat_rate')), '20', 'Satır KDV oranı');
select test.eq((select ((x->'totals'->>'net')::numeric + (x->'totals'->>'vat')::numeric) = (x->'totals'->>'gross')::numeric
                  from (select public.invoice_preview((select id::uuid from sale)) x) z), true, 'KDV hariç + KDV = KDV dahil');
select test.ok((select exists (select 1 from jsonb_array_elements(public.invoice_preview((select id::uuid from sale))->'issues') i where i->>'field' = 'tax_no')),
               'VKN eksikliği uyarısı');

-- Fatura bilgisi: geçersiz VKN reddedilir, geçerli kaydedilir
select test.throws($$select public.set_customer_billing(test.biz(), test.cust('M002'), '{"tax_no":"1234567891"}')$$, '%geçersiz%', 'Geçersiz VKN reddedilir');
select test.throws($$select public.set_customer_billing(test.biz(), test.cust('M002'), '{"email":"abc"}')$$, '%E-posta%', 'Geçersiz e-posta reddedilir');

-- Taslak + mükerrer engeli
create temp table inv on commit drop as select public.create_invoice_draft(test.biz(), (select id::uuid from sale), 'deneme') as id;
select test.throws($$select public.create_invoice_draft(test.biz(), (select id::uuid from sale))$$, '%zaten var%', 'Aynı satışa ikinci fatura açılamaz');
select test.throws($$insert into public.invoices(business_id, sale_id, no, customer, lines, totals) select test.biz(), id::uuid, 999, '{}', '[]', '{}' from sale$$,
                   '%', 'Veritabanı da mükerrer kaydı engeller');
select test.throws($$select public.invoice_action(test.biz(), (select id from inv), 'hazirla')$$, '%Eksik bilgi%', 'Hata varken gönderime hazırlanamaz');

select public.set_customer_billing(test.biz(), test.cust('M002'),
  '{"legal_title":"Limitsiz Firma Ltd. Şti.","tax_no":"1234567890","tax_office":"Kocaeli","city":"Kocaeli","district":"Kartepe","address":"Köseköy","email":"muhasebe@ornek.com"}');
select test.eq(public.invoice_action(test.biz(), (select id from inv), 'hazirla'), 'hazir', 'Bilgiler tamamlanınca gönderime hazır');
select test.eq((select customer->>'tax_no' from public.invoices where id = (select id from inv)), '1234567890', 'Hazırlanırken alıcı bilgisi güncellendi');
select test.eq(public.invoice_action(test.biz(), (select id from inv), 'taslaga'), 'taslak', 'Taslağa geri alınır');
select test.throws($$select public.invoice_action(test.biz(), (select id from inv), 'iptal')$$, '%neden%', 'İptal nedeni zorunlu');
select test.eq(public.invoice_action(test.biz(), (select id from inv), 'iptal', 'yanlış satış'), 'iptal', 'Taslak iptal edilir');
select test.ok(public.create_invoice_draft(test.biz(), (select id::uuid from sale)) is not null, 'İptalden sonra yeni taslak açılabilir');
select test.eq((select count(*) from public.invoice_events where invoice_id = (select id from inv))::int, 4, 'Olay geçmişi tutulur');
select test.throws($$update public.invoice_events set event = 'x'$$, '%', 'Olay geçmişi değiştirilemez');
select test.throws($$select public.invoice_action(test.biz(), (select id from inv), 'gonderildi')$$, '%Geçersiz%', 'Kullanıcı gönderildi durumuna geçiremez');
select test.eq((select count(*) from public.uninvoiced_sales(test.biz())), 0::bigint, 'Faturası olan satış faturalanmamışlar listesinde yok');

select test.login(test.u_satis());
select test.throws($$select public.invoice_preview((select id::uuid from sale))$$, '%yetkiniz yok%', 'Satış personeli fatura önizleyemez');
select test.eq((select count(*) from public.invoices)::int, 0, 'Satış personeli fatura kayıtlarını görmez');
select test.ok(public.set_customer_billing(test.biz(), test.cust('M001'), '{"tax_no":"10000000146"}')->>'tax_kind' = 'tckn', 'Satış personeli fatura bilgisi girebilir');
rollback;
