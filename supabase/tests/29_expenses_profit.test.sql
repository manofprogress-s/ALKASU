-- Giderler + gelir-gider raporu + İşbaşı'nda elle kesilen fatura (K-11..K-14, GG-01..GG-03, F-29)
begin;
select test.fixture();
create function test.u_sv() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-000000000039'::uuid $$;
create function test.rep(p_grain text default 'ay') returns jsonb language sql as $$
  select public.profit_report(test.biz(), app.local_date(now()), app.local_date(now()), p_grain)->'periods'->0 $$;
create function test.cat(p_code text) returns uuid language sql security definer as $$
  select id from public.expense_categories where business_id = test.biz() and code = p_code $$;
grant execute on all functions in schema test to authenticated;
insert into auth.users(id, email) values (test.u_sv(), 'sv39@t');
select test.login(test.u_admin());
select public.add_member(test.biz(), test.u_sv(), 'sevkiyat', 'Hüseyin');

-- Kategoriler
select test.eq((select count(*) from public.expense_categories where business_id = test.biz() and restricted)::int, 3, 'Maaş, kira, vergi/SGK kısıtlı');
select test.ok(test.cat('temizlik') is not null and test.cat('maas') is not null, 'Temizlik ve maaş kategorileri var');

create temp table r0 on commit drop as select test.rep() as r;

-- Gelir: satış faturasız (turuncu) sayılır
create temp table sale on commit drop as
  select (test.sell('SU-005', 'Koli', 2, jsonb_build_object('customer_id', test.cust('M002'))))->>'id' as id;
create temp table s1 on commit drop as select goods_net from public.sales where id = (select id::uuid from sale);
select test.eq((test.rep()->>'income_uninvoiced')::numeric - ((select r from r0)->>'income_uninvoiced')::numeric,
               (select goods_net from s1), 'Satış faturasız gelir olarak sayılır');

-- İşbaşı'nda elle kesildi → faturalı (yeşil)
create temp table inv on commit drop as select public.create_invoice_draft(test.biz(), (select id::uuid from sale)) as id;
select test.throws($$select public.invoice_action(test.biz(), (select id from inv), 'elle_kesildi', '')$$, '%fatura numarasını%', 'Fatura numarası zorunlu');
select test.eq(public.invoice_action(test.biz(), (select id from inv), 'elle_kesildi', 'ALK2026000000001'), 'resmilesti', 'Elle kesildi işaretlenir');
select test.eq((test.rep()->>'income_invoiced')::numeric - ((select r from r0)->>'income_invoiced')::numeric,
               (select goods_net from s1), 'Faturası kesilen satış faturalı gelire geçer');
select test.eq((test.rep()->>'income_uninvoiced')::numeric, ((select r from r0)->>'income_uninvoiced')::numeric, 'Faturasız gelirden çıkar');
select test.throws($$select public.invoice_action(test.biz(), (select id from inv), 'iptal', 'yanlış')$$, '%Logo İşbaşı üzerinden%', 'Kesilmiş fatura buradan iptal edilemez');
create temp table sale2 on commit drop as select (test.sell('SU-005', 'Koli', 1, jsonb_build_object('customer_id', test.cust('M002'))))->>'id' as id;
create temp table inv2 on commit drop as select public.create_invoice_draft(test.biz(), (select id::uuid from sale2)) as id;
select test.throws($$select public.invoice_action(test.biz(), (select id from inv2), 'elle_kesildi', 'ALK2026000000001')$$, '%başka bir satışa%', 'Aynı fatura no iki satışa işlenemez');

-- Gider: mal kabul (alış fiyatı × miktar)
select public.receive_goods(test.biz(), jsonb_build_object('id', '39393939-0000-0000-0000-000000000001',
  'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005', 'Koli'), 'qty', 10, 'unit_cost', 150))));
select test.eq((select status from public.purchases where id = '39393939-0000-0000-0000-000000000001'), 'onaylandi', 'Yönetici mal kabulü onaylı');
select test.eq((test.rep()->>'purchases')::numeric - ((select r from r0)->>'purchases')::numeric, 1500::numeric, 'Mal kabul gidere girer');

-- Personel gider girer
select test.login(test.u_sv());
select public.add_expense(test.biz(), jsonb_build_object('id', '39393939-0000-0000-0000-0000000000e1', 'category_id', test.cat('yakit'),
  'amount', 100, 'method', 'banka', 'description', 'Kamyonet'));
