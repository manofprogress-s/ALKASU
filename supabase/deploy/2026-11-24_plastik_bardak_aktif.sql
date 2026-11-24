-- Plastik Bardak (PB001) aktifleştirme (kullanıcı 24.11, D-116)
-- Ürün 24.11 13:05'te pasif kaydedilmişti (işlem geçmişi: insert active=false); pasif ürün satış, sipariş,
-- mağaza ve özel fiyat ekranlarında görünmez. Fiyatlar zaten girili (Adet 50, Paket(30) 1250).
begin;

do $$
declare v_p uuid; v_bid uuid; v_active boolean;
begin
  select id, business_id, active into v_p, v_bid, v_active from public.products where code = 'PB001';
  if v_p is null then raise exception 'PB001 bulunamadı'; end if;
  if v_active then raise exception 'PB001 zaten aktif'; end if;
  update public.products set active = true, updated_at = now() where id = v_p;
  perform app.audit(v_bid, 'urun_guncelle', 'products', v_p::text,
    jsonb_build_object('active', false), jsonb_build_object('active', true, 'neden', 'yanlışlıkla pasif kaydedilmiş (D-116)'));
end $$;

select 'SONUC: ' || string_agg(p.code || ' aktif=' || p.active || ' ' || u.name || '=' || coalesce(u.price::text, '-'), ' ; ' order by p.code, u.factor) as sonuc
  from public.products p join public.product_units u on u.product_id = p.id and u.active
 where p.code = 'PB001';
commit;
