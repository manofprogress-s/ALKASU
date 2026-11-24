-- Ürün kartı düzenleme yetkisi (F-42, D-118)
begin;
select test.fixture();
create function test.mid(p_user uuid) returns uuid language sql stable security definer as $$ select id from public.memberships where user_id = p_user and business_id = test.biz() $$;
create function test.pname(p_code text) returns text language sql stable security definer as $$ select name from public.products where code = p_code and business_id = test.biz() $$;
create function test.prod_id(p_code text) returns uuid language sql stable security definer as $$ select id from public.products where code = p_code and business_id = test.biz() $$;
grant execute on all functions in schema test to authenticated;

select test.login(test.u_satis());
select test.throws($$select public.upsert_product(test.biz(), jsonb_build_object('id', test.prod_id('SU-005'), 'code', 'SU-005', 'name', 'Yeni ad'))$$,
  '%yetkiniz yok%', 'Yetkisiz personel ürün kartını değiştiremez');
select test.throws($$select public.set_member_product_perm(test.mid(test.u_satis()), true)$$, '%yetkiniz yok%', 'Yetkiyi yalnızca yönetici verir');
select test.login(test.u_admin());
select public.set_member_product_perm(test.mid(test.u_satis()), true);
select test.ok((select count(*) from audit.log where action = 'yetki_urun') = 1, 'Yetki işlem geçmişinde');
select test.login(test.u_satis());
select public.upsert_product(test.biz(), jsonb_build_object('id', test.prod_id('SU-005'), 'code', 'SU-005', 'name', 'Su 0,5 L Yeni', 'base_unit_name', 'Adet', 'base_price', 12, 'vat_rate', 1, 'units', '[]'::jsonb, 'barcodes', '[]'::jsonb));
select test.eq(test.pname('SU-005'), 'Su 0,5 L Yeni', 'Yetkili personel ürün adını değiştirir');
select public.set_product_active(test.prod_id('SU-005'), false);
select test.login(test.u_depo());
select test.throws($$select public.upsert_product(test.biz(), '{"code":"X","name":"X"}')$$, '%yetkiniz yok%', 'Depo personeli yapamaz');
select test.login(test.u_admin_b());
select test.throws($$select public.upsert_product(test.biz(), '{"code":"X","name":"X"}')$$, '%yetkiniz yok%', 'Başka işletmenin yöneticisi yapamaz');
rollback;
