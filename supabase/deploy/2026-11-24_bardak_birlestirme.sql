-- 24.11 (D-117): EN-PBARDAK stoğu PB001'e aktarılır + ürün aktif/pasif yetkisi (0052)
-- Kullanıcı: "They are same product" — eski EN-PBARDAK (Paket, fiyatsız, 200 paket) = Plastik Bardak PB001 (Paket = 30 adet).
-- Stok hareketleri silinmez: EN-PBARDAK −200 paket, PB001 +6.000 adet (sayım düzeltme, ref urun_birlestirme).
-- Kullanıcı isteğiyle EN-PBARDAK pasife alınmaz; Hüseyin gerekirse Ürünler'den pasife alır.
begin;

-- 0052: ürün aktif/pasif — yönetici veya özel fiyat yetkilisi (kullanıcı 24.11, D-117, F-41)
-- Hüseyin (sevkiyat, can_price) ürün kartlarını düzenleyemez ama yinelenen/kullanılmayan ürünü pasife alıp geri açabilir.
create or replace function public.set_product_active(p_product uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare p public.products;
begin
  select * into p from public.products where id = p_product;
  if p.id is null then raise exception 'Ürün bulunamadı' using errcode = 'P0002'; end if;
  if not app.can_price(p.business_id) then
    raise exception 'Ürünü aktif/pasif yapmak için özel fiyat yetkisi gerekir' using errcode = '42501';
  end if;
  if p.active = coalesce(p_active, true) then return; end if;
  update public.products set active = coalesce(p_active, true), updated_at = now() where id = p_product;
  perform app.audit(p.business_id, 'urun_aktiflik', 'products', p_product::text,
                    jsonb_build_object('active', p.active), jsonb_build_object('active', coalesce(p_active, true), 'kod', p.code));
end $$;

select app.apply_grants();

do $$
declare v_old uuid; v_new uuid; v_bid uuid; v_loc uuid; v_qty int; v_f int; v_ref uuid := gen_random_uuid(); v_n int;
begin
  select id, business_id into v_old, v_bid from public.products where code = 'EN-PBARDAK';
  select id into v_new from public.products where code = 'PB001' and business_id = v_bid and active;
  if v_old is null or v_new is null then raise exception 'Ürünler bulunamadı'; end if;
  select factor into v_f from public.product_units where product_id = v_new and active and name = 'Paket';
  if v_f is distinct from 30 then raise exception 'PB001 paket çarpanı 30 değil (%)', v_f; end if;
  select count(*) into v_n from public.stock_levels where product_id = v_old and qty <> 0;
  if v_n <> 1 then raise exception 'EN-PBARDAK stoğu tek depoda değil (%)', v_n; end if;
  select location_id, qty into v_loc, v_qty from public.stock_levels where product_id = v_old and qty <> 0;
  if v_qty <> 200 then raise exception 'EN-PBARDAK stoğu 200 değil (%)', v_qty; end if;

  perform app.post_stock(v_bid, v_loc, v_old, -v_qty, 'sayim_duzeltme', 'urun_birlestirme', v_ref,
                         'Plastik Bardak PB001''e aktarıldı (aynı ürün, 200 paket)');
  perform app.post_stock(v_bid, v_loc, v_new, v_qty * v_f, 'sayim_duzeltme', 'urun_birlestirme', v_ref,
                         'EN-PBARDAK''tan aktarıldı: 200 paket × 30 adet');
  perform app.audit(v_bid, 'urun_birlestirme', 'products', v_new::text,
    jsonb_build_object('EN-PBARDAK', v_qty, 'PB001', 0),
    jsonb_build_object('EN-PBARDAK', 0, 'PB001_adet', v_qty * v_f, 'ref', v_ref));
end $$;

select 'SONUC: fn=' || (select count(*) from pg_proc where proname = 'set_product_active')
    || ' | ENP=' || coalesce((select sum(l.qty) from public.stock_levels l join public.products p on p.id = l.product_id where p.code = 'EN-PBARDAK'), 0)
    || ' | PB001=' || coalesce((select sum(l.qty) from public.stock_levels l join public.products p on p.id = l.product_id where p.code = 'PB001'), 0)
    || ' | pasif=' || (select count(*) from public.products where not active) as sonuc;
commit;
