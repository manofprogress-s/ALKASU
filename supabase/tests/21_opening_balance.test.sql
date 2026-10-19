-- Eski borç açılışı ve yöneticinin açılış düzeltmesi (M-22)
begin;
select test.fixture();
grant execute on all functions in schema test to authenticated;
update public.customers set legacy_debt = 6120 where id = test.cust('M001');
update public.customers set legacy_debt = -250 where id = test.cust('M002');

select test.eq((app.post_legacy_openings(test.biz(), null))->>'count', '2', 'İki karta açılış yazıldı');
select test.eq(test.balance('M001'), 6120.00, 'Borç cariye geçti');
select test.eq(test.balance('M002'), -250.00, 'Alacak (eksi) da işlenir');
select test.eq((app.post_legacy_openings(test.biz(), null))->>'count', '0', 'Tekrar çalışınca yeni kayıt yok');

select test.login(test.u_admin());
select test.eq((public.set_opening_balance(test.biz(), test.cust('M001'), 5000))->>'previous', '6120.00', 'Düzeltme öncesi');
select test.eq(test.balance('M001'), 5000.00, 'Açılış 5000 oldu');
select test.eq(public.opening_balance(test.cust('M001')), 5000.00, 'Açılış toplamı');
select public.set_opening_balance(test.biz(), test.cust('M001'), 0);
select test.eq(test.balance('M001'), 0.00, 'Sıfırlandı');
select test.eq((select count(*) from public.customer_ledger where customer_id = test.cust('M001'))::int, 3, 'Kayıtlar silinmez; düzeltmeler yeni satır');
select test.eq((select count(*) from audit.log where action = 'acilis_duzeltme')::int, 2, 'Düzeltmeler işlem geçmişinde');

select test.login(test.u_satis());
select test.throws($$select public.set_opening_balance(test.biz(), test.cust('M001'), 10)$$, '%yetkiniz yok%', 'Satış personeli açılış değiştiremez');
select test.throws($$select public.opening_balance(test.cust('M001'))$$, '%yetkiniz yok%', 'Satış personeli açılışı göremez');
rollback;
