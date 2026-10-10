-- Müşterinin kendi siparişi, ilk sipariş onayı, bayiye elle atama, bayi teslimatı, rota (D-051..D-058)
begin;
select test.fixture();

create function test.u_bayi()  returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000021'::uuid $$;
create function test.u_bayi2() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000022'::uuid $$;
create function test.u_mus()   returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000023'::uuid $$;
create function test.u_mus2()  returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000024'::uuid $$;
create function test.ord(p_id uuid) returns public.orders language sql stable security definer as $$ select * from public.orders where id = p_id $$;
create function test.cust_of(p_user uuid) returns public.customers language sql stable security definer as $$ select * from public.customers where user_id = p_user $$;
create function test.service() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
  perform set_config('role', 'service_role', true);
end $$;
create function test.item(p_code text, p_unit text, p_qty int) returns jsonb language sql stable security definer as $$
  select jsonb_build_object('product_id', test.pid(p_code), 'unit_id', test.unit(p_code, p_unit), 'qty', p_qty)
$$;
grant usage on schema test to anon, service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

insert into auth.users(id, email) values (test.u_bayi(), 'b1@test'), (test.u_bayi2(), 'b2@test'),
  (test.u_mus(), '5321112233@musteri.test'), (test.u_mus2(), '5329998877@musteri.test');
update public.businesses set public_ordering = true where id = test.biz();

-- Bayi kartları ve kullanıcıları
select test.login(test.u_admin());
select public.upsert_customer(test.biz(), '{"code":"B001","name":"Sağlam Ticaret","channel":"bayi","price_list":"bayi"}'::jsonb);
select public.upsert_customer(test.biz(), '{"code":"B002","name":"Yıldız Ticaret","channel":"bayi","price_list":"bayi"}'::jsonb);
select public.add_member(test.biz(), test.u_bayi(), 'bayi', 'İbrahim', test.cust('B001'));
select public.add_member(test.biz(), test.u_bayi2(), 'bayi', 'Hüseyin Y', test.cust('B002'));
select public.set_list_price(test.unit('SU-005', 'Koli'), 'bayi', 150);

-- ---------------------------------------------------------------- ziyaretçi kataloğu ve kayıt
select test.logout();
set local role anon;
select test.ok((select count(*) from public.public_catalog()) >= 3, 'Ziyaretçi herkese açık ürün listesini görür');
select test.eq((select price from public.public_catalog() where unit_id = test.unit('SU-005', 'Koli')), 200.00::numeric,
  'Ziyaretçiye perakende fiyat gösterilir');
select test.throws($$select count(*) from public.products$$, '%permission denied%', 'Ziyaretçi tabloları doğrudan okuyamaz');
select test.throws($$select public.register_customer(gen_random_uuid(), 'Ad Soyad', '5321112233', 'Açık adres yeterince uzun')$$,
  '%permission denied%', 'Ziyaretçi kayıt fonksiyonunu doğrudan çağıramaz');
reset role;

select test.login(test.u_admin());
select test.throws($$select public.register_customer(test.u_mus(), 'Ad Soyad', '5321112233', 'Açık adres yeterince uzun')$$,
  '%yetkiniz yok%', 'Kayıt yalnızca sunucu (service_role) tarafından yapılır');
select test.service();
select test.throws($$select public.register_customer(test.u_mus(), 'Ali Veli', '12345', 'Kartepe Mah. 1. Sok. No 5')$$, '%Telefon%', 'Geçersiz telefon reddedilir');
select test.throws($$select public.register_customer(test.u_mus(), 'Ali Veli', '5321112233', 'kısa')$$, '%adres%', 'Açık adres zorunlu');
select public.register_customer(test.u_mus(), 'Ali Veli', '5321112233', 'Kartepe Mah. 1. Sok. No 5', 40.75, 30.02);
select public.register_customer(test.u_mus2(), 'Ayşe Kaya', '5329998877', 'Fuska Mah. 2. Sok. No 7');
select test.eq((test.cust_of(test.u_mus())).approved, false, 'İnternetten kayıt olan müşteri onaysız başlar');
select test.eq((test.cust_of(test.u_mus())).channel, 'perakende', 'Online müşteri ev müşterisidir');
select test.eq((test.cust_of(test.u_mus())).phone, '05321112233', 'Telefon 0 ile saklanır');
select test.throws($$select public.register_customer(test.u_mus(), 'Ali Veli', '5321112233', 'Kartepe Mah. 1. Sok. No 5')$$, '%zaten kayıtlı%', 'Aynı kullanıcı iki kez kayıt olamaz');
select test.logout();

