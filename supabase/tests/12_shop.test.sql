-- Mağaza (W-08..W-10): katalogda bölüm, fotoğraf, çok satanlar; fotoğrafı yalnızca yönetici bağlar
begin;
select test.fixture();
update public.businesses set public_ordering = true where id = test.biz();
create function test.img(p_code text) returns text language sql stable security definer as $$ select image_path from public.products where code = p_code $$;
grant execute on all functions in schema test to authenticated, anon;

select test.login(test.u_satis());
select test.sell('SU-005', 'Koli', 3);
select test.sell('SU-005', 'Koli', 2);

select test.logout();
set local role anon;
select test.eq((select brand_name from public.public_catalog() where unit_id = test.unit('SU-005', 'Koli')), 'Örnek Marka', 'Katalog marka adını verir');
select test.eq((select category_name from public.public_catalog() where unit_id = test.unit('SU-005', 'Koli')), 'Su', 'Katalog kategori adını verir');
select test.eq((select popularity from public.public_catalog() where unit_id = test.unit('SU-005', 'Koli')), 5, 'Son 60 günün satış adedi (çok satanlar)');
select test.eq((select popularity from public.public_catalog() where unit_id = test.unit('DM-001', 'Damacana')), 0, 'Satılmayan ürünün satış adedi 0');
select test.eq((select product_code from public.public_catalog() where unit_id = test.unit('DM-001', 'Damacana')), 'DM-001', 'Katalog ürün kodunu verir');
reset role;

-- Genel marka mağazada bölüm açmaz
update public.brands set show_in_shop = false where name = 'Örnek Marka';
set local role anon;
select test.ok((select brand_name from public.public_catalog() where unit_id = test.unit('SU-005', 'Koli')) is null, 'Mağazada gösterilmeyen marka boş döner');
reset role;

-- Fotoğraf
select test.login(test.u_admin());
select public.set_product_image(test.pid('SU-005'), test.biz()::text || '/su-005-1.webp');
select test.eq(test.img('SU-005'), test.biz()::text || '/su-005-1.webp', 'Yönetici ürün fotoğrafını bağlar');
select test.throws($$select public.set_product_image(test.pid('SU-005'), test.biz_b()::text || '/x.webp')$$, '%Geçersiz dosya%', 'Başka işletmenin klasörü reddedilir');
select test.throws($$select public.set_product_image(test.pid('SU-005'), test.biz()::text || '/../x.webp')$$, '%Geçersiz dosya%', 'Yol dışına çıkan ad reddedilir');
select test.ok((select count(*) from audit.log where action = 'urun_gorseli') >= 1, 'Fotoğraf değişikliği işlem geçmişine yazılır');
set local role anon;
select test.eq((select image_path from public.public_catalog() where unit_id = test.unit('SU-005', 'Koli')), test.biz()::text || '/su-005-1.webp', 'Katalog fotoğraf yolunu verir');
reset role;
select test.login(test.u_admin());
select public.set_product_image(test.pid('SU-005'), null);
select test.ok(test.img('SU-005') is null, 'Fotoğraf kaldırılır');
select test.login(test.u_satis());
select test.throws($$select public.set_product_image(test.pid('SU-005'), test.biz()::text || '/a.webp')$$, '%yetkiniz yok%', 'Satış personeli fotoğraf bağlayamaz');
rollback;
