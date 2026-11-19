-- Karton bardak: 50'li ve 100'lü paket ayrı ürün (kullanıcı 19.11, D-107)
-- 50'li: mevcut EN-KBARDAK (stok 57 paket 50'li kabul edildi) → ad "Karton Bardak 50'li", birim "Paket (50)", gel al 80, bayi 70
-- 100'lü: yeni EN-KBARDAK100 → "Karton Bardak 100'lü", birim "Paket (100)", gel al 150, bayi 135, stok 0
-- Eve teslim / kurumsal boş bırakıldı (kural: gel al + 40 / gel al × 1,5). Fiyatlar fiyat geçmişine yazılır.
begin;

do $$
declare v_p50 uuid; v_bid uuid; v_u50 uuid; v_p100 uuid; v_u100 uuid;
begin
  select id, business_id into v_p50, v_bid from public.products where code = 'EN-KBARDAK';
  if v_p50 is null then raise exception 'EN-KBARDAK bulunamadı'; end if;
  if exists (select 1 from public.products where code = 'EN-KBARDAK100') then raise exception 'EN-KBARDAK100 zaten var'; end if;
  select id into v_u50 from public.product_units where product_id = v_p50 and is_base;

  -- 50'li paket
  update public.products set name = 'Karton Bardak 50''li', base_unit_name = 'Paket (50)', updated_at = now() where id = v_p50;
  update public.product_units set name = 'Paket (50)' where id = v_u50;
  perform app.set_unit_price(v_u50, 80, 'manuel');
  insert into public.product_list_prices(unit_id, business_id, price_list, price) values (v_u50, v_bid, 'bayi', 70)
    on conflict (unit_id, price_list) do update set price = excluded.price, updated_at = now();
  insert into public.product_prices(business_id, unit_id, price, source, price_list) values (v_bid, v_u50, 70, 'manuel', 'bayi');

  -- 100'lü paket (marka, kategori, KDV 50'liden)
  insert into public.products(business_id, code, name, brand_id, category_id, base_unit_name, vat_rate, critical_level, image_path)
  select business_id, 'EN-KBARDAK100', 'Karton Bardak 100''lü', brand_id, category_id, 'Paket (100)', vat_rate, critical_level, image_path
    from public.products where id = v_p50
  returning id into v_p100;
  insert into public.product_units(business_id, product_id, name, factor, is_base, sort)
  values (v_bid, v_p100, 'Paket (100)', 1, true, 0) returning id into v_u100;
  insert into public.product_costs(product_id, business_id) values (v_p100, v_bid);
  perform app.set_unit_price(v_u100, 150, 'manuel');
  insert into public.product_list_prices(unit_id, business_id, price_list, price) values (v_u100, v_bid, 'bayi', 135);
  insert into public.product_prices(business_id, unit_id, price, source, price_list) values (v_bid, v_u100, 135, 'manuel', 'bayi');

  perform app.audit(v_bid, 'urun_guncelle', 'products', v_p50::text,
    jsonb_build_object('name', 'Karton Bardak', 'unit', 'Paket'),
    jsonb_build_object('name', 'Karton Bardak 50''li', 'unit', 'Paket (50)', 'gel_al', 80, 'bayi', 70));
  perform app.audit(v_bid, 'urun_ekle', 'products', v_p100::text, null,
    jsonb_build_object('code', 'EN-KBARDAK100', 'name', 'Karton Bardak 100''lü', 'gel_al', 150, 'bayi', 135));
end $$;

select 'SONUC: ' || string_agg(p.code || '=' || p.name || ' ' || u.name || ' gelal ' || u.price || ' bayi ' ||
       coalesce((select lp.price::text from public.product_list_prices lp where lp.unit_id = u.id and lp.price_list = 'bayi'), '-'), ' ; ' order by p.code) as sonuc
  from public.products p join public.product_units u on u.product_id = p.id and u.is_base
 where p.code in ('EN-KBARDAK', 'EN-KBARDAK100');
commit;
