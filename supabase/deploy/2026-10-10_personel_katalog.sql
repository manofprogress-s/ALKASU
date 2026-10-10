-- 10.10.2026 yayını: satış/sipariş ekranı mağaza düzeni okuma (0026). Yalnızca yeni fonksiyon, mevcut veriye dokunmaz.
begin;
-- ALKASU 0026 — Satış ve sipariş ekranında mağaza düzeni: personel ve bayi, müşteri ekranındaki bölümleri/sırayı görür
-- Kural: BUSINESS_RULES §20 (W-13) · Karar: D-086
-- Yalnızca okuma: ürünün bölümü, bölüm içi sıra, bölüm sırası ve son 60 günün satış adedi (çok satanlar).
-- Müşteri ekranından gizlenen ürünler personelde gizlenmez (satışta her ürün satılabilmeli).

create or replace function public.staff_catalog_layout(p_business uuid)
returns table(unit_id uuid, popularity integer, sort integer, section text, section_rank integer, top_rank integer)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform app.require_role(p_business, 'yonetici', 'satis', 'depo', 'sevkiyat', 'izleyici', 'bayi', 'musteri');
  return query select c.unit_id, c.popularity, c.sort, c.section, c.section_rank, c.top_rank
                 from app.shop_catalog(p_business, true) c;
end $$;

select app.apply_grants();
select 'SONUC: staff_catalog_layout hazır' as sonuc;
commit;
