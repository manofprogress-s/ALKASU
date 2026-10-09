import { SUPABASE_URL } from "@/lib/env";

/** Müşteri sipariş ekranındaki (mağaza) bir satılabilir birim. Kaynak: public_catalog() (D-069). */
export interface ShopItem {
  unitId: string;
  productId: string;
  productCode: string;
  productName: string;
  unitName: string;
  factor: number;
  price: number;
  hasDeposit: boolean;
  brand: string | null;
  category: string | null;
  imageUrl: string | null;
  popularity: number;
}

export interface CatalogRow {
  product_id: string;
  product_name: string;
  unit_id: string;
  unit_name: string;
  factor: number;
  price: number | string;
  has_deposit: boolean;
  product_code?: string | null;
  brand_name?: string | null;
  category_name?: string | null;
  image_path?: string | null;
  popularity?: number | null;
}

export const PRODUCT_IMAGE_BUCKET = "urun";

export function productImageUrl(path: string | null | undefined): string | null {
  return path ? `${SUPABASE_URL}/storage/v1/object/public/${PRODUCT_IMAGE_BUCKET}/${path}` : null;
}

export function toShopItems(rows: CatalogRow[]): ShopItem[] {
  return rows.map((r) => ({
    unitId: r.unit_id,
    productId: r.product_id,
    productCode: r.product_code ?? "",
    productName: r.product_name,
    unitName: r.unit_name,
    factor: r.factor,
    price: Number(r.price),
    hasDeposit: r.has_deposit,
    brand: r.brand_name ?? null,
    category: r.category_name ?? null,
    imageUrl: productImageUrl(r.image_path),
    popularity: r.popularity ?? 0,
  }));
}

export type ProductKind = "damacana" | "sise" | "bidon" | "bardak" | "soda" | "pompa" | "epompa" | "tup" | "kutu";

/** Fotoğrafı olmayan ürün için çizim türü (ad, birim ve kategoriden) */
export function productKind(i: Pick<ShopItem, "productName" | "unitName" | "category">): ProductKind {
  const n = `${i.productName} ${i.unitName}`.toLocaleLowerCase("tr-TR");
  const c = (i.category ?? "").toLocaleLowerCase("tr-TR");
  if (/pompa/.test(n)) return /elektrik|otomatik|şarjlı/.test(n) ? "epompa" : "pompa";
  if (/tüp/.test(n) || c === "tüp") return "tup";
  if (/damacana|19 ?l\b/.test(n)) return "damacana";
  if (/bardak su/.test(n)) return "bardak";
  if (/bardak/.test(n)) return "kutu";
  if (/maden|soda/.test(n) || /maden/.test(c)) return "soda";
  if (/(^|[^\d,.])5 ?l\b|bidon/.test(n)) return "bidon"; // "1,5 L" bidon değildir
  if (/\bsu\b|\b\d+([,.]\d+)? ?l\b/.test(n) || c === "su") return "sise";
  return "kutu";
}

const KIND_ORDER: ProductKind[] = ["damacana", "sise", "bidon", "bardak", "soda", "pompa", "epompa", "tup", "kutu"];

/** Ürün adından marka önekini atar: "Gürpınar 1,5 L Su" → "1,5 L Su" */
export function shortName(i: Pick<ShopItem, "productName" | "brand">): string {
  if (i.brand && i.productName.toLocaleLowerCase("tr-TR").startsWith(i.brand.toLocaleLowerCase("tr-TR") + " ")) {
    return i.productName.slice(i.brand.length + 1);
  }
  return i.productName;
}

/** Birim açıklaması: "Paket · 6 adet" */
export function unitLabel(i: Pick<ShopItem, "unitName" | "factor">): string {
  return i.factor > 1 ? `${i.unitName} · ${i.factor} adet` : i.unitName;
}

export interface ShopSection {
  key: string;
  title: string;
  items: ShopItem[];
}

function sortItems(items: ShopItem[]): ShopItem[] {
  return [...items].sort(
    (a, b) =>
      KIND_ORDER.indexOf(productKind(a)) - KIND_ORDER.indexOf(productKind(b)) ||
      b.popularity - a.popularity ||
      a.productName.localeCompare(b.productName, "tr"),
  );
}

/**
 * Bölümler (W-08): önce markalar (en çok ürünü olan önce), sonra son 60 günün çok satanları,
 * sonra markasız ürünler kategoriye göre.
 */
export function buildSections(items: ShopItem[], topCount = 6): ShopSection[] {
  const byBrand = new Map<string, ShopItem[]>();
  const byCat = new Map<string, ShopItem[]>();
  for (const i of items) {
    if (i.brand) byBrand.set(i.brand, [...(byBrand.get(i.brand) ?? []), i]);
    else byCat.set(i.category ?? "Diğer", [...(byCat.get(i.category ?? "Diğer") ?? []), i]);
  }
  const brands = [...byBrand.entries()]
    .sort((a, b) => b[1].length - a[1].length || a[0].localeCompare(b[0], "tr"))
    .map(([b, list]) => ({ key: `b:${b}`, title: `${b} çeşitleri`, items: sortItems(list) }));
  const top = [...items].filter((i) => i.popularity > 0).sort((a, b) => b.popularity - a.popularity).slice(0, topCount);
  const cats = [...byCat.entries()]
    .sort((a, b) => a[0].localeCompare(b[0], "tr"))
    .map(([c, list]) => ({ key: `c:${c}`, title: c, items: sortItems(list) }));
  return [...brands, ...(top.length ? [{ key: "top", title: "Çok satanlar", items: top }] : []), ...cats];
}

const BRAND_COLORS: Record<string, string> = {
  "gürpınar": "#1f6fd6",
  "fuska": "#d9367a",
  "kızılay": "#d3262e",
  "beypazarı": "#1d8a48",
};

/** Çizimdeki vurgu rengi (markaya göre; logo değil, yalnızca renk) */
export function brandColor(brand: string | null): string {
  return (brand && BRAND_COLORS[brand.toLocaleLowerCase("tr-TR")]) || "#0a6fb8";
}
