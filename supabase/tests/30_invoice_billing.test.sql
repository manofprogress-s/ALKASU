-- Faturalama yöntemi: aylık toplu / sevkiyat başına (F-30..F-36)
begin;
select test.fixture();
-- Sipariş aç + teslim et (kısmi miktar verilebilir); veresiye ile kapatır
create function test.order_deliver(p_cust text, p_order uuid, p_sale uuid, p_qty int, p_deliver int default null) returns uuid
language plpgsql as $$
declare v_item uuid; v_price numeric;
begin
  perform public.save_order(test.biz(), jsonb_build_object('id', p_order, 'customer_id', test.cust(p_cust), 'assignee', test.u_admin(),
    'items', jsonb_build_array(jsonb_build_object('product_id', test.pid('SU-005'), 'unit_id', test.unit('SU-005', 'Koli'), 'qty', p_qty))));
  select id, unit_price into v_item, v_price from public.order_items where order_id = p_order;
  perform public.deliver_order(test.biz(), jsonb_build_object('order_id', p_order, 'sale_id', p_sale,
    'items', jsonb_build_array(jsonb_build_object('order_item_id', v_item, 'qty', coalesce(p_deliver, p_qty))),
    'payments', jsonb_build_array(jsonb_build_object('method', 'veresiye', 'amount', v_price * coalesce(p_deliver, p_qty)))));
  return p_sale;
end $$;
create function test.inv_sales(p_inv uuid) returns int language sql security definer as $$
  select count(*)::int from public.invoice_sales where invoice_id = p_inv and active $$;
grant execute on all functions in schema test to authenticated;

select test.logout();
update public.customers set channel = 'kurumsal', tax_no = '1234567890', tax_office = 'Alemdar', address = 'Köseköy', city = 'Kocaeli',
       district = 'Kartepe', email = 'a@b.com' where id = test.cust('M002');
select test.login(test.u_admin());

-- Yöntem: varsayılan sevkiyat başına; yalnızca yönetici değiştirir
select test.eq((select billing_mode from public.customers where id = test.cust('M002')), 'teslimat', 'Varsayılan sevkiyat başına');
select public.set_customer_billing_mode(test.biz(), test.cust('M002'), 'aylik');
select test.eq((select billing_mode from public.customers where id = test.cust('M002')), 'aylik', 'Aylık toplu seçilir');
select test.login(test.u_satis());
select test.throws($$select public.set_customer_billing_mode(test.biz(), test.cust('M001'), 'aylik')$$, '%yetkiniz yok%', 'Satış personeli fatura yöntemini değiştiremez');
select test.login(test.u_admin());

-- Aylık müşteriye 3 teslimat (biri kısmi: 10 sipariş, 7 teslim)
select test.order_deliver('M002', 'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', 2);
select test.order_deliver('M002', 'a0000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000002', 10, 7);
select test.order_deliver('M002', 'a0000000-0000-0000-0000-000000000003', 'b0000000-0000-0000-0000-000000000003', 3);
-- 3. teslimattan 1 koli iade
select public.create_return(jsonb_build_object('id', gen_random_uuid(), 'sale_id', 'b0000000-0000-0000-0000-000000000003', 'reason', 'Hasarlı',
  'items', jsonb_build_array(jsonb_build_object('sale_item_id', (select id from public.sale_items where sale_id = 'b0000000-0000-0000-0000-000000000003'), 'qty', 1, 'condition', 'saglam'))));

create temp table mb on commit drop as select public.monthly_billing(test.biz(), app.local_date(now())) as j;
select test.eq((select jsonb_array_length(j->'customers') from mb), 1, 'Aylık listede müşteri bir kez');
select test.eq((select (j->'customers'->0->>'count')::int from mb), 3, 'Ayın 3 teslimatı gruplanır');

-- Kontrol ekranı: birleşik satır, yalnızca teslim edilen − iade
create temp table pv on commit drop as select public.invoice_preview_multi(test.biz(), array['b0000000-0000-0000-0000-000000000001','b0000000-0000-0000-0000-000000000002','b0000000-0000-0000-0000-000000000003']::uuid[]) as j;
select test.eq((select jsonb_array_length(j->'lines') from pv), 1, 'Aynı ürün/fiyat tek satırda birleşir');
select test.eq((select (j->'lines'->0->>'qty')::int from pv), 2 + 7 + 2, 'Miktar = teslim edilen − iade (siparişteki 10 değil)');
select test.eq((select jsonb_array_length(j->'sales') from pv), 3, 'Faturadaki teslimatlar listelenir');
select test.ok((select (j->'sales'->1->>'order_no') is not null from pv), 'Teslimatın sipariş numarası izlenir');
select test.ok((select bool_or(x->>'field' = 'returns') from pv, jsonb_array_elements(j->'issues') x), 'İade düşüldü uyarısı');

