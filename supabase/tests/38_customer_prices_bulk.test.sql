-- Özel fiyatları toplu kaydetme (F-38)
begin;
select test.fixture();
create function test.cp(p_unit uuid) returns numeric language sql stable security definer as $$
  select price from public.customer_prices where customer_id = test.cust('M001') and unit_id = p_unit $$;
create function test.cp_count() returns int language sql stable security definer as $$
  select count(*)::int from public.customer_prices where customer_id = test.cust('M001') $$;
create function test.mid(p_user uuid) returns uuid language sql stable security definer as $$ select id from public.memberships where user_id = p_user and business_id = test.biz() $$;
grant execute on all functions in schema test to authenticated;

select test.login(test.u_admin());
select test.eq(public.set_customer_prices(test.cust('M001'), jsonb_build_array(
  jsonb_build_object('unit_id', test.unit('DM-001', 'Damacana'), 'price', 78),
  jsonb_build_object('unit_id', test.unit('SU-005', 'Koli'), 'price', 130.456))), 2, 'İki özel fiyat kaydedildi');
select test.eq(test.cp(test.unit('DM-001', 'Damacana')), 78.00::numeric, 'Damacana 78');
select test.eq(test.cp(test.unit('SU-005', 'Koli')), 130.46::numeric, 'Kuruşa yuvarlanır');
select test.eq(public.set_customer_prices(test.cust('M001'), jsonb_build_array(
  jsonb_build_object('unit_id', test.unit('DM-001', 'Damacana'), 'price', 78),
  jsonb_build_object('unit_id', test.unit('SU-005', 'Koli'), 'price', null))), 1, 'Değişmeyen sayılmaz, boş fiyat kaldırır');
select test.eq(test.cp_count(), 1, 'Kaldırılan fiyat silindi');
-- Hepsi ya da hiçbiri
select test.throws($$select public.set_customer_prices(test.cust('M001'), jsonb_build_array(
  jsonb_build_object('unit_id', test.unit('SU-005', 'Koli'), 'price', 120),
  jsonb_build_object('unit_id', test.unit('DM-001', 'Damacana'), 'price', -1)))$$, '%negatif%', 'Hatalı satır varsa hiçbiri kaydedilmez');
select test.eq(test.cp(test.unit('SU-005', 'Koli')), null::numeric, 'Önceki satır da kaydedilmedi');
select test.throws($$select public.set_customer_prices(test.cust('M001'), jsonb_build_array(jsonb_build_object('unit_id', gen_random_uuid(), 'price', 1)))$$, '%bulunamadı%', 'Bilinmeyen birim');
select test.ok((select count(*) from audit.log where action = 'ozel_fiyat' and record_id = test.cust('M001')::text) >= 3, 'Her değişiklik işlem geçmişinde');
select test.login(test.u_satis());
select test.throws($$select public.set_customer_prices(test.cust('M001'), '[]'::jsonb)$$, '%özel fiyat yetkisi%', 'Yetkisiz satış personeli giremez');
select test.throws($$select public.set_customer_price(test.cust('M001'), test.unit('DM-001', 'Damacana'), 70)$$, '%özel fiyat yetkisi%', 'Tek fiyat da aynı yetkiyle');
select test.throws($$select public.set_member_price_perm(test.mid(test.u_satis()), true)$$, '%yetkiniz yok%', 'Yetkiyi yalnızca yönetici verir');
select test.login(test.u_admin());
select public.set_member_price_perm(test.mid(test.u_satis()), true);
select test.login(test.u_satis());
select test.eq(public.set_customer_prices(test.cust('M001'), jsonb_build_array(jsonb_build_object('unit_id', test.unit('DM-001', 'Damacana'), 'price', 75))), 1, 'Yetki verilen personel özel fiyat girer');
select public.set_customer_price(test.cust('M001'), test.unit('SU-005', 'Koli'), 125);
select test.eq(test.cp(test.unit('SU-005', 'Koli')), 125.00::numeric, 'Tek fiyat kaydı');
select test.login(test.u_depo());
select test.throws($$select public.set_customer_prices(test.cust('M001'), '[]'::jsonb)$$, '%yetkiniz yok%', 'Depo personeli giremez');
rollback;
