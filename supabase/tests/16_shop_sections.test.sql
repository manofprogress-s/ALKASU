-- Mağaza bölüm sırası (W-12): yalnızca yönetici, müşteri kataloğuna yansır
begin;
select test.fixture();
update public.businesses set public_ordering = true where id = test.biz();
grant execute on all functions in schema test to authenticated, anon;

select test.login(test.u_admin());
select test.eq(public.save_shop_sections(test.biz(), array['Örnek Marka çeşitleri', '__top__', '  ']), 2, 'Bölüm sırası kaydedilir (boş başlık atlanır)');
select test.logout();
set local role anon;
select test.eq((select section_rank from public.public_catalog() where unit_id = test.unit('SU-005', 'Koli')), 10, 'Ürünün bölüm sırası katalogda');
select test.eq((select top_rank from public.public_catalog() limit 1), 20, 'Çok satanların sırası katalogda');
reset role;

select test.login(test.u_admin());
select public.save_shop_layout(test.biz(), jsonb_build_array(jsonb_build_object('unit_id', test.unit('DM-001', 'Damacana'), 'section', 'Öne çıkanlar')));
select public.save_shop_sections(test.biz(), array['Öne çıkanlar', 'Örnek Marka çeşitleri']);
select test.eq((select section_rank from public.shop_catalog_admin(test.biz()) where unit_id = test.unit('DM-001', 'Damacana')), 10, 'Elle açılan bölümün sırası');
select test.ok((select top_rank is null from public.shop_catalog_admin(test.biz()) limit 1), 'Listede olmayan bölüm otomatik sıraya döner');
select test.ok((select count(*) from audit.log where action = 'magaza_bolum_sirasi') >= 2, 'Bölüm sırası işlem geçmişine yazılır');

select test.login(test.u_satis());
select test.throws($$select public.save_shop_sections(test.biz(), array['x'])$$, '%yetkiniz yok%', 'Satış personeli bölüm sırasını değiştiremez');
select test.eq((select count(*) from public.shop_sections)::int, 0, 'Satış personeli bölüm sırasını görmez');
rollback;
