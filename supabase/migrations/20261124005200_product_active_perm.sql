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
