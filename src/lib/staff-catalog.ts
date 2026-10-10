import type { SupabaseClient } from "@supabase/supabase-js";
import type { CatalogUnit } from "@/lib/catalog";
import { productImageUrl, type ShopItem } from "@/lib/shop";

/** Mağaza düzeninden birimin yeri (W-13): satış ve sipariş ekranı müşteri ekranıyla aynı bölüm ve sırayı kullanır. */
export interface UnitLayout {
  popularity: number;
  sort: number | null;
  section: string | null;
  sectionRank: number | null;
  topRank: number | null;
}

/** Ürünün mağaza görünümü: mağazada gösterilen marka (yoksa kategoriye düşer), kategori, fotoğraf */
export interface ProductShopInfo {
  shopBrand: string | null;
  category: string | null;
  imagePath: string | null;
}

export async function loadUnitLayout(supabase: SupabaseClient, businessId: string): Promise<Record<string, UnitLayout>> {
  const { data, error } = await supabase.rpc("staff_catalog_layout", { p_business: businessId });
  if (error) return {}; // düzen okunamazsa otomatik bölümlerle devam
  const out: Record<string, UnitLayout> = {};
  for (const r of (data ?? []) as { unit_id: string; popularity: number | null; sort: number | null; section: string | null; section_rank: number | null; top_rank: number | null }[]) {
    out[r.unit_id] = { popularity: r.popularity ?? 0, sort: r.sort, section: r.section, sectionRank: r.section_rank, topRank: r.top_rank };
  }
  return out;
}

/** Ürün sorgusundaki ilişkilerden mağaza bilgisi */
export function shopInfo(p: { brands?: { name: string; show_in_shop?: boolean | null } | null; categories?: { name: string } | null; image_path?: string | null }): ProductShopInfo {
  return {
    shopBrand: p.brands && p.brands.show_in_shop !== false ? p.brands.name : null,
    category: p.categories?.name ?? null,
    imagePath: p.image_path ?? null,
  };
}

export interface StaffProduct extends ProductShopInfo {
  id: string;
  code: string;
  name: string;
  deposit: number | null;
  units: CatalogUnit[];
}

/**
 * Personel / bayi kataloğu (W-13): her fiyatlı birim bir kart. Fiyat müşteriye göre (özel fiyat > liste > perakende).
 * Müşteri ekranında gizlenen ürünler burada görünür. Birimin mağazadaki yeri `u.layout`tan gelir.
 */
export function staffItems<P extends StaffProduct>(
  products: P[],
  price: (u: CatalogUnit) => number | null,
  note?: (p: P, u: CatalogUnit) => { text: string; danger?: boolean } | null,
): ShopItem[] {
  const out: ShopItem[] = [];
  for (const p of products) {
    for (const u of p.units) {
      const pr = price(u);
      if (pr === null) continue;
      const l = u.layout;
      const n = note?.(p, u) ?? null;
      out.push({
        unitId: u.id,
        productId: p.id,
        productCode: p.code,
        productName: p.name,
        unitName: u.name,
        factor: u.factor,
        price: pr,
        hasDeposit: p.deposit !== null,
        brand: p.shopBrand,
        category: p.category,
        imageUrl: productImageUrl(p.imagePath),
        popularity: l?.popularity ?? 0,
        sort: l?.sort ?? null,
        section: l?.section ?? null,
        hidden: false,
        sectionRank: l?.sectionRank ?? null,
        topRank: l?.topRank ?? null,
        note: n?.text,
        noteDanger: n?.danger,
      });
    }
  }
  return out;
}
