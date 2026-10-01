-- Konum, tedarikçi kartı, sebil ve kap sayısı (D-047..D-050)
begin;
select test.fixture();

select test.login(test.u_depo());
select test.lives($$select public.upsert_supplier(test.biz(), '{"name":"Fuska","address":"Kocaeli","latitude":"40.7651","longitude":"29.9408","contact_name":"Ali"}'::jsonb)$$,
  'Depo personeli tedarikçi kartı açar (adres + konum)');
select test.eq((select latitude from public.suppliers where name = 'Fuska'), 40.765100::numeric, 'Konum 6 haneye yuvarlanarak saklanır');
select test.throws($$select public.upsert_supplier(test.biz(), '{"name":"X","latitude":"40.1"}'::jsonb)$$, '%birlikte%', 'Enlem ve boylam birlikte girilmeli');
select test.throws($$select public.upsert_supplier(test.biz(), '{"name":"Y","latitude":"140","longitude":"20"}'::jsonb)$$, '%Konum geçersiz%', 'Geçersiz konum reddedilir');
select test.throws($$select public.upsert_supplier(test.biz(), '{"name":"fuska"}'::jsonb)$$, '%zaten var%', 'Aynı adla ikinci tedarikçi açılamaz');
select test.throws($$select public.upsert_supplier(test.biz(), '{"name":" "}'::jsonb)$$, '%zorunlu%', 'Tedarikçi adı zorunlu');
select public.upsert_supplier(test.biz(), jsonb_build_object('id', (select id from public.suppliers where name = 'Fuska'), 'name', 'Fuska', 'latitude', '', 'longitude', ''));
select test.eq((select latitude from public.suppliers where name = 'Fuska'), null::numeric, 'Konum silinebilir');

select test.login(test.u_satis());
select test.throws($$select public.upsert_supplier(test.biz(), '{"name":"Z"}'::jsonb)$$, '%yetkiniz yok%', 'Satış personeli tedarikçi açamaz');
select public.upsert_customer(test.biz(), jsonb_build_object('id', test.cust('M001'), 'name', 'Ahmet Bakkal',
  'latitude', 40.7, 'longitude', 29.9, 'dispenser_count', 2, 'channel', 'kurumsal'));
select test.eq((select dispenser_count from public.customers where id = test.cust('M001')), 2, 'Müşteride sebil sayısı tutulur');
select test.eq((select longitude from public.customers where id = test.cust('M001')), 29.900000::numeric, 'Müşteri konumu tutulur');
select public.upsert_customer(test.biz(), jsonb_build_object('id', test.cust('M001'), 'name', 'Ahmet Bakkal'));
select test.eq((select latitude from public.customers where id = test.cust('M001')), 40.700000::numeric, 'Konum gönderilmezse korunur');
select test.throws($$select public.upsert_customer(test.biz(), jsonb_build_object('id', test.cust('M001'), 'name', 'A', 'dispenser_count', -1))$$,
  '%negatif%', 'Sebil sayısı negatif olamaz');
select test.throws($$select public.set_customer_containers(test.cust('M001'), test.pid('DM-001'), 10)$$, '%yetkiniz yok%',
  'Kap sayısını yalnızca yönetici düzeltir');

select test.login(test.u_admin());
select public.set_customer_containers(test.cust('M001'), test.pid('DM-001'), 10);
select test.eq((select qty from public.container_balances where customer_id = test.cust('M001')), 10, 'Müşteriye açılış kap sayısı girilir');
select public.set_customer_containers(test.cust('M001'), test.pid('DM-001'), 7, 0, 'sayım');
select test.eq((select qty from public.container_balances where customer_id = test.cust('M001')), 7, 'Kap sayısı düzeltilir (fark hareketi)');
select test.eq((select count(*) from public.container_ledger where customer_id = test.cust('M001'))::int, 2, 'Geçmiş silinmez, fark kaydı eklenir');
select test.eq((public.set_customer_containers(test.cust('M001'), test.pid('DM-001'), 7)->>'changed')::boolean, false, 'Aynı sayı tekrar girilirse kayıt oluşmaz');
select test.throws($$select public.set_customer_containers(test.cust('M001'), test.pid('SU-005'), 3)$$, '%depozitolu değil%', 'Depozitosuz ürüne kap sayısı girilemez');
select test.eq(test.stock('BK-001'), 0, 'Kap sayısı düzeltmesi depo stoğunu değiştirmez');

rollback;
