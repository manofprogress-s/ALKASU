-- 09.10.2026 yayını: müşteri sipariş ekranı (0018). Tek işlem.
begin;
-- ALKASU 0018 — Müşteri sipariş ekranı (mağaza): ürün fotoğrafı, marka bölümleri, çok satanlar
-- Kural: BUSINESS_RULES §20 (W-08..W-10) · Karar: D-069..D-071

-- Marka bölümü: "Envanter" gibi genel markalar mağazada bölüm açmaz, ürünleri kategoriye göre listelenir
alter table public.brands add column if not exists show_in_shop boolean not null default true;
update public.brands set show_in_shop = false where name = 'Envanter';

-- Ürün fotoğrafı: Supabase Storage "urun" kovasında <işletme>/<dosya> yolu
alter table public.products add column if not exists image_path text
  check (image_path is null or (length(image_path) between 3 and 200 and image_path ~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]+$'));

-- Yönetici: ürün fotoğrafını bağlar / kaldırır (null). Dosya kendi işletme klasöründe olmalı.
create or replace function public.set_product_image(p_product uuid, p_path text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bid uuid; v_old text;
begin
  select business_id, image_path into v_bid, v_old from public.products where id = p_product;
  if v_bid is null then raise exception 'Ürün bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(v_bid, 'yonetici');
  if p_path is not null and (split_part(p_path, '/', 1) <> v_bid::text or p_path !~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]+$') then
    raise exception 'Geçersiz dosya yolu' using errcode = '22023';
  end if;
  update public.products set image_path = p_path, updated_at = now() where id = p_product;
  perform app.audit(v_bid, 'urun_gorseli', 'products', p_product::text,
                    jsonb_build_object('image_path', v_old), jsonb_build_object('image_path', p_path));
end $$;

-- Herkese açık katalog: bölüm (marka/kategori), fotoğraf ve son 60 günün satış adedi (çok satanlar)
drop function if exists public.public_catalog();
create or replace function public.public_catalog()
returns table(product_id uuid, product_name text, unit_id uuid, unit_name text, factor integer, price numeric, has_deposit boolean,
              product_code text, brand_name text, category_name text, image_path text, popularity integer)
language sql stable security definer set search_path = public, pg_temp as $$
  select p.id, p.name, u.id, u.name, u.factor, u.price, p.deposit_amount is not null,
         p.code, case when b.show_in_shop then b.name end, c.name, p.image_path,
         coalesce((select sum(si.qty)::int from public.sale_items si join public.sales s on s.id = si.sale_id
                    where si.unit_id = u.id and s.status = 'tamamlandi' and s.sold_at > now() - interval '60 days'), 0)
    from public.products p
    join public.product_units u on u.product_id = p.id
    left join public.brands b on b.id = p.brand_id
    left join public.categories c on c.id = p.category_id
   where p.business_id = app.public_business() and p.active and not p.is_container and u.active and u.price is not null
   order by p.name, u.factor desc
$$;

-- Storage kovası ve yetkiler (yalnızca Supabase'de; yerel testte storage şeması yoktur)
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
    values ('urun', 'urun', true, 1048576, array['image/webp', 'image/jpeg', 'image/png'])
    on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
    execute 'drop policy if exists urun_yonetici_ekle on storage.objects';
    execute 'drop policy if exists urun_yonetici_guncelle on storage.objects';
    execute 'drop policy if exists urun_yonetici_sil on storage.objects';
    execute 'drop policy if exists urun_yonetici_oku on storage.objects';
    execute $p$create policy urun_yonetici_oku on storage.objects for select to authenticated
      using (bucket_id = 'urun' and app.has_role(((storage.foldername(name))[1])::uuid, 'yonetici'))$p$;
    execute $p$create policy urun_yonetici_ekle on storage.objects for insert to authenticated
      with check (bucket_id = 'urun' and app.has_role(((storage.foldername(name))[1])::uuid, 'yonetici'))$p$;
    execute $p$create policy urun_yonetici_guncelle on storage.objects for update to authenticated
      using (bucket_id = 'urun' and app.has_role(((storage.foldername(name))[1])::uuid, 'yonetici'))$p$;
    execute $p$create policy urun_yonetici_sil on storage.objects for delete to authenticated
      using (bucket_id = 'urun' and app.has_role(((storage.foldername(name))[1])::uuid, 'yonetici'))$p$;
  end if;
end $$;

select app.apply_grants();
insert into supabase_migrations.schema_migrations(version, name) values ('20261009001800', 'shop') on conflict do nothing;
commit;
select (select count(*) from public.public_catalog()) as katalog, (select count(distinct brand_name) from public.public_catalog()) as marka, (select count(*) from public.brands where not show_in_shop) as gizli_marka;
