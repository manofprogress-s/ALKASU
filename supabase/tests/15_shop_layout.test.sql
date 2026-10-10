-- Mağaza düzeni (W-11): yalnızca yönetici gizler / sıralar / bölüm değiştirir; müşteri gizlenenleri görmez
begin;
select test.fixture();
update public.businesses set public_ordering = true where id = test.biz();
grant execute on all functions in schema test to authenticated, anon;

select test.login(test.u_admin());
select test.ok((select count(*) from public.shop_catalog_admin(test.biz())) >= 2, 'Yönetici mağaza ürünlerini görür');
select public.save_shop_layout(test.biz(), jsonb_build_array(
  jsonb_build_object('unit_id', test.unit('SU-005', 'Koli'), 'hidden', true),
  jsonb_build_object('unit_id', test.unit('DM-001', 'Damacana'), 'sort', 10, 'section', 'Öne çıkanlar')));
select test.ok((select hidden from public.shop_catalog_admin(test.biz()) where unit_id = test.unit('SU-005', 'Koli')), 'Gizlenen ürün yöneticide işaretli görünür');

select test.logout();
set local role anon;
select test.eq((select count(*) from public.public_catalog() where unit_id = test.unit('SU-005', 'Koli'))::int, 0, 'Müşteri gizlenen ürünü görmez');
select test.eq((select section from public.public_catalog() where unit_id = test.unit('DM-001', 'Damacana')), 'Öne çıkanlar', 'Bölüm değişikliği müşteriye yansır');
select test.eq((select sort from public.public_catalog() where unit_id = test.unit('DM-001', 'Damacana')), 10, 'Sıra müşteriye yansır');
reset role;

select test.login(test.u_admin());
select public.save_shop_layout(test.biz(), jsonb_build_array(jsonb_build_object('unit_id', test.unit('SU-005', 'Koli'), 'hidden', false)));
select test.eq((select section from public.shop_catalog_admin(test.biz()) where unit_id = test.unit('DM-001', 'Damacana')), 'Öne çıkanlar', 'Verilmeyen alanlar korunur');
select test.ok(not (select hidden from public.shop_catalog_admin(test.biz()) where unit_id = test.unit('SU-005', 'Koli')), 'Gizlenen ürün geri getirilir');
select public.save_shop_layout(test.biz(), jsonb_build_array(jsonb_build_object('unit_id', test.unit('DM-001', 'Damacana'), 'section', null, 'sort', null)));
select test.ok((select section is null and sort is null from public.shop_catalog_admin(test.biz()) where unit_id = test.unit('DM-001', 'Damacana')), 'Otomatik düzene dönülür');
select test.throws($$select public.save_shop_layout(test.biz(), jsonb_build_array(jsonb_build_object('unit_id', gen_random_uuid())))$$, '%bulunamadı%', 'Bilinmeyen ürün reddedilir');
select test.throws($$select public.save_shop_layout(test.biz_b(), jsonb_build_array(jsonb_build_object('unit_id', test.unit('SU-005', 'Koli'))))$$, '%yetkiniz yok%', 'Başka işletmenin düzeni değiştirilemez');

select test.login(test.u_satis());
select test.throws($$select public.save_shop_layout(test.biz(), '[]'::jsonb)$$, '%yetkiniz yok%', 'Satış personeli düzeni değiştiremez');
select test.throws($$select count(*) from public.shop_catalog_admin(test.biz())$$, '%yetkiniz yok%', 'Satış personeli yönetici kataloğunu açamaz');
select test.eq((select count(*) from public.shop_items)::int, 0, 'Satış personeli düzen kayıtlarını görmez');
rollback;
