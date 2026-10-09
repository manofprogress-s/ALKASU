-- KVKK (K-01..K-07): aydınlatma kaydı, isteğe bağlı kampanya izni, değiştirilemez kayıt, yetki
begin;
select test.fixture();

create function test.u_bayi()  returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000031'::uuid $$;
create function test.u_bayi2() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000032'::uuid $$;
create function test.u_mus()   returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000033'::uuid $$;
create function test.u_mus2()  returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000034'::uuid $$;
create function test.cust_of(p_user uuid) returns public.customers language sql stable security definer as $$ select * from public.customers where user_id = p_user $$;
create function test.cust_named(p_name text) returns uuid language sql stable security definer as $$ select id from public.customers where name = p_name $$;
create function test.events(p_customer uuid) returns text language sql stable security definer as $$
  select coalesce(string_agg(kind || ':' || channel || ':' || notice_version, ',' order by id), '') from public.privacy_events where customer_id = p_customer
$$;
create function test.service() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
  perform set_config('role', 'service_role', true);
end $$;
grant usage on schema test to anon, service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

insert into auth.users(id, email) values (test.u_bayi(), 'kb1@test'), (test.u_bayi2(), 'kb2@test'),
  (test.u_mus(), '5321110001@musteri.test'), (test.u_mus2(), '5321110002@musteri.test');
update public.businesses set public_ordering = true where id = test.biz();

select test.login(test.u_admin());
select public.upsert_customer(test.biz(), '{"code":"B001","name":"Gürpınar Bayi","channel":"bayi","price_list":"bayi"}'::jsonb);
select public.upsert_customer(test.biz(), '{"code":"B002","name":"Fuska Bayi","channel":"bayi","price_list":"bayi"}'::jsonb);
select public.upsert_customer(test.biz(), '{"code":"K001","name":"Ofis Müşterisi","channel":"kurumsal"}'::jsonb);
select public.add_member(test.biz(), test.u_bayi(), 'bayi', 'Gürpınar', test.cust('B001'));
select public.add_member(test.biz(), test.u_bayi2(), 'bayi', 'Fuska', test.cust('B002'));

-- ---------------------------------------------------------------- online kayıt
select test.service();
select public.register_customer(test.u_mus(), 'Ali Veli', '5321110001', 'Kartepe Mah. 1. Sok. No 5', null, null, '2026-10-09', true);
select public.register_customer(test.u_mus2(), 'Ayşe Kaya', '5321110002', 'Fuska Mah. 2. Sok. No 7', null, null, '2026-10-09', false);
reset role;
select test.eq(test.events((test.cust_of(test.u_mus())).id), 'aydinlatma:online_kayit:2026-10-09,kampanya_izni:online_kayit:2026-10-09',
  'Kayıtta aydınlatma sürümü ve verilen kampanya izni kaydedilir');
select test.eq(test.events((test.cust_of(test.u_mus2())).id), 'aydinlatma:online_kayit:2026-10-09',
  'Kampanya izni verilmezse yalnızca aydınlatma kaydedilir');
select test.ok((test.cust_of(test.u_mus())).marketing_consent and (test.cust_of(test.u_mus())).marketing_consent_at is not null, 'Kartta izin ve zamanı tutulur');
select test.ok(not (test.cust_of(test.u_mus2())).marketing_consent, 'Kampanya izni varsayılan olarak kapalı');

-- Eski çağrı biçimi (yeni parametreler olmadan) çalışmaya devam eder
insert into auth.users(id, email) values ('00000000-0000-0000-0000-000000000035', '5321110003@musteri.test');
select test.service();
select test.lives($$select public.register_customer('00000000-0000-0000-0000-000000000035', 'Eski Uyg', '5321110003', 'Eski uygulama adresi uzun')$$,
  'Önceki uygulama sürümü kayıt yapabilir');
reset role;

