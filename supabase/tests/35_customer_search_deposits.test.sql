-- Bayi araması, satış ekranı araması, müşteriye özel depozito, borç özeti (M-29, F-37)
begin;
select test.fixture();
create function test.s(q text) returns text language sql as $$
  select string_agg(code, ' | ') from (select code from public.search_customers(test.biz(), q, 10)) x $$;
create function test.hint(q text, p_code text) returns text language sql as $$
  select dealer_hint->>'code' from public.search_customers(test.biz(), q, 30) where code = p_code $$;
create function test.dm(p_qty int, p_price numeric) returns jsonb language sql stable security definer as $$
  select jsonb_build_object('product_id', test.pid('DM-001'), 'unit_id', test.unit('DM-001', 'Damacana'), 'qty', p_qty, 'unit_price', p_price) $$;
grant execute on all functions in schema test to authenticated;

select test.login(test.u_admin());
select public.upsert_customer(test.biz(), '{"code":"B001","name":"Sağlam Ticaret (Gürpınar Ev Bayisi)","channel":"bayi","price_list":"bayi","unlimited_credit":true}'::jsonb);
select public.upsert_customer(test.biz(), '{"code":"B002","name":"Yıldız Ticaret (Fuska Ev Bayisi)","channel":"bayi","price_list":"bayi","phone":"0532 111 22 33"}'::jsonb);
select public.upsert_customer(test.biz(), '{"code":"A1027","name":"İBRAHİM SAĞLAM"}'::jsonb);
select public.upsert_customer(test.biz(), '{"code":"A1164","name":"FUSKA"}'::jsonb);
select public.upsert_customer(test.biz(), '{"code":"A1242","name":"HÜSEYİN YILDIZ"}'::jsonb);
select public.upsert_customer(test.biz(), '{"code":"A588","name":"YILDIZ EFE"}'::jsonb);
select public.upsert_customer(test.biz(), '{"code":"A900","name":"Mehmet Kaya","phone":"+90 532 111 22 33"}'::jsonb);
select test.logout();
-- Bayi kullanıcıları (D-084): İbrahim → Sağlam Ticaret, Hüseyin Yıldız → Yıldız Ticaret
insert into auth.users(id, email) values ('00000000-0000-0000-0000-0000000000b1', 'ibrahim@test'), ('00000000-0000-0000-0000-0000000000b2', 'huseyin@test');
insert into public.memberships(business_id, user_id, role, display_name, customer_id) values
  (test.biz(), '00000000-0000-0000-0000-0000000000b1', 'bayi', 'İbrahim', test.cust('B001')),
  (test.biz(), '00000000-0000-0000-0000-0000000000b2', 'bayi', 'Hüseyin Yıldız', test.cust('B002'));
insert into public.customers(business_id, code, name) select test.biz(), 'X' || g, 'AAA Dolgu ' || lpad(g::text, 4, '0') from generate_series(1, 1050) g;

select test.login(test.u_satis());
-- Bayi kartı üstte
select test.eq(test.s('sağlam'), 'B001 | A1027', 'Bayi kartı ev kartının üstünde');
select test.eq(test.s('fuska'), 'B002 | A1164', 'Tam eşleşen ev kartı olsa da bayi kartı üstte');
select test.eq(test.s('hüseyin yıldız'), 'B002 | A1242', 'Bayi kartı bayi kullanıcısının adıyla da bulunur');
select test.eq(test.s('ibrahim sağlam'), 'B001 | A1027', 'Kullanıcı adı + bayi adı birlikte');
select test.eq((select channel from public.search_customers(test.biz(), 'sağlam', 10) limit 1), 'bayi', 'Kanal döner');
-- Benzer ev kartına bayi ipucu
select test.eq(test.hint('sağlam', 'A1027'), 'B001', 'İBRAHİM SAĞLAM → Sağlam Ticaret olabilir');
select test.eq(test.hint('fuska', 'A1164'), 'B002', 'FUSKA → Yıldız Ticaret (Fuska Ev Bayisi) olabilir');
select test.eq(test.hint('hüseyin', 'A1242'), 'B002', 'HÜSEYİN YILDIZ → bayi kullanıcısı');
select test.eq(test.hint('mehmet', 'A900'), 'B002', 'Aynı telefon → bayi ipucu');
select test.eq(test.hint('yıldız efe', 'A588'), null::text, 'Yalnızca bir kelimesi geçen kartta ipucu yok');
select test.eq(test.hint('sağlam', 'B001'), null::text, 'Bayi kartının kendisinde ipucu yok');
-- 1.000 satır sınırının ötesi ve sınır
select test.eq(test.s('yıldız ticaret'), 'B002', 'Liste sınırının ötesindeki bayi bulunur');
select test.eq((select max(total)::int from public.search_customers(test.biz(), 'dolgu', 10)), 1050, 'Toplam eşleşme sayısı');
select test.eq((select count(*)::int from public.search_customers(test.biz(), 'dolgu', 99)), 30, 'En fazla 30 sonuç');

