-- Bayi yalnızca kendi bilgisini görür (G-19): merkezin satış özeti, raporlar, diğer bayi ve müşteri listesi kapalı
begin;
select test.fixture();
create function test.u_b1() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000051'::uuid $$;
create function test.u_b2() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000052'::uuid $$;
grant execute on all functions in schema test to authenticated;
insert into auth.users(id, email) values (test.u_b1(), 'ibrahim@t'), (test.u_b2(), 'huseyin@t');

select test.login(test.u_admin());
select public.upsert_customer(test.biz(), '{"code":"B001","name":"Sağlam Ticaret","channel":"bayi","price_list":"bayi"}'::jsonb);
select public.upsert_customer(test.biz(), '{"code":"B002","name":"Yıldız Ticaret","channel":"bayi","price_list":"bayi"}'::jsonb);
select public.add_member(test.biz(), test.u_b1(), 'bayi', 'İbrahim', test.cust('B001'));
select public.add_member(test.biz(), test.u_b2(), 'bayi', 'Hüseyin Y', test.cust('B002'));
select test.login(test.u_satis());
select test.sell('SU-005', 'Koli', 2);

select test.login(test.u_b1());
select test.ok((public.dashboard(test.biz())->>'net_revenue') is null, 'Bayi merkezin günlük satışını görmez');
select test.ok((public.dashboard(test.biz())->>'balance') is not null, 'Bayi kendi cari bakiyesini görür');
select test.throws($$select * from public.report_daily_sales(test.biz(), current_date, current_date)$$, '%yetkiniz yok%', 'Bayi satış raporunu göremez');
select test.throws($$select * from public.report_receivables(test.biz())$$, '%yetkiniz yok%', 'Bayi veresiye raporunu göremez');
select test.eq((select count(*) from public.sales)::int, 0, 'Bayi merkezin satışlarını görmez');
select test.eq((select count(*) from public.customers where id <> test.cust('B001'))::int, 0, 'İbrahim diğer bayiyi ve merkezin müşterilerini görmez');
select test.login(test.u_b2());
select test.eq((select count(*) from public.customers where id <> test.cust('B002'))::int, 0, 'Hüseyin Yıldız yalnızca kendi bayisini görür');
select test.eq((select count(*) from public.memberships where user_id <> test.u_b2())::int, 0, 'Bayi diğer kullanıcıları görmez');
rollback;
