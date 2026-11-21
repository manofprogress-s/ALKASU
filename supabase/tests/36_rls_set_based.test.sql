-- Yetki kontrolü sorgu başına (D-108): politikalarda satır başına has_role/is_admin/my_customer kalmamalı
begin;
select test.fixture();
select test.eq((select count(*)::int from pg_policies where schemaname in ('public', 'audit')
                 and (coalesce(qual, '') || coalesce(with_check, '')) ~ 'app\.(has_role|is_admin|my_customer)\('), 0,
               'Politikalarda satır başına yetki fonksiyonu yok');
-- Sevkiyat rolü satış yetkisini kapsar (role_covers): müşterileri ve cariyi görür, stok hareketini depo olarak görür
insert into auth.users(id, email) values ('00000000-0000-0000-0000-0000000000c1', 'sevkiyat@test');
insert into public.memberships(business_id, user_id, role, display_name) values (test.biz(), '00000000-0000-0000-0000-0000000000c1', 'sevkiyat', 'Sevkiyat');
select test.login('00000000-0000-0000-0000-0000000000c1');
select test.eq((select count(*)::int from public.customers), 3, 'Sevkiyat müşterileri görür');
select test.ok((select count(*) from public.stock_movements) > 0, 'Sevkiyat stok hareketlerini görür (depo)');
select test.eq((select count(*)::int from public.invoices), 0, 'Sevkiyat faturaları görmez (yalnızca yönetici)');
-- Başka işletmenin yöneticisi hiçbir şey görmez
select test.login(test.u_admin_b());
select test.eq((select count(*)::int from public.customers where business_id = test.biz()), 0, 'Diğer işletme müşterileri görmez');
select test.eq((select count(*)::int from public.customer_ledger where business_id = test.biz()), 0, 'Diğer işletme cariyi görmez');
-- Yetkisiz kullanıcı
select test.login(test.u_outsider());
select test.eq((select count(*)::int from public.customers), 0, 'Üyeliği olmayan kullanıcı müşteri görmez');
select test.eq((select count(*)::int from public.sales), 0, 'Üyeliği olmayan kullanıcı satış görmez');
-- Fatura sekme sayıları
select test.login(test.u_admin());
select test.eq((select coalesce(sum(n), 0)::int from public.invoice_status_counts(test.biz())), 0, 'Fatura yokken sayı 0');
select test.login(test.u_satis());
select test.throws($$select * from public.invoice_status_counts(test.biz())$$, '%yetkiniz yok%', 'Fatura sayılarını yalnızca yönetici görür');
rollback;