-- Bakiye, kap, özel fiyat ve özel depozito aramayla gelir; özel depozito satışta uygulanır
select test.login(test.u_admin());
select public.set_customer_price(test.cust('B001'), test.unit('DM-001', 'Damacana'), 78);
select public.set_customer_deposit(test.cust('B001'), test.pid('DM-001'), 100);
select test.throws($$select public.set_customer_deposit(test.cust('B001'), test.pid('SU-005'), 10)$$, '%Depozitolu ürün bulunamadı%', 'Depozitosuz ürüne özel depozito girilmez');
select test.throws($$select public.set_customer_deposit(test.cust('B001'), test.pid('DM-001'), 0)$$, '%sıfırdan büyük%', 'Sıfır depozito girilmez');
select test.login(test.u_satis());
select test.throws($$select public.set_customer_deposit(test.cust('B001'), test.pid('DM-001'), 50)$$, '%yetkiniz yok%', 'Özel depozitoyu yalnızca yönetici girer');
select public.complete_sale(test.biz(), jsonb_build_object('id', 'eeeeeeee-0000-0000-0000-000000000001', 'customer_id', test.cust('B001'),
  'items', jsonb_build_array(test.dm(10, 78)), 'deposits', jsonb_build_array(jsonb_build_object('product_id', test.pid('DM-001'), 'empty_returned', 0)),
  'payments', jsonb_build_array(jsonb_build_object('method', 'veresiye', 'amount', 10 * 78 + 10 * 100))));
select test.eq((select deposit_total from public.sales where id = 'eeeeeeee-0000-0000-0000-000000000001'), 1000.00::numeric, 'Bayiye özel depozito (100) uygulanır');
select public.complete_sale(test.biz(), jsonb_build_object('id', 'eeeeeeee-0000-0000-0000-000000000002', 'customer_id', test.cust('M001'),
  'items', jsonb_build_array(test.dm(1, 120)), 'deposits', jsonb_build_array(jsonb_build_object('product_id', test.pid('DM-001'), 'empty_returned', 0)),
  'payments', jsonb_build_array(jsonb_build_object('method', 'veresiye', 'amount', 120 + 250))));
select test.eq((select deposit_total from public.sales where id = 'eeeeeeee-0000-0000-0000-000000000002'), 250.00::numeric, 'Diğer müşteride ürün kartındaki depozito');
select test.eq((select balance from public.search_customers(test.biz(), 'B001', 10) where code = 'B001'), 1780.00::numeric, 'Bakiye aramayla gelir');
select test.eq((select (containers->0->>'qty')::int from public.search_customers(test.biz(), 'B001', 10) where code = 'B001'), 10, 'Kap bakiyesi aramayla gelir');
select test.eq((select (special_prices->>test.unit('DM-001', 'Damacana')::text)::numeric from public.search_customers(test.biz(), 'B001', 10) where code = 'B001'), 78::numeric, 'Özel fiyat aramayla gelir');
select test.eq((select (deposits->>test.pid('DM-001')::text)::numeric from public.search_customers(test.biz(), 'B001', 10) where code = 'B001'), 100::numeric, 'Özel depozito aramayla gelir');
select test.logout();
select test.eq(app.deposit_for(test.cust('B001'), test.pid('DM-001'), 'ev'), 100::numeric, 'Özel depozito eve teslimden de önce gelir');
select test.login(test.u_admin());
select public.set_customer_deposit(test.cust('B001'), test.pid('DM-001'), null);
select test.logout();
select test.eq(app.deposit_for(test.cust('B001'), test.pid('DM-001'), null), 250::numeric, 'Kaldırılınca ürün kartındaki depozito');
select test.eq(app.deposit_for(test.cust('B001'), test.pid('SU-005'), null), null::numeric, 'Depozitosuz ürün');

-- Borç özeti ve borçlu sayfası
select test.login(test.u_satis());
select test.eq((select debtors from public.customer_debt_summary(test.biz())), 2, 'Borçlu sayısı');
select test.eq((select total from public.customer_debt_summary(test.biz())), 2150.00::numeric, 'Toplam alacak');
select test.eq((select string_agg(cu.code, ',' order by cu.name) from public.debtor_page(test.biz(), null, null, 0, 100) d join public.customers cu on cu.id = d.id), 'M001,B001', 'Borçlu sayfası');
select test.eq((select count(*)::int from public.debtor_page(test.biz(), null, 'bayi', 0, 100)), 1, 'Kanala göre borçlu');
select test.eq((select max(total)::int from public.debtor_page(test.biz(), null, null, 0, 1)), 2, 'Toplam borçlu sayısı sayfadan bağımsız');

select test.login(test.u_depo());
select test.throws($$select * from public.search_customers(test.biz(), 'ali', 10)$$, '%yetkiniz yok%', 'Depo personeli müşteri arayamaz');
select test.throws($$select * from public.customer_debt_summary(test.biz())$$, '%yetkiniz yok%', 'Depo personeli borç özetini göremez');
rollback;