-- ---------------------------------------------------------------- müşterinin kendi siparişi
select test.login(test.u_mus());
select public.save_order(test.biz(), jsonb_build_object('id', '88888888-0000-0000-0000-000000000001', 'customer_id', test.cust('M001'),
  'assignee', test.u_admin(), 'delivery_date', '2020-01-01',
  'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005', 'Koli'), 'qty', 2, 'unit_price', 1))));
select test.eq((test.ord('88888888-0000-0000-0000-000000000001')).customer_id, (test.cust_of(test.u_mus())).id, 'Müşteri yalnızca kendi adına sipariş verir');
select test.eq((test.ord('88888888-0000-0000-0000-000000000001')).status, 'onay_bekliyor', 'İlk online sipariş onay bekler');
select test.eq((test.ord('88888888-0000-0000-0000-000000000001')).assignee, null::uuid, 'Müşteri atama yapamaz');
select test.eq((test.ord('88888888-0000-0000-0000-000000000001')).source, 'online', 'Kaynak: online');
select test.ok((test.ord('88888888-0000-0000-0000-000000000001')).delivery_date >= app.local_date(now()), 'Geçmiş teslim tarihi bugüne çekilir');
select test.eq((select unit_price from public.order_items where order_id = '88888888-0000-0000-0000-000000000001'), 200.00::numeric, 'Müşteri fiyat belirleyemez');
select test.eq((select count(*) from public.orders)::int, 1, 'Müşteri yalnızca kendi siparişini görür');
select test.eq((select count(*) from public.customers)::int, 1, 'Müşteri yalnızca kendi kartını görür');
select test.eq((select count(*) from public.stock_levels)::int, 0, 'Müşteri stok göremez');
select test.eq((select count(*) from public.product_prices)::int, 0, 'Müşteri fiyat geçmişini göremez');
select test.eq((select count(*) from public.product_list_prices)::int, 0, 'Müşteri bayi/palet fiyatlarını göremez');
select test.eq((select count(*) from public.app_settings)::int, 0, 'Müşteri ayarları göremez');
select test.throws($$select test.sell('SU-005', 'Koli', 1)$$, '%yetkiniz yok%', 'Müşteri satış yapamaz');
select test.throws($$select public.assignable_users(test.biz())$$, '%yetkiniz yok%', 'Müşteri personel listesini göremez');
select test.eq((public.dashboard(test.biz())->>'pending_approval')::int, 1, 'Müşteri özetinde onay bekleyen sipariş');
select public.update_my_profile(test.biz(), '{"name":"Ali Veli","address":"Yeni adres Kartepe","latitude":40.8,"longitude":30.1}'::jsonb);
select test.eq((test.cust_of(test.u_mus())).latitude, 40.800000::numeric, 'Müşteri kendi konumunu günceller');

select test.login(test.u_mus2());
select test.eq((select count(*) from public.orders)::int, 0, 'Başka müşteri bu siparişi göremez');
select test.throws($$select public.cancel_order('88888888-0000-0000-0000-000000000001', 'x')$$, '%size ait değil%', 'Başka müşteri iptal edemez');

-- ---------------------------------------------------------------- onay
select test.login(test.u_satis());
select test.eq((public.dashboard(test.biz())->>'pending_approval')::int, 1, 'Personel onay bekleyenleri görür');
select test.throws($$select public.assign_order_dealer('88888888-0000-0000-0000-000000000001', test.cust('B001'))$$, '%onaylanmış%',
  'Onaylanmamış sipariş bayiye atanamaz');
select test.throws($$select public.deliver_order(test.biz(), jsonb_build_object('order_id', '88888888-0000-0000-0000-000000000001', 'sale_id', gen_random_uuid(), 'payments', '[]'::jsonb))$$,
  '%onaylanmadı%', 'Onaylanmamış sipariş teslim edilemez');
select public.approve_order('88888888-0000-0000-0000-000000000001');
select test.eq((test.ord('88888888-0000-0000-0000-000000000001')).status, 'acik', 'Onaylanan sipariş açılır');
select test.eq((test.cust_of(test.u_mus())).approved, true, 'Onayla müşteri kartı da onaylanır');
select test.throws($$select public.approve_order('88888888-0000-0000-0000-000000000001')$$, '%onay beklemiyor%', 'İkinci onay reddedilir');

select test.login(test.u_mus());
select public.save_order(test.biz(), jsonb_build_object('id', '88888888-0000-0000-0000-000000000002',
  'items', jsonb_build_array(test.item('DM-001', 'Damacana', 3))));
