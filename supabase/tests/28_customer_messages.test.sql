-- Müşteri mesajı kaydı (M-27)
begin;
select test.fixture();
grant execute on all functions in schema test to authenticated;
select test.login(test.u_satis());
select test.eq(public.log_customer_message(test.biz(), test.cust('M001'), 'tanitim', 'whatsapp')->>'ok', 'true', 'Mesaj açılışı kaydedilir');
select test.throws($$select public.log_customer_message(test.biz(), test.cust('M001'), 'x', 'sms')$$, '%Geçersiz%', 'Geçersiz taslak reddedilir');
select test.eq((select count(*) from public.customer_messages)::int, 1, 'Satış personeli kaydı görür');
select test.logout();
insert into public.privacy_events(business_id, customer_id, kind, notice_version, channel) values (test.biz(), test.cust('M003'), 'kampanya_ret', 'v1', 'personel');
select test.login(test.u_satis());
select test.throws($$select public.log_customer_message(test.biz(), test.cust('M003'), 'hatirlatma', 'sms')$$, '%istemediğini%', 'Kampanya iznini reddedene gönderilmez');
select test.throws($$update public.customer_messages set channel = 'sms'$$, '%', 'Kayıt değiştirilemez');
select test.login(test.u_depo());
select test.throws($$select public.log_customer_message(test.biz(), test.cust('M001'), 'tanitim', 'sms')$$, '%yetkiniz yok%', 'Depo mesaj gönderemez');
rollback;
