-- Karton ve plastik bardak kartlarının sıfırlanması (kullanıcı 24.11, D-119)
-- Kullanıcı: tüm karton/plastik bardak kartlarını ve fiyatlarını sıfırla (kayıtları sil); firmaya özel fiyat yok;
-- adet birimi kalksın, yalnızca paket ve koli; her yerde aynı fiyat:
--   Karton Bardak Paket (50'li) 60 TL, Koli (60 paket) 2.400 TL
--   Plastik Bardak Paket (100'lü) 60 TL, Koli (30 paket) 1.400 TL
-- Yapılan:
--   • Bardak birimlerinin tüm fiyat kayıtları silinir (gel al geçmişi, bayi/palet/ev/kurumsal liste fiyatları,
--     firmaya özel fiyatlar, barkod, mağaza düzeni) ve birimler silinip yeniden açılır. Satış/sipariş kaydı yoktu.
--   • Karton Bardak 100'lü (EN-KBARDAK100, hiç hareketi yok) tamamen silinir.
--   • Eski Plastik Bardak (EN-PBARDAK) stok hareketi geçmişi olduğu için silinmez; pasif ve stoğu 0.
--   • Fiyat tüm listelerde aynı yazılır (yoksa eve teslim gel al + 40, kurumsal × 1,5 olurdu).
--   • Plastik bardağın temel birimi adetten pakete geçer: stok 6.000 adet → 200 paket (eski kartın sayımı).
-- Satış/sipariş/sayım satırı bağlıysa işlem durur (hiçbir şey değişmez).
begin;

do $$
declare
  v_bid uuid; v_k uuid; v_p uuid; v_k100 uuid; v_loc uuid; v_qty int;
  v_units uuid[]; fk record; v_n bigint; v_u uuid;
  c_allowed text[] := array['customer_prices', 'product_list_prices', 'product_prices', 'product_barcodes', 'shop_items',
                            'product_costs', 'cost_history', 'customer_deposits', 'stock_levels', 'product_units'];
  r record;
begin
  select id, business_id into v_k, v_bid from public.products where code = 'EN-KBARDAK';
  select id into v_p from public.products where code = 'PB001' and business_id = v_bid;
  select id into v_k100 from public.products where code = 'EN-KBARDAK100' and business_id = v_bid;
  if v_k is null or v_p is null then raise exception 'Bardak kartları bulunamadı'; end if;
  if v_k100 is not null and exists (select 1 from public.stock_movements where product_id = v_k100) then
    raise exception 'EN-KBARDAK100 stok hareketi var, silinemez';
  end if;

  -- 1) Silinecek birimler: iki kartın tüm birimleri + 100'lü kartın birimleri
  select array_agg(id) into v_units from public.product_units where product_id in (v_k, v_p, v_k100);

  -- Birimlere bağlı tablolar: yalnızca fiyat/düzen kayıtları silinir, başka bağ varsa dur
  for fk in
    select c.conrelid::regclass::text tbl, a.attname col
      from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
     where c.contype = 'f' and c.confrelid = 'public.product_units'::regclass
  loop
    execute format('select count(*) from %s where %I = any($1)', fk.tbl, fk.col) into v_n using v_units;
    if v_n > 0 then
      if replace(fk.tbl, 'public.', '') = any(c_allowed) then
        execute format('delete from %s where %I = any($1)', fk.tbl, fk.col) using v_units;
      else
        raise exception 'Birim % tablosunda kullanılıyor (% satır), silinemez', fk.tbl, v_n;
      end if;
    end if;
  end loop;
  delete from public.product_units where id = any(v_units);

  -- 2) Karton Bardak 100'lü kartı: ürüne bağlı kayıtlar (yalnızca izinli tablolar) ve kart
  if v_k100 is not null then
    for fk in
      select c.conrelid::regclass::text tbl, a.attname col
        from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
       where c.contype = 'f' and c.confrelid = 'public.products'::regclass
    loop
      execute format('select count(*) from %s where %I = $1', fk.tbl, fk.col) into v_n using v_k100;
      if v_n > 0 then
        if replace(fk.tbl, 'public.', '') = any(c_allowed) then
          execute format('delete from %s where %I = $1', fk.tbl, fk.col) using v_k100;
        else
          raise exception 'EN-KBARDAK100 % tablosunda kullanılıyor (% satır), silinemez', fk.tbl, v_n;
        end if;
      end if;
    end loop;
    delete from public.products where id = v_k100;
  end if;

  -- 3) Kartları yeniden kur: temel birim paket, ek birim koli; fiyat her listede aynı
  update public.products set name = 'Karton Bardak', base_unit_name = 'Paket (50)', active = true, updated_at = now() where id = v_k;
  update public.products set name = 'Plastik Bardak', base_unit_name = 'Paket (100)', active = true, updated_at = now() where id = v_p;

  for r in select * from (values
      (v_k, 'Paket (50)', 1, true, 0, 60::numeric),
      (v_k, 'Koli (60 paket)', 60, false, 1, 2400::numeric),
      (v_p, 'Paket (100)', 1, true, 0, 60::numeric),
      (v_p, 'Koli (30 paket)', 30, false, 1, 1400::numeric)) t(product_id, name, factor, is_base, sort, price)
  loop
    insert into public.product_units(business_id, product_id, name, factor, is_base, sort)
    values (v_bid, r.product_id, r.name, r.factor, r.is_base, r.sort) returning id into v_u;
    perform app.set_unit_price(v_u, r.price, 'manuel');
    insert into public.product_list_prices(unit_id, business_id, price_list, price)
    select v_u, v_bid, l, r.price from unnest(array['bayi', 'palet', 'ev', 'kurumsal']) l;
    insert into public.product_prices(business_id, unit_id, price, source, price_list)
    select v_bid, v_u, r.price, 'manuel', l from unnest(array['bayi', 'palet', 'ev', 'kurumsal']) l;
  end loop;

  -- 4) Plastik bardak stoğu: temel birim adet → paket; 6.000 adet = eski kartın 200 paketi
  select count(*) into v_n from public.stock_levels where product_id = v_p and qty <> 0;
  if v_n <> 1 then raise exception 'PB001 stoğu tek depoda değil (%)', v_n; end if;
  select location_id, qty into v_loc, v_qty from public.stock_levels where product_id = v_p and qty <> 0;
  if v_qty <> 6000 then raise exception 'PB001 stoğu 6000 değil (%)', v_qty; end if;
  perform app.post_stock(v_bid, v_loc, v_p, 200 - v_qty, 'sayim_duzeltme', 'birim_degisikligi', null,
                         'Temel birim adetten pakete (100''lü) geçti: 6.000 adet kaydı → 200 paket (eski kart sayımı)');

  perform app.audit(v_bid, 'bardak_sifirlama', 'products', v_p::text, null,
    jsonb_build_object('karton', 'Paket (50) 60, Koli (60 paket) 2400', 'plastik', 'Paket (100) 60, Koli (30 paket) 1400',
                       'silinen', 'EN-KBARDAK100 ve tüm bardak fiyat/özel fiyat kayıtları', 'pb001_stok', '6000 adet → 200 paket'));
end $$;

select 'SONUC: ' || string_agg(p.code || ' ' || p.name || ' [' || u.name || ' f' || u.factor || ' gelal=' || u.price
       || ' liste=' || (select string_agg(lp.price_list || ':' || lp.price, ',' order by lp.price_list) from public.product_list_prices lp where lp.unit_id = u.id)
       || ' ozel=' || (select count(*) from public.customer_prices cp where cp.unit_id = u.id) || ']'
       || ' stok=' || coalesce((select sum(qty) from public.stock_levels l where l.product_id = p.id), 0), ' ; ' order by p.code, u.factor)
    || ' | k100=' || (select count(*) from public.products where code = 'EN-KBARDAK100') as sonuc
  from public.products p join public.product_units u on u.product_id = p.id
 where p.code in ('EN-KBARDAK', 'PB001');
commit;