select test.eq((test.ord('88888888-0000-0000-0000-000000000002')).status, 'acik', 'Onaylı müşterinin sonraki siparişi doğrudan açılır');

-- ---------------------------------------------------------------- bayiye elle atama ve bayi teslimatı
select test.login(test.u_bayi());
select test.eq((select count(*) from public.orders)::int, 0, 'Atanmadan önce bayi ev müşterisi siparişini görmez');
select test.eq((select count(*) from public.customers)::int, 1, 'Bayi yalnızca kendi kartını görür');

select test.login(test.u_satis());
select test.throws($$select public.assign_order_dealer('88888888-0000-0000-0000-000000000001', test.cust('M001'))$$, '%Bayi bulunamadı%',
  'Bayi olmayan müşteriye atanamaz');
select public.assign_order('88888888-0000-0000-0000-000000000001', test.u_satis());
select public.assign_order_dealer('88888888-0000-0000-0000-000000000001', test.cust('B001'));
select test.eq((test.ord('88888888-0000-0000-0000-000000000001')).assignee, null::uuid, 'Bayiye atanınca personel ataması kalkar');
select public.assign_order_dealer('88888888-0000-0000-0000-000000000002', test.cust('B001'));
select test.throws($$select public.deliver_order(test.biz(), jsonb_build_object('order_id', '88888888-0000-0000-0000-000000000001', 'sale_id', gen_random_uuid(), 'payments', '[]'::jsonb))$$,
  '%bayiye atanmış%', 'Bayiye atanmış sipariş bizden satışa dönüşmez');

select test.login(test.u_mus());
select test.throws($$select public.cancel_order('88888888-0000-0000-0000-000000000001', 'vazgeçtim')$$, '%teslimata çıktı%',
  'Teslimata çıkan siparişi müşteri iptal edemez');

select test.login(test.u_bayi());
select test.eq((select count(*) from public.orders)::int, 2, 'Bayi kendisine atanan siparişleri görür');
select test.eq((select count(*) from public.customers)::int, 2, 'Bayi atanan siparişin müşterisini (adres/konum) görür');
select test.eq((select phone from public.customers where user_id = test.u_mus()), '05321112233', 'Bayi müşterinin telefonunu görür');
select test.eq((select count(*) from public.order_items)::int, 2, 'Bayi atanan siparişin kalemlerini görür');
select test.eq((public.dashboard(test.biz())->>'dealer_open')::int, 2, 'Bayi özetinde atanan teslimatlar');
select test.eq(public.set_route(test.biz(), array['88888888-0000-0000-0000-000000000002', '88888888-0000-0000-0000-000000000001']::uuid[]), 2,
  'Bayi kendi teslimat sırasını kaydeder');
select test.eq((test.ord('88888888-0000-0000-0000-000000000001')).route_seq, 2, 'Rota sırası yazılır');

select test.login(test.u_bayi2());
select test.eq((select count(*) from public.orders)::int, 0, 'Diğer bayi bu siparişleri görmez');
select test.throws($$select public.dealer_complete_order('88888888-0000-0000-0000-000000000001')$$, '%size atanmamış%', 'Diğer bayi kapatamaz');
select test.throws($$select public.set_route(test.biz(), array['88888888-0000-0000-0000-000000000001']::uuid[])$$, '%size ait olmayan%',
  'Diğer bayi rota yazamaz');

select test.login(test.u_bayi());
select test.lives($$select public.dealer_complete_order('88888888-0000-0000-0000-000000000001', 'Kapıda teslim')$$, 'Bayi teslim edildi olarak kapatır');
select test.eq((test.ord('88888888-0000-0000-0000-000000000001')).status, 'teslim_edildi', 'Sipariş teslim edildi');
select test.eq((test.ord('88888888-0000-0000-0000-000000000001')).sale_id, null::uuid, 'Bayi teslimatı bizde satış oluşturmaz');
select test.eq(test.stock('SU-005'), 240, 'Bayi teslimatı bizim stoğu değiştirmez');
select test.eq(test.balance('M001'), 0.00::numeric, 'Bayi teslimatı cari oluşturmaz');
select test.throws($$select public.dealer_release_order('88888888-0000-0000-0000-000000000002', ' ')$$, '%zorunlu%', 'Geri bırakma nedeni zorunlu');
select public.dealer_release_order('88888888-0000-0000-0000-000000000002', 'Araç arızalı');
select test.eq((test.ord('88888888-0000-0000-0000-000000000002')).dealer_customer_id, null::uuid, 'Bayi siparişi geri bırakır');
select test.eq((select count(*) from public.orders)::int, 1, 'Geri bırakılan sipariş bayiden kalkar');

