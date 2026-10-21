-- Sayım onaylayanlar ayarı (T-04/6, D-095)
begin;
select test.fixture();
create function test.u_y2() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000034'::uuid $$;
grant execute on all functions in schema test to authenticated;
insert into auth.users(id, email) values (test.u_y2(), 'y2@t');
select test.login(test.u_admin());
select public.add_member(test.biz(), test.u_y2(), 'yonetici', 'Ayhan');
select test.logout();
select test.eq(app.count_approvals_required(test.biz()), 2, 'Varsayılan: iki yönetici onayı');
select test.login(test.u_admin());
select test.throws($$select public.set_count_approvers(test.biz(), array[test.u_depo()])$$, '%aktif yöneticiler%', 'Yönetici olmayan onaylayıcı olamaz');
select test.eq(public.set_count_approvers(test.biz(), array[test.u_admin()])->>'required', '1', 'Yalnızca bir onaylayıcı: tek onay yeter');

select public.start_stock_count(test.biz(), jsonb_build_object('id', 'ffffffff-0000-0000-0000-000000000001', 'product_ids', jsonb_build_array(test.pid('SU-005'))));
select public.save_stock_count_lines('ffffffff-0000-0000-0000-000000000001', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'counted_qty', 100)));
select public.submit_stock_count('ffffffff-0000-0000-0000-000000000001');
select test.eq(jsonb_array_length(public.stock_count_preview('ffffffff-0000-0000-0000-000000000001')->'approvers'), 1, 'Onay listesinde yalnızca belirlenen kişi');
select test.login(test.u_y2());
select test.throws($$select public.approve_stock_count('ffffffff-0000-0000-0000-000000000001')$$, '%yetkili değilsiniz%', 'Listede olmayan yönetici onaylayamaz');
select test.login(test.u_admin());
select test.eq(public.approve_stock_count('ffffffff-0000-0000-0000-000000000001')->>'applied', 'true', 'Tek yetkili onayıyla stoğa işlenir');
select test.eq(test.stock('SU-005'), 100, 'Stok sayılan miktar');

select test.eq(public.set_count_approvers(test.biz(), array[test.u_admin(), test.u_y2()])->>'required', '2', 'İkinci kişi eklenince iki onay');
select test.eq(public.set_count_approvers(test.biz(), '{}')->>'required', '2', 'Boş liste: tüm yöneticiler (en fazla 2)');
rollback;
