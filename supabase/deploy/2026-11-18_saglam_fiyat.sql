-- Sağlam Ticaret (B001) özel fiyatları ve depozitosu + basma pompa gel al fiyatı (kullanıcı 18.11, D-105)
-- Önce 2026-11-18_bayi_arama.sql (0046: customer_deposits) çalışmış olmalı.
-- Kişisel veri yok; yalnızca ürün kodu ve fiyat. Her değişiklik işlem geçmişine yazılır.
begin;

do $$
declare
  v_cust uuid; v_bid uuid; r record; v_old numeric; n_price int := 0; n_dep int := 0;
begin
  select id, business_id into v_cust, v_bid from public.customers where code = 'B001' and channel = 'bayi' and name ilike 'Sağlam Ticaret%';
  if v_cust is null then raise exception 'Sağlam Ticaret (B001) bulunamadı'; end if;

  -- 1) Özel fiyatlar (birim başına, KDV dahil). Pet: gel al − 5 TL.
  for r in
    with want(code, price) as (values
      ('DM-GP', 78), ('DM-FS', 78),                                         -- damacana (standart, 80'lik markalar)
      ('BP-SADE', 240),
      ('BP-LIMON', 285), ('BP-ELMA', 285),
      ('BP-KCILEK', 295), ('BP-MANGO', 295), ('BP-KARADUT', 295),
      ('TP-B', 1400), ('TP-K', 300))
    select u.id as unit_id, p.code, w.price::numeric as price
      from want w join public.products p on p.business_id = v_bid and p.code = w.code
      join public.product_units u on u.product_id = p.id and u.active and u.price is not null
    union all
    select u.id, p.code, u.price - 5
      from public.products p join public.product_units u on u.product_id = p.id and u.active and u.price is not null
     where p.business_id = v_bid and p.code in ('FS-033','FS-05','FS-1','FS-15','FS-5','GP-033','GP-05','GP-15','GP-5','GP-19PET',
                                                'KZ-033','KZ-05','KZ-1','KZ-15','KZ-5')
  loop
    select price into v_old from public.customer_prices where customer_id = v_cust and unit_id = r.unit_id;
    insert into public.customer_prices(customer_id, unit_id, business_id, price)
    values (v_cust, r.unit_id, v_bid, r.price)
    on conflict (customer_id, unit_id) do update set price = excluded.price, updated_at = now();
    perform app.audit(v_bid, 'ozel_fiyat', 'customer_prices', v_cust::text,
                      jsonb_build_object('unit_id', r.unit_id, 'price', v_old), jsonb_build_object('unit_id', r.unit_id, 'price', r.price, 'kod', r.code));
    n_price := n_price + 1;
  end loop;

  -- 2) Özel depozito: büyük tüp 400, küçük tüp 300
  for r in
    select p.id as product_id, p.code, d.amount::numeric as amount
      from (values ('TP-B', 400), ('TP-K', 300)) d(code, amount)
      join public.products p on p.business_id = v_bid and p.code = d.code and p.deposit_amount is not null
  loop
    select amount into v_old from public.customer_deposits where customer_id = v_cust and product_id = r.product_id;
    insert into public.customer_deposits(customer_id, product_id, business_id, amount)
    values (v_cust, r.product_id, v_bid, r.amount)
    on conflict (customer_id, product_id) do update set amount = excluded.amount, updated_at = now();
    perform app.audit(v_bid, 'ozel_depozito', 'customer_deposits', v_cust::text,
                      jsonb_build_object('product_id', r.product_id, 'amount', v_old), jsonb_build_object('product_id', r.product_id, 'amount', r.amount, 'kod', r.code));
    n_dep := n_dep + 1;
  end loop;

  -- 3) Basma pompa gel al fiyatı 150 → 160 (herkes; fiyat geçmişine yazılır)
  for r in
    select u.id as unit_id, u.price as old from public.products p join public.product_units u on u.product_id = p.id and u.active and u.price is not null
     where p.business_id = v_bid and p.code = 'EN-BPOMPA'
  loop
    perform app.set_unit_price(r.unit_id, 160, 'manuel');
    perform app.audit(v_bid, 'fiyat', 'product_units', r.unit_id::text, jsonb_build_object('price', r.old), jsonb_build_object('price', 160));
  end loop;

  if n_price <> 25 or n_dep <> 2 then
    raise exception 'Beklenmeyen sayı: fiyat % (25 bekleniyor), depozito % (2 bekleniyor)', n_price, n_dep;
  end if;
end $$;

select 'SONUC: ozel_fiyat=' || (select count(*) from public.customer_prices cp join public.customers c on c.id = cp.customer_id where c.code = 'B001')
    || ' | ozel_depozito=' || (select count(*) from public.customer_deposits cd join public.customers c on c.id = cd.customer_id where c.code = 'B001')
    || ' | damacana=' || (select cp.price from public.customer_prices cp join public.customers c on c.id = cp.customer_id
                            join public.product_units u on u.id = cp.unit_id join public.products p on p.id = u.product_id
                           where c.code = 'B001' and p.code = 'DM-GP' limit 1)
    || ' | pompa=' || (select u.price from public.product_units u join public.products p on p.id = u.product_id
                        where p.code = 'EN-BPOMPA' and u.price is not null limit 1) as sonuc;
commit;