-- Aylık fatura: üç teslimat tek kayıtta
create temp table inv on commit drop as select public.create_invoice(test.biz(),
  array['b0000000-0000-0000-0000-000000000001','b0000000-0000-0000-0000-000000000002','b0000000-0000-0000-0000-000000000003']::uuid[], 'aylik') as id;
select test.eq(test.inv_sales((select id from inv)), 3, 'Aylık faturada 3 teslimat birleşti');
select test.eq((select kind from public.invoices where id = (select id from inv)), 'aylik', 'Fatura türü aylık');
select test.eq((select sale_id from public.invoices where id = (select id from inv)), null::uuid, 'Aylık faturada tek satış alanı boş');
select test.eq((select (totals->>'gross')::numeric from public.invoices where id = (select id from inv)),
               (select sum(i.line_net) from public.sale_items i where i.sale_id in ('b0000000-0000-0000-0000-000000000001','b0000000-0000-0000-0000-000000000002','b0000000-0000-0000-0000-000000000003'))
               - (select sum(refund_amount) from public.return_items), 'Fatura tutarı = teslimatlar − iade');

-- Tekrar faturalama engeli
select test.throws($$select public.create_invoice(test.biz(), array['b0000000-0000-0000-0000-000000000002']::uuid[], 'aylik')$$, '%zaten faturalanmış%', 'Aynı teslimat ikinci kez faturalanamaz (aylık)');
select test.throws($$select public.create_invoice_draft(test.biz(), 'b0000000-0000-0000-0000-000000000002')$$, '%zaten var%', 'Aynı teslimat ikinci kez faturalanamaz (tek)');
select test.eq((select jsonb_array_length(public.monthly_billing(test.biz(), app.local_date(now()))->'customers')), 0, 'Faturalanan teslimatlar aylık listeden çıkar');
select test.ok(not exists (select 1 from public.uninvoiced_sales(test.biz(), true, 200, 0) u where u.id = 'b0000000-0000-0000-0000-000000000001'), 'Faturalanmamışlar listesinde yok');
select test.ok((select bool_or(x->>'message' like 'Zaten faturalanmış%') from jsonb_array_elements(public.invoice_preview_multi(test.biz(), array['b0000000-0000-0000-0000-000000000001']::uuid[])->'issues') x),
               'Kontrol ekranı faturalanmış teslimatı hata olarak gösterir');

-- Yenile: kendi teslimatlarını "faturalanmış" saymaz
select public.invoice_action(test.biz(), (select id from inv), 'yenile');
select test.ok(not exists (select 1 from public.invoices i, jsonb_array_elements(i.issues) x where i.id = (select id from inv) and x->>'message' like 'Zaten%'), 'Yenileme kendi teslimatını hata saymaz');

-- İptal → teslimatlar serbest, yeniden faturalanabilir
select public.invoice_action(test.biz(), (select id from inv), 'iptal', 'yanlış ay');
select test.eq(test.inv_sales((select id from inv)), 0, 'İptal edilen faturanın teslimatları serbest');
select test.eq((select count(*)::int from public.invoice_sales where invoice_id = (select id from inv)), 3, 'Bağlantı kaydı silinmez (izlenebilir)');
select test.ok(public.create_invoice(test.biz(), array['b0000000-0000-0000-0000-000000000001','b0000000-0000-0000-0000-000000000002']::uuid[], 'aylik') is not null, 'İptalden sonra yeniden faturalanır');
select test.throws($$update public.invoice_sales set active = true where invoice_id = (select id from inv)$$, '%', 'Bağlantı kaydı elle değiştirilemez');

-- Sevkiyat başına müşteri: her teslimat ayrı
select test.order_deliver('M001', 'a0000000-0000-0000-0000-000000000011', 'b0000000-0000-0000-0000-000000000011', 1);
select test.order_deliver('M001', 'a0000000-0000-0000-0000-000000000012', 'b0000000-0000-0000-0000-000000000012', 1);
select test.throws($$select public.create_invoice(test.biz(), array['b0000000-0000-0000-0000-000000000011','b0000000-0000-0000-0000-000000000012']::uuid[], 'aylik')$$,
                   '%sevkiyat başına%', 'Sevkiyat başına müşteride toplu fatura açılamaz');
