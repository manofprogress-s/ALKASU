-- 10.10.2026 yayını: hız adımı 4 — eksik indeksler (0021). Tek işlem, veri değişmez.
begin;
-- ALKASU 0021 — Hız adımı 4: veri büyüdükçe yavaşlamasın diye eksik yabancı anahtar indeksleri
-- Karar: D-079. Yalnızca sık okunan / birleştirilen ve büyüyecek tablolar seçildi; davranış değişmez.
create index if not exists container_ledger_customer   on public.container_ledger(customer_id);
create index if not exists container_ledger_product    on public.container_ledger(product_id);
create index if not exists container_returns_customer  on public.container_returns(customer_id);
create index if not exists container_returns_session   on public.container_returns(session_id);
create index if not exists customer_payments_session   on public.customer_payments(session_id);
create index if not exists expenses_session            on public.expenses(session_id);
create index if not exists returns_session             on public.returns(session_id);
create index if not exists return_items_return         on public.return_items(return_id);
create index if not exists return_payments_return      on public.return_payments(return_id);
create index if not exists return_requests_sale        on public.return_requests(sale_id);
create index if not exists sale_items_unit             on public.sale_items(unit_id);      -- çok satanlar (public_catalog)
create index if not exists order_items_product         on public.order_items(product_id);
create index if not exists orders_sale                 on public.orders(sale_id) where sale_id is not null;
create index if not exists purchase_items_product      on public.purchase_items(product_id);
create index if not exists purchase_empties_purchase   on public.purchase_empties(purchase_id);
create index if not exists purchases_supplier          on public.purchases(supplier_id);
create index if not exists product_units_business      on public.product_units(business_id);
create index if not exists product_list_prices_business on public.product_list_prices(business_id);
create index if not exists product_barcodes_product    on public.product_barcodes(product_id);
create index if not exists stock_count_lines_product   on public.stock_count_lines(product_id);
create index if not exists waste_records_product       on public.waste_records(product_id);
create index if not exists memberships_customer        on public.memberships(customer_id) where customer_id is not null;
create index if not exists cash_movements_business     on public.cash_movements(business_id);
insert into supabase_migrations.schema_migrations(version, name) values ('20261010002100', 'perf_indexes') on conflict do nothing;
commit;
select 'SONUC: surum=' || (select max(version) from supabase_migrations.schema_migrations) || ' indeks=' || (select count(*) from pg_indexes where schemaname='public') as sonuc;