-- ---------------------------------------------------------------- müşteri kendi iznini yönetir
select test.login(test.u_mus());
select public.set_my_marketing(test.biz(), false, '2026-10-09');
select test.ok(not (test.cust_of(test.u_mus())).marketing_consent, 'Müşteri kampanya iznini geri çeker');
select public.set_my_marketing(test.biz(), false, '2026-10-09');
select test.eq((select count(*) from public.privacy_events where kind = 'kampanya_ret')::int, 1, 'Değişmeyen tercih ikinci kez kaydedilmez');
select test.eq((select count(*) from public.privacy_events)::int, 3, 'Müşteri yalnızca kendi kayıtlarını görür');
select test.throws($$select public.record_customer_privacy(test.cust('K001'), 'aydinlatma', 'x')$$,
  '%yetkiniz yok%', 'Müşteri başkası adına kayıt düşemez');
select test.throws($$update public.privacy_events set notice_version = 'x' where true$$, '%permission denied%', 'Müşteri kaydı değiştiremez');

-- ---------------------------------------------------------------- personel
select test.login(test.u_satis());
select public.record_customer_privacy(test.cust('K001'), 'aydinlatma', '2026-10-09');
select public.record_customer_privacy(test.cust('K001'), 'kampanya_izni', '2026-10-09');
select test.eq(test.events(test.cust('K001')), 'aydinlatma:personel:2026-10-09,kampanya_izni:personel:2026-10-09',
  'Satış personeli ilk iletişimde aydınlatmayı ve telefonla verilen izni kaydeder');
select test.throws($$select public.record_customer_privacy(test.cust('K001'), 'sil', '2026-10-09')$$, '%Geçersiz%', 'Bilinmeyen işlem reddedilir');
select test.throws($$select public.set_my_marketing(test.biz(), true, '2026-10-09')$$, '%yetkiniz yok%', 'Personel set_my_marketing kullanamaz');
select test.login(test.u_depo());
select test.throws($$select public.record_customer_privacy(test.cust('K001'), 'aydinlatma', '2026-10-09')$$, '%yetkiniz yok%', 'Depo personeli kayıt düşemez');
select test.eq((select count(*) from public.privacy_events)::int, 0, 'Depo personeli KVKK kayıtlarını görmez');

-- ---------------------------------------------------------------- bayi
select test.login(test.u_bayi());
select public.dealer_upsert_customer(test.biz(), '{"name":"Bayi Ev Müşterisi","address":"Gürpınar Mah. 3"}'::jsonb);
select public.record_customer_privacy(test.cust_named('Bayi Ev Müşterisi'), 'aydinlatma', '2026-10-09');
select test.eq(test.events(test.cust_named('Bayi Ev Müşterisi')), 'aydinlatma:bayi:2026-10-09', 'Bayi kendi müşterisine aydınlatmayı kaydeder');
select test.eq((select count(*) from public.privacy_events)::int, 1, 'Bayi yalnızca kendi müşterilerinin kayıtlarını görür');
select test.throws($$select public.record_customer_privacy(test.cust('K001'), 'aydinlatma', '2026-10-09')$$, '%size ait değil%',
  'Bayi başka müşteri için kayıt düşemez');
select test.login(test.u_bayi2());
select test.throws($$select public.record_customer_privacy(test.cust_named('Bayi Ev Müşterisi'), 'aydinlatma', '2026-10-09')$$, '%size ait değil%',
  'Bayi diğer bayinin müşterisi için kayıt düşemez');
select test.eq((select count(*) from public.privacy_events)::int, 0, 'Diğer bayi kayıtları göremez');

-- ---------------------------------------------------------------- değiştirilemezlik
reset role;
select test.throws($$update public.privacy_events set channel = 'bayi' where true$$, '%değiştirilemez%', 'Kayıt yönetici/sunucu tarafından da değiştirilemez');
select test.throws($$delete from public.privacy_events where true$$, '%değiştirilemez%', 'Kayıt silinemez');
select test.login(test.u_admin());
select test.eq((select count(*) from public.privacy_events)::int, 7, 'Yönetici tüm KVKK kayıtlarını görür');
rollback;
