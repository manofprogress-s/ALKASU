-- Ürün aktif/pasif yetkisi (F-41, D-117)
begin;
select test.fixture();
create function test.prod_id(p_code text) returns uuid language sql stable security definer as $$ select id from public.products where code = p_code and business_id = test.biz() $$;
create function test.pact(p_code text) returns boolean language sql stable security definer as $$ select active from public.products where code = p_code and business_id = test.biz() $$;
create function test.mid(p_user uuid) returns uuid language sql stable security definer as $$ select id from public.memberships where user_id = p_user and business_id = test.biz() $$;
grant execute on all functions in schema test to authenticated;

select test.login(test.u_satis());
select test.throws($$select public.set_product_active(test.prod_id('SU-005'), false)$$, '%özel fiyat yetkisi%', 'Yetkisiz personel ürünü pasife alamaz');
select test.login(test.u_admin());
select public.set_member_price_perm(test.mid(test.u_satis()), true);
select test.login(test.u_satis());
select public.set_product_active(test.prod_id('SU-005'), false);
select test.eq(test.pact('SU-005'), false, 'Özel fiyat yetkilisi pasife alır');
select public.set_product_active(test.prod_id('SU-005'), true);
select test.eq(test.pact('SU-005'), true, 'Geri aktif yapar');
select test.login(test.u_admin());
select test.ok((select count(*) from audit.log where action = 'urun_aktiflik' and record_id = test.prod_id('SU-005')::text) = 2, 'İşlem geçmişinde');
select test.login(test.u_depo());
select test.throws($$select public.set_product_active(test.prod_id('SU-005'), false)$$, '%yetki%', 'Depo personeli yapamaz');
select test.login(test.u_admin_b());
select test.throws($$select public.set_product_active(test.prod_id('SU-005'), false)$$, '%yetki%', 'Başka işletmenin yöneticisi yapamaz');
rollback;
