-- Kalite: tarih aralığı filtreleri (İstanbul gün sınırı) ve düzenli gider günlük kontrolü (D-103)
begin;
select test.fixture();
create function test.cat(p_code text) returns uuid language sql security definer as $$
  select id from public.expense_categories where business_id = test.biz() and code = p_code $$;
grant execute on all functions in schema test to authenticated;

select test.eq(app.day_start(date '2026-10-23'), timestamptz '2026-10-22 21:00:00+00', 'Gün başı İstanbul saatiyle 00:00');

select test.login(test.u_admin());
create temp table s1 on commit drop as select (test.sell('SU-005', 'Koli', 1))->>'id' as id;
create temp table s2 on commit drop as select (test.sell('SU-005', 'Koli', 2))->>'id' as id;
select test.logout();
-- 22.10 23:30 (İstanbul) ve 23.10 00:30 (İstanbul)
update public.sales set sold_at = timestamptz '2026-10-22 23:30:00+03' where id = (select id::uuid from s1);
update public.sales set sold_at = timestamptz '2026-10-23 00:30:00+03' where id = (select id::uuid from s2);
select test.login(test.u_admin());
select test.eq((select sales_count from public.report_daily_sales(test.biz(), date '2026-10-22', date '2026-10-22'))::int, 1, '23:30 satışı 22 Ekime yazılır');
select test.eq((select sales_count from public.report_daily_sales(test.biz(), date '2026-10-23', date '2026-10-23'))::int, 1, '00:30 satışı 23 Ekime yazılır');
select test.eq((select sum(sales_count) from public.report_daily_sales(test.biz(), date '2026-10-22', date '2026-10-23'))::int, 2, 'İki gün birlikte');
select test.eq((select sum(qty_base) from public.report_product_sales(test.biz(), date '2026-10-23', date '2026-10-23', 'urun'))::int,
               (select base_qty from public.sale_items where sale_id = (select id::uuid from s2)), 'Ürün raporu aynı gün sınırını kullanır');
select test.ok((public.dashboard(test.biz()) ? 'critical_count') and (public.dashboard(test.biz()) ? 'negative_count'), 'Ana sayfa stok sayıları');

-- Düzenli gider: günde bir kontrol
select test.logout();
insert into public.recurring_expenses(business_id, category_id, amount, day_of_month, start_month)
values (test.biz(), test.cat('kira'), 1000, 1, date_trunc('month', app.local_date(now()))::date);
select test.login(test.u_admin());
select test.eq(public.post_due_recurring(test.biz()), 1, 'İlk açılışta vadesi gelen işlenir');
select test.logout();
insert into public.recurring_expenses(business_id, category_id, amount, day_of_month, start_month)
values (test.biz(), test.cat('yakit'), 500, 1, date_trunc('month', app.local_date(now()))::date);
select test.login(test.u_admin());
select test.eq(public.post_due_recurring(test.biz()), 0, 'Aynı gün ikinci açılışta tekrar çalışmaz');
select test.logout();
select test.eq(app.post_due_recurring(test.biz()), 1, 'Şablon kaydında doğrudan çekirdek çalışır');
select test.eq((select recurring_checked_on from public.app_settings where business_id = test.biz()), app.local_date(now()), 'Kontrol günü saklanır');
rollback;