select test.throws($$select public.create_invoice(test.biz(), array['b0000000-0000-0000-0000-000000000011','b0000000-0000-0000-0000-000000000012']::uuid[], 'teslimat')$$,
                   '%ayrı faturalanır%', 'Sevkiyat başına faturada tek teslimat');
create temp table i1 on commit drop as select public.create_invoice_draft(test.biz(), 'b0000000-0000-0000-0000-000000000011') as id;
create temp table i2 on commit drop as select public.create_invoice(test.biz(), array['b0000000-0000-0000-0000-000000000012']::uuid[], 'teslimat') as id;
select test.ok((select id from i1) <> (select id from i2) and test.inv_sales((select id from i1)) = 1 and test.inv_sales((select id from i2)) = 1,
               'Her teslimat ayrı fatura kaydında');
select test.eq((select sale_id from public.invoices where id = (select id from i1)), 'b0000000-0000-0000-0000-000000000011'::uuid, 'Tek teslimat faturası satışa bağlı');

-- Farklı müşteriler / farklı aylar birleşmez
select test.throws($$select public.create_invoice(test.biz(), array['b0000000-0000-0000-0000-000000000003','b0000000-0000-0000-0000-000000000011']::uuid[], 'aylik')$$,
                   '%aynı müşterinin%', 'Farklı müşterilerin teslimatı birleşmez');
select test.logout();
update public.sales set sold_at = sold_at - interval '40 days' where id = 'b0000000-0000-0000-0000-000000000001';
select test.login(test.u_admin());
select test.order_deliver('M002', 'a0000000-0000-0000-0000-000000000004', 'b0000000-0000-0000-0000-000000000004', 1);
-- 001 hâlâ ikinci faturada; 003 + 004 bu ay, geçmiş ay ile birleştirme denemesi:
select test.logout();
update public.sales set sold_at = sold_at - interval '40 days' where id = 'b0000000-0000-0000-0000-000000000003';
select test.login(test.u_admin());
select test.throws($$select public.create_invoice(test.biz(), array['b0000000-0000-0000-0000-000000000003','b0000000-0000-0000-0000-000000000004']::uuid[], 'aylik')$$,
                   '%aynı ayın%', 'Farklı ayların teslimatı birleşmez');

-- Eşik: aylık müşteride eşik üstü teslimat ayrı işaretlenir (varsayılan kapalı)
select test.eq((select (public.monthly_billing(test.biz(), app.local_date(now()))->>'split_qty')), null::text, 'Eşik varsayılan kapalı');
select public.set_invoice_split_qty(test.biz(), 70);
select test.order_deliver('M002', 'a0000000-0000-0000-0000-000000000005', 'b0000000-0000-0000-0000-000000000005', 70);
create temp table mb2 on commit drop as select public.monthly_billing(test.biz(), app.local_date(now())) as j;
select test.eq((select count(*)::int from mb2, jsonb_array_elements(j->'customers'->0->'sales') x where (x->>'over')::boolean), 1, '70 ve üstü teslimat eşik üstü işaretlenir');
select test.eq((select count(*)::int from mb2, jsonb_array_elements(j->'customers'->0->'sales') x where not (x->>'over')::boolean), 1, 'Küçük teslimat toplu faturaya kalır');
select test.ok((select jsonb_array_length(j->'pending_months') >= 2 from mb2), 'Bekleyen geçmiş aylar listelenir');
select test.ok(public.create_invoice(test.biz(), array['b0000000-0000-0000-0000-000000000005']::uuid[], 'teslimat') is not null, 'Eşik üstü teslimat ayrı faturalanır');

-- Gelir raporu: elle kesilen aylık fatura teslimatlarını faturalı sayar
select public.invoice_action(test.biz(), (select id from i1), 'elle_kesildi', 'ALK0000000000099');
select test.ok((public.profit_report(test.biz(), app.local_date(now()), app.local_date(now()), 'ay')->'periods'->0->>'income_invoiced')::numeric > 0,
               'Kesilen faturanın teslimatı faturalı gelir');
select test.login(test.u_satis());
select test.throws($$select public.monthly_billing(test.biz(), current_date)$$, '%yetkiniz yok%', 'Aylık fatura listesi yalnızca yönetici');
select test.eq((select count(*)::int from public.invoice_sales), 0, 'Personel fatura bağlantılarını görmez');
rollback;