select test.throws($$select public.add_expense(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'category_id', test.cat('maas'), 'amount', 1, 'method', 'banka'))$$,
                   '%yalnızca yönetici%', 'Personel maaş giremez');
select test.throws($$select public.add_expense(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'category_id', test.cat('kira'), 'amount', 1, 'method', 'banka'))$$,
                   '%yalnızca yönetici%', 'Personel kira giremez');
select test.throws($$select public.add_expense(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'category_id', test.cat('sarf'), 'amount', 1, 'method', 'banka',
                     'expense_date', (app.local_date(now()) + 1)::text))$$, '%İleri tarihli%', 'İleri tarihli gider girilemez');
select test.throws($$select public.add_expense(test.biz(), jsonb_build_object('id', gen_random_uuid(), 'category_id', test.cat('sarf'), 'amount', 1, 'method', 'banka',
                     'expense_date', (app.local_date(now()) - 40)::text))$$, '%1 ay%', 'Personel çok eski tarihli gider giremez');
select test.throws($$select public.profit_report(test.biz(), current_date, current_date, 'ay')$$, '%yetkiniz yok%', 'Personel raporu göremez');
select test.eq((select count(*) from public.expense_categories where business_id = test.biz() and restricted)::int, 0, 'Personel kısıtlı kategorileri görmez');

select test.login(test.u_admin());
select public.add_expense(test.biz(), jsonb_build_object('id', '39393939-0000-0000-0000-0000000000e2', 'category_id', test.cat('maas'),
  'amount', 30000, 'method', 'banka', 'payee', 'Selin'));
select test.eq((select payee from public.expenses where id = '39393939-0000-0000-0000-0000000000e2'), 'Selin', 'Maaşta kime ödendiği saklanır');
select test.eq((test.rep()->>'expenses')::numeric - ((select r from r0)->>'expenses')::numeric, 30100::numeric, 'İşletme giderleri toplanır');
select test.eq((test.rep()->'expense_categories'->>'Personel maaşları')::numeric, 30000::numeric, 'Kategori kırılımı');
select test.eq((select ((r->>'income')::numeric - (r->>'purchases')::numeric) = (r->>'gross_profit')::numeric
                   and ((r->>'gross_profit')::numeric - (r->>'expenses')::numeric) = (r->>'net_profit')::numeric
                  from (select test.rep() as r) x), true, 'Brüt = gelir − mal alımı; net = brüt − gider');

-- Personel yalnızca kendi girdiğini görür; toplam göremez
select test.login(test.u_sv());
select test.eq((select count(*) from public.expenses)::int, 1, 'Personel yalnızca kendi giderini görür');
select test.login(test.u_satis());
select test.eq((select count(*) from public.expenses)::int, 0, 'Başka personelin giderini görmez');
select test.throws($$select public.cancel_expense('39393939-0000-0000-0000-0000000000e1', 'hata')$$, '%yalnızca yönetici%', 'Başkasının giderini iptal edemez');
select test.login(test.u_sv());
select public.cancel_expense('39393939-0000-0000-0000-0000000000e1', 'Yanlış tutar');
select test.eq((select status from public.expenses where id = '39393939-0000-0000-0000-0000000000e1'), 'iptal', 'Personel kendi gideri aynı gün iptal eder');
select test.login(test.u_admin());
select test.eq((test.rep()->>'expenses')::numeric - ((select r from r0)->>'expenses')::numeric, 30000::numeric, 'İptal edilen gider rapordan düşer');

-- Haftalık dönem
select test.ok((select jsonb_array_length(public.profit_report(test.biz(), date '2026-10-01', date '2026-10-31', 'hafta')->'periods')) = 5,
               'Ekim 2026 haftalık 5 dönem (1. hafta ayın 1inden başlar)');
select test.eq((select public.profit_report(test.biz(), date '2026-10-01', date '2026-10-31', 'hafta')->'periods'->1->>'start'), '2026-10-05', 'Haftalar pazartesi başlar');
select test.eq((select jsonb_array_length(public.profit_report(test.biz(), date '2026-01-01', date '2026-12-31', 'ay')->'periods')), 12, 'Yıllık 12 ay');
select test.throws($$select public.profit_report(test.biz(), date '2026-02-01', date '2026-01-01', 'ay')$$, '%geçersiz%', 'Ters aralık reddedilir');
rollback;
