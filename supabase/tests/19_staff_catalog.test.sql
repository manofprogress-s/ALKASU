-- Satış / sipariş ekranı mağaza düzeni (W-13): personel düzeni okur, gizli ürünü de görür, dışarıdaki göremez
begin;
select test.fixture();
grant execute on all functions in schema test to authenticated, anon;

select test.login(test.u_admin());
select public.save_shop_layout(test.biz(), jsonb_build_array(
  jsonb_build_object('unit_id', test.unit('DM-001', 'Damacana'), 'section', 'Öne çıkanlar', 'sort', 10),
  jsonb_build_object('unit_id', test.unit('SU-005', 'Koli'), 'hidden', true)));
select public.save_shop_sections(test.biz(), array['Öne çıkanlar', '__top__']);

select test.login(test.u_satis());
select test.eq((select section from public.staff_catalog_layout(test.biz()) where unit_id = test.unit('DM-001', 'Damacana')), 'Öne çıkanlar', 'Satış personeli ürünün bölümünü görür');
select test.eq((select sort from public.staff_catalog_layout(test.biz()) where unit_id = test.unit('DM-001', 'Damacana')), 10, 'Bölüm içi sıra');
select test.eq((select section_rank from public.staff_catalog_layout(test.biz()) where unit_id = test.unit('DM-001', 'Damacana')), 10, 'Bölüm sırası');
select test.eq((select top_rank from public.staff_catalog_layout(test.biz()) limit 1), 20, 'Çok satanların sırası');
select test.ok(exists(select 1 from public.staff_catalog_layout(test.biz()) where unit_id = test.unit('SU-005', 'Koli')), 'Müşteriden gizlenen ürün personelde görünür');

select test.login(test.u_izleyici());
select test.ok((select count(*) from public.staff_catalog_layout(test.biz())) > 0, 'İzleyici de okuyabilir');

select test.login(test.u_outsider());
select test.throws($$select * from public.staff_catalog_layout(test.biz())$$, '%yetkiniz yok%', 'İşletme dışından okunamaz');
select test.logout();
select test.throws($$select * from public.staff_catalog_layout(test.biz())$$, '%Oturum%', 'Oturumsuz okunamaz');
rollback;