-- ---------------------------------------------------------------- rota ve depo konumu
select test.login(test.u_satis());
select test.throws($$select public.set_location_coords(app_default_loc.id, 40.7, 29.9) from (select app.default_location(test.biz()) as id) app_default_loc$$,
  null, 'Depo konumunu yalnızca yönetici girer');
select test.throws($$select public.set_route(test.biz(), array['88888888-0000-0000-0000-000000000001']::uuid[])$$, '%geçersiz%',
  'Kapanmış sipariş rotaya yazılamaz');
select test.login(test.u_admin());
select public.set_location_coords((select id from public.locations where business_id = test.biz() and is_default), 40.7651, 29.9408);
select test.eq((select latitude from public.locations where business_id = test.biz() and is_default), 40.765100::numeric, 'Depo konumu kaydedilir');

-- Mevcut kurallar korunur: personel siparişi
select public.save_order(test.biz(), jsonb_build_object('id', '88888888-0000-0000-0000-000000000003', 'customer_id', test.cust('M001'),
  'items', jsonb_build_array(test.item('SU-005', 'Koli', 1))));
select test.eq((test.ord('88888888-0000-0000-0000-000000000003')).status, 'acik', 'Ofis siparişi onay beklemez');
select test.eq((test.ord('88888888-0000-0000-0000-000000000003')).source, 'ofis', 'Kaynak: ofis');

select test.logout();
-- ---------------------------------------------------------------- güvenlik incelemesi düzeltmeleri
select test.login(test.u_bayi2());
select public.save_order(test.biz(), jsonb_build_object('id', '88888888-0000-0000-0000-000000000009', 'items', jsonb_build_array(test.item('SU-005', 'Koli', 3))));
select test.login(test.u_admin());
select public.approve_order('88888888-0000-0000-0000-000000000009');
select test.throws($$select public.assign_order_dealer('88888888-0000-0000-0000-000000000009', test.cust('B001'))$$, '%gerekçe%',
  'Bayinin kendi alımını başka bayiye vermek özel yönlendirmedir: gerekçe zorunlu');
select public.assign_order_dealer('88888888-0000-0000-0000-000000000002', test.cust('B002'));
select test.throws($$select public.set_route(test.biz(), array['88888888-0000-0000-0000-000000000002']::uuid[])$$, '%size ait olmayan%',
  'Personel bayiye verilmiş siparişin sırasını değiştiremez');
select test.throws($$select public.update_member((select id from public.memberships where user_id = test.u_mus()), 'satis', 'X', true)$$,
  '%personel veya bayi yapılamaz%', 'İnternet müşterisi personele çevrilemez');
select public.update_member((select id from public.memberships where user_id = test.u_mus()), 'musteri', 'Ali Veli', false);
select test.eq((select customer_id from public.memberships where user_id = test.u_mus()), (test.cust_of(test.u_mus())).id, 'Pasife alınan müşterinin kart bağlantısı korunur');
select test.throws($$select public.update_member((select id from public.memberships where user_id = test.u_satis()), 'musteri', 'X', true)$$,
  '%personel veya bayi yapılamaz%', 'Personel müşteriye çevrilemez');

select test.login(test.u_bayi());
select public.update_my_profile(test.biz(), '{"name":"Yıldız Ticaret","latitude":40.71,"longitude":29.91}'::jsonb);
select test.eq((select name from public.customers where id = test.cust('B001')), 'Sağlam Ticaret', 'Bayi kart adını değiştiremez');
select test.eq((select latitude from public.customers where id = test.cust('B001')), 40.710000::numeric, 'Bayi depo konumunu girer');
select public.update_my_profile(test.biz(), '{"address":"Gürpınar depo"}'::jsonb);
select test.eq((select latitude from public.customers where id = test.cust('B001')), 40.710000::numeric, 'Gönderilmeyen konum silinmez');

select test.logout();
select test.service();
select test.ok((select bool_and(public.signup_attempt('1.2.3.4', '5550000000') is not null) from generate_series(1, 5)), 'İlk 5 deneme kabul edilir');
select test.eq(public.signup_attempt('1.2.3.4', '5550000001'), null::bigint, 'Aynı IPden 6. deneme reddedilir');
select test.eq(public.signup_attempt('9.9.9.9', '5550000000'), null::bigint, 'Aynı telefondan günde 6. deneme reddedilir');
select test.logout();
select test.login(test.u_admin());
select test.throws($$select public.signup_attempt('1.1.1.1', '5550000002')$$, '%yetkiniz yok%', 'Hız sınırı fonksiyonu yalnızca sunucu içindir');

rollback;
