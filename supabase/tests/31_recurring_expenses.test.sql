-- Her ay düzenli giderler (K-15..K-17)
begin;
select test.fixture();
create function test.cat(p_code text) returns uuid language sql security definer as $$
  select id from public.expense_categories where business_id = test.biz() and code = p_code $$;
create function test.n_rec(p uuid) returns int language sql security definer as $$
  select count(*)::int from public.expenses where recurring_id = p $$;
grant execute on all functions in schema test to authenticated;
select test.login(test.u_admin());

-- Ayın 5'i Selin maaşı, Ağustos 2026'dan beri; bugün 22 Ekim → Ağu, Eyl, Eki = 3 kayıt
create temp table r on commit drop as select public.upsert_recurring_expense(test.biz(), jsonb_build_object(
  'category_id', test.cat('maas'), 'amount', 30000, 'payee', 'Selin', 'day_of_month', 5, 'start_month', '2026-08-01')) as id;
select test.logout();
delete from public.expenses where recurring_id = (select id from r);   -- gerçek tarihten bağımsız sınamak için
select test.eq(app.post_due_recurring(test.biz(), date '2026-10-22'), 3, 'Vadesi gelen 3 ay işlenir');
select test.eq(app.post_due_recurring(test.biz(), date '2026-10-22'), 0, 'Tekrar çalışınca çift kayıt yok');
select test.eq((select string_agg(expense_date::text, ',' order by expense_date) from public.expenses where recurring_id = (select id from r)),
               '2026-08-05,2026-09-05,2026-10-05', 'Her ayın seçilen gününe yazılır');
select test.eq((select min(payee) || '/' || min(method) from public.expenses where recurring_id = (select id from r)), 'Selin/banka', 'Kime ve banka ödemesi');
-- Gün henüz gelmediyse bu ay oluşmaz
select test.eq(app.post_due_recurring(test.biz(), date '2026-11-04'), 0, 'Kasım 5 gelmeden Kasım kaydı yok');
select test.eq(app.post_due_recurring(test.biz(), date '2026-11-05'), 1, 'Kasım 5 gelince Kasım kaydı oluşur');
-- Ayın 31'i kısa ayda ayın son günü
insert into public.recurring_expenses(business_id, category_id, amount, day_of_month, start_month)
values (test.biz(), test.cat('kira'), 15000, 31, '2027-02-01');
select test.eq(app.post_due_recurring(test.biz(), date '2027-02-28'), 4, 'Şubat 28: kira (31→28) + Selin Ara/Oca/Şub');
select test.ok(exists (select 1 from public.expenses where expense_date = '2027-02-28' and amount = 15000), 'Kısa ayda ayın son günü');

-- İptal edilen ay yeniden üretilmez
select test.login(test.u_admin());
select public.cancel_expense((select id from public.expenses where recurring_id = (select id from r) and period = '2026-09-01'), 'Eylülde ödenmedi');
select test.logout();
select test.eq(app.post_due_recurring(test.biz(), date '2027-02-28'), 0, 'İptal edilen ay geri gelmez');

-- Tutar değişikliği yalnızca sonraki aylara
select test.login(test.u_admin());
select public.upsert_recurring_expense(test.biz(), jsonb_build_object('id', (select id from r), 'category_id', test.cat('maas'),
  'amount', 32000, 'payee', 'Selin', 'day_of_month', 5));
select test.logout();
select test.eq((select amount from public.expenses where recurring_id = (select id from r) and period = '2026-10-01'), 30000.00::numeric, 'Geçmiş ay tutarı değişmez');
select test.eq(app.post_due_recurring(test.biz(), date '2027-03-06'), 1, 'Mart 6: maaş (kira 31inde)');
select test.eq((select amount from public.expenses where recurring_id = (select id from r) and period = '2027-03-01'), 32000.00::numeric, 'Yeni ay yeni tutarla');

-- Durdurma
select test.login(test.u_admin());
select public.set_recurring_active((select id from r), false);
select test.logout();
select test.eq(app.post_due_recurring(test.biz(), date '2027-04-06'), 1, 'Durdurulan maaş oluşmaz (yalnız Mart kirası)');

-- Yetki
select test.login(test.u_satis());
select test.throws($$select public.upsert_recurring_expense(test.biz(), jsonb_build_object('category_id', test.cat('yakit'), 'amount', 1, 'day_of_month', 1))$$,
                   '%yetkiniz yok%', 'Düzenli gideri yalnızca yönetici tanımlar');
select test.eq((select count(*)::int from public.recurring_expenses), 0, 'Personel düzenli giderleri görmez');
select test.throws($$select public.post_due_recurring(test.biz())$$, '%yetkiniz yok%', 'Personel işletemez');
select test.login(test.u_admin());
select test.throws($$select public.upsert_recurring_expense(test.biz(), jsonb_build_object('category_id', test.cat('yakit'), 'amount', 1, 'day_of_month', 32))$$,
                   '%1 ile 31%', 'Geçersiz gün reddedilir');
rollback;
