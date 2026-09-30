-- Güvenlik: RLS, rol yetkileri, doğrudan yazma yasağı, denetim kaydı (Y-01..Y-04, T-01, L-02)
begin;
select test.fixture();

-- İşletme izolasyonu
select test.login(test.u_outsider());
select test.eq((select count(*) from public.businesses)::int, 0, 'Üye olmayan kullanıcı hiçbir işletmeyi görmez');
select test.eq((select count(*) from public.products)::int, 0, 'Üye olmayan kullanıcı ürün göremez');
select test.throws($$select public.complete_sale(test.biz(), '{"id":"11111111-1111-1111-1111-111111111111","items":[{}]}')$$,
                   '%yetkiniz yok%', 'Üye olmayan satış yapamaz');

select test.login(test.u_admin_b());
select test.eq((select count(*) from public.products where business_id = test.biz())::int, 0, 'Başka işletmenin yöneticisi A ürünlerini göremez');
select test.throws($$select public.upsert_brand(test.biz(), 'Sızma')$$, '%yetkiniz yok%', 'Başka işletmeye marka ekleyemez');

-- Doğrudan tablo yazma yasak (T-004, T-01)
select test.login(test.u_admin());
select test.throws($$insert into public.brands(business_id, name) values (test.biz(), 'X')$$, '%permission denied%', 'Yönetici bile tabloya doğrudan yazamaz');
select test.throws($$update public.stock_levels set qty = 999$$, '%permission denied%', 'Stok seviyesi doğrudan değiştirilemez (T-01)');
select test.throws($$delete from public.sales$$, '%permission denied%', 'Satış silinemez');
select test.throws($$update public.product_units set price = 1$$, '%permission denied%', 'Fiyat doğrudan değiştirilemez');

-- Maliyet yalnızca yöneticide (Y-02)
select test.ok((select count(*) from public.product_costs) > 0, 'Yönetici maliyetleri görür');
select test.login(test.u_satis());
select test.eq((select count(*) from public.product_costs)::int, 0, 'Satış personeli maliyet göremez');
select test.eq((select count(*) from public.purchase_item_costs)::int, 0, 'Satış personeli alış fiyatı göremez');
select test.eq((select count(*) from public.cash_movements)::int, 0, 'Satış personeli kasa hareketlerini göremez');
select test.ok((select count(*) from public.products) > 0, 'Satış personeli ürünleri görür');
select test.ok((select count(*) from public.stock_levels) > 0, 'Satış personeli stok miktarını görür');
select test.ok((select count(*) from public.customers) > 0, 'Satış personeli müşterileri görür');
select test.login(test.u_depo());
select test.eq((select count(*) from public.product_costs)::int, 0, 'Depo personeli maliyet göremez');
select test.eq((select count(*) from public.customers)::int, 0, 'Depo personeli müşteri göremez');
select test.ok((select count(*) from public.purchases) > 0, 'Depo personeli mal kabulleri görür');
select test.login(test.u_izleyici());
select test.eq((select count(*) from public.product_costs)::int, 0, 'İzleyici maliyet göremez');
select test.eq((select count(*) from public.sales)::int, 0, 'İzleyici satış ayrıntısı göremez');
select test.eq((select count(*) from audit.log)::int, 0, 'İzleyici işlem geçmişini göremez');

-- Rol yetkileri RPC seviyesinde
select test.login(test.u_satis());
select test.throws($$select public.upsert_product(test.biz(), '{"code":"X","name":"X"}')$$, '%yetkiniz yok%', 'Satış personeli ürün kartı açamaz');
select test.throws($$select public.set_unit_price(test.unit('SU-005','Şişe'), 1)$$, '%yetkiniz yok%', 'Satış personeli fiyat değiştiremez');
select test.throws($$select public.receive_goods(test.biz(), jsonb_build_object('id', gen_random_uuid()))$$, '%yetkiniz yok%', 'Satış personeli mal kabul yapamaz');
select test.login(test.u_depo());
select test.throws($$select test.sell('SU-005', 'Şişe', 1)$$, '%yetkiniz yok%', 'Depo personeli satış yapamaz');
select test.throws($$select public.approve_purchase((select id from public.purchases limit 1), '[]')$$, '%yetkiniz yok%', 'Depo personeli alış fiyatı onaylayamaz');
select test.login(test.u_izleyici());
select test.throws($$select test.sell('SU-005', 'Şişe', 1)$$, '%yetkiniz yok%', 'İzleyici satış yapamaz');

-- anon hiçbir RPC'yi çağıramaz
select test.logout();
set local role anon;
select test.throws($$select public.my_context()$$, '%permission denied%', 'Oturumsuz kullanıcı RPC çağıramaz');
reset role;

-- S-08: satış personeli yalnızca kendi satışlarını görür
select test.login(test.u_admin());
select test.sell('SU-005', 'Şişe', 1);
select test.login(test.u_satis());
select test.sell('SU-005', 'Şişe', 2);
select test.eq((select count(*) from public.sales)::int, 1, 'Satış personeli yalnızca kendi satışını görür');
select test.eq((select count(*) from public.sale_items)::int, 1, 'Satış personeli yalnızca kendi satış kalemlerini görür');
select test.login(test.u_admin());
select test.eq((select count(*) from public.sales)::int, 2, 'Yönetici tüm satışları görür');

-- Y-04: son yönetici korunur
select test.throws($$select public.update_member((select id from public.memberships where user_id = test.u_admin()), 'satis', 'A', true)$$,
                   '%en az bir aktif yönetici%', 'Son yöneticinin rolü düşürülemez (Y-04)');
select test.throws($$select public.update_member((select id from public.memberships where user_id = test.u_admin()), 'yonetici', 'A', false)$$,
                   '%en az bir aktif yönetici%', 'Son yönetici pasife alınamaz (Y-04)');
select test.lives($$select public.update_member((select id from public.memberships where user_id = test.u_satis()), 'depo', 'Satış A', true)$$,
                  'Yönetici başka kullanıcının rolünü değiştirebilir');
select test.login(test.u_satis());
select test.eq(public.my_context()->0->>'role', 'depo', 'Rol değişikliği anında geçerli olur');

-- Denetim kaydı
select test.logout();
select test.ok((select count(*) from audit.log where action = 'satis') >= 2, 'Satışlar denetim kaydına yazılır');
select test.ok((select count(*) from audit.log where table_name = 'memberships' and action = 'update') >= 1, 'Rol değişikliği önceki/yeni değerle kaydedilir');
select test.throws($$delete from audit.log$$, '%değiştirilemez%', 'Denetim kaydı silinemez (L-02)');
select test.throws($$update audit.log set action = 'x'$$, '%değiştirilemez%', 'Denetim kaydı güncellenemez (L-02)');

rollback;
