-- Depozitosuz kap (F-40)
begin;
select test.fixture();
create function test.dsale(p_id uuid, p_qty int, p_ret int, p_free int) returns jsonb language sql as $$
  select public.complete_sale(test.biz(), jsonb_build_object('id', p_id, 'customer_id', test.cust('M001'),
    'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('DM-001'), 'unit_id', test.unit('DM-001', 'Damacana'), 'qty', p_qty, 'unit_price', 120)),
    'deposits', jsonb_build_array(jsonb_build_object('product_id', test.pid('DM-001'), 'empty_returned', p_ret, 'deposit_free', p_free)),
    'payments', jsonb_build_array(jsonb_build_object('method', 'veresiye', 'amount', p_qty * 120 + greatest(p_qty - p_ret - p_free, 0) * 250)))) $$;
create function test.sale_dep(p_id uuid) returns numeric language sql stable security definer as $$ select deposit_total from public.sales where id = p_id $$;
create function test.kap(p_cust uuid) returns int language sql stable security definer as $$
  select coalesce(sum(qty), 0)::int from public.container_ledger where customer_id = p_cust and product_id = test.pid('DM-001') $$;
create function test.kap_amt(p_cust uuid) returns numeric language sql stable security definer as $$
  select coalesce(sum(amount), 0) from public.container_ledger where customer_id = p_cust and product_id = test.pid('DM-001') $$;
create function test.mid(p_user uuid) returns uuid language sql stable security definer as $$ select id from public.memberships where user_id = p_user and business_id = test.biz() $$;
grant execute on all functions in schema test to authenticated;

update public.customers set unlimited_credit = true where code = 'M001' and business_id = test.biz();
select test.login(test.u_admin());
-- 12 dolu verildi, 2 boş alındı → 10 kap müşteride; 10'u depozitosuz
select test.dsale('cccccccc-0000-0000-0000-000000000001', 12, 2, 10);
select test.eq(test.sale_dep('cccccccc-0000-0000-0000-000000000001'), 0::numeric, 'Depozitosuz 10 kap: depozito 0');
select test.eq(test.kap(test.cust('M001')), 10, 'Kaplar müşteriye yazılır (stok takibi)');
select test.eq(test.kap_amt(test.cust('M001')), 0::numeric, 'Kap bakiyesinin depozito tutarı 0');
-- Kısmen: 5 kap kalıyor, 2'si depozitosuz → 3 × 250
select test.dsale('cccccccc-0000-0000-0000-000000000002', 5, 0, 2);
select test.eq(test.sale_dep('cccccccc-0000-0000-0000-000000000002'), 750::numeric, '3 kap depozitolu, 2 kap depozitosuz');
-- Sonraki teslimatta fazla boş geri alınır: depozitosuz kapların iadesi 0
select public.complete_sale(test.biz(), jsonb_build_object('id', 'cccccccc-0000-0000-0000-000000000003', 'customer_id', test.cust('M001'),
  'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('DM-001'), 'unit_id', test.unit('DM-001', 'Damacana'), 'qty', 2, 'unit_price', 120)),
  'deposits', jsonb_build_array(jsonb_build_object('product_id', test.pid('DM-001'), 'empty_returned', 12)),
  'payments', jsonb_build_array(jsonb_build_object('method', 'veresiye', 'amount', 240))));
select test.eq(test.kap(test.cust('M001')), 5, '10 fazla boş geri alındı');
select test.eq(test.sale_dep('cccccccc-0000-0000-0000-000000000003'), 0::numeric, 'Geri alınan 10 kap depozitosuz kaplardan düşer: iade 0');
select test.eq(test.kap_amt(test.cust('M001')), 750::numeric, 'Kalan 5 kabın ödenmiş depozitosu korunur');
-- Kalan 5 depozitolu kap geri gelince ödenen 750 iade edilir
select public.complete_sale(test.biz(), jsonb_build_object('id', 'cccccccc-0000-0000-0000-000000000004', 'customer_id', test.cust('M001'),
  'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('DM-001'), 'unit_id', test.unit('DM-001', 'Damacana'), 'qty', 1, 'unit_price', 120)),
  'deposits', jsonb_build_array(jsonb_build_object('product_id', test.pid('DM-001'), 'empty_returned', 6)),
  'payments', '[]'::jsonb));
select test.eq(test.sale_dep('cccccccc-0000-0000-0000-000000000004'), -750::numeric, 'Depozitolu kaplar iade edilir');
-- İptal: depozitosuz sayısı da geri döner
select public.cancel_sale('cccccccc-0000-0000-0000-000000000001', 'test');
select test.eq((select app_free from (select coalesce(sum(coalesce(free_qty,0)),0)::int as app_free from public.container_ledger where ref_id = 'cccccccc-0000-0000-0000-000000000001') x), 0, 'İptal depozitosuz kapları da geri alır');
-- Sınırlar
select test.throws($$select test.dsale(gen_random_uuid(), 3, 0, 4)$$, '%aşamaz%', 'Depozitosuz sayı kalan kaptan fazla olamaz');
select test.throws($$select test.dsale(gen_random_uuid(), 3, 3, 1)$$, '%aşamaz%', 'Değişimde depozitosuz kap olmaz');
select test.throws($$select test.dsale(gen_random_uuid(), 3, 0, -1)$$, '%aşamaz%', 'Negatif olamaz');
-- Yetki: satış personeli yalnızca özel fiyat yetkisiyle
select test.login(test.u_satis());
select test.throws($$select test.dsale(gen_random_uuid(), 3, 0, 3)$$, '%özel fiyat yetkisi%', 'Yetkisiz personel depozitosuz kap bırakamaz');
select test.lives($$select test.dsale(gen_random_uuid(), 1, 0, 0)$$, 'Depozitosuz olmayan normal satış');
select test.login(test.u_admin());
select public.set_member_price_perm(test.mid(test.u_satis()), true);
select test.login(test.u_satis());
select test.lives($$select test.dsale(gen_random_uuid(), 3, 0, 3)$$, 'Özel fiyat yetkili personel depozitosuz kap bırakır');
rollback;
