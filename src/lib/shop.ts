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
  /** Mağaza düzeni (W-11): bölüm içi sıra, elle verilen bölüm, gizli */
  sort: number | null;
  section: string | null;
  hidden: boolean;
  /** Bölümün elle verilen sırası (W-12); boş = otomatik */
  sectionRank: number | null;
  /** "Çok satanlar" bölümünün sırası (W-12) */
  topRank: number | null;
  /** Personel ekranında kartın altındaki küçük bilgi (ör. stok) (W-13) */
  note?: string;
  noteDanger?: boolean;
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
  sort?: number | null;
  section?: string | null;
  hidden?: boolean | null;
  section_rank?: number | null;
  top_rank?: number | null;
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
    sort: r.sort ?? null,
    section: r.section ?? null,
    hidden: !!r.hidden,
    sectionRank: r.section_rank ?? null,
    topRank: r.top_rank ?? null,
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
      // Elle verilen sıra önce (W-11), sonra otomatik: tür, satış, ad
      (a.sort ?? Number.MAX_SAFE_INTEGER) - (b.sort ?? Number.MAX_SAFE_INTEGER) ||
      KIND_ORDER.indexOf(productKind(a)) - KIND_ORDER.indexOf(productKind(b)) ||
      b.popularity - a.popularity ||
      a.productName.localeCompare(b.productName, "tr"),
  );
}

/** Ürünün kendiliğinden düştüğü bölüm başlığı (marka ya da kategori) */
export function naturalSection(i: Pick<ShopItem, "brand" | "category">): string {
  return i.brand ? `${i.brand} çeşitleri` : i.category ?? "Diğer";
}

/** Ürünün gösterildiği bölüm: elle verilen bölüm, yoksa marka/kategori */
export function sectionOf(i: Pick<ShopItem, "brand" | "category" | "section">): string {
  return i.section ?? naturalSection(i);
}

/**
 * Bölümler (W-08, W-11): önce elle açılan bölümler, sonra markalar (en çok ürünü olan önce), sonra son 60 günün
 * çok satanları, sonra markasız ürünler kategoriye göre. Gizli ürünler gösterilmez.
 */
export function buildSections(items: ShopItem[], topCount = 6): ShopSection[] {
  const visible = items.filter((i) => !i.hidden);
  const groups = new Map<string, ShopItem[]>();
  for (const i of visible) {
    const title = sectionOf(i);
    groups.set(title, [...(groups.get(title) ?? []), i]);
  }
  // Bölüm türü, o bölüme kendiliğinden düşen üründen gelir (marka 1, kategori 2); hiç yoksa elle açılmış bölümdür (0).
  // Böylece bir bölüme başka markadan ürün konması bölümün yerini değiştirmez.
  const kindOf = (title: string, list: ShopItem[]) => {
    const own = list.find((i) => naturalSection(i) === title);
    if (own) return own.brand ? 1 : 2;
    return title.endsWith(" çeşitleri") ? 1 : 0;
  };
  const all = [...groups.entries()].map(([title, list]) => ({ key: `t:${title}`, title, kind: kindOf(title, list), items: sortItems(list) }));
  const byKind = (k: number) => all.filter((g) => g.kind === k);
  const strip = (g: { key: string; title: string; items: ShopItem[] }) => ({ key: g.key, title: g.title, items: g.items });
  const top = [...visible].filter((i) => i.popularity > 0).sort((a, b) => b.popularity - a.popularity).slice(0, topCount);
  const auto = [
    ...byKind(0).sort((a, b) => a.title.localeCompare(b.title, "tr")).map(strip),
    ...byKind(1).sort((a, b) => b.items.length - a.items.length || a.title.localeCompare(b.title, "tr")).map(strip),
    ...(top.length ? [{ key: "top", title: "Çok satanlar", items: top }] : []),
    ...byKind(2).sort((a, b) => a.title.localeCompare(b.title, "tr")).map(strip),
  ];
  // Elle verilen bölüm sırası (W-12) önce gelir; sırası verilmeyenler otomatik sırada arkaya dizilir
  const topRank = items.find((i) => i.topRank !== null)?.topRank ?? null;
  const rankOf = (s: ShopSection) => (s.key === "top" ? topRank : s.items.find((i) => i.sectionRank !== null)?.sectionRank ?? null);
  return auto
    .map((s, idx) => ({ s, r: rankOf(s), idx }))
    .sort((a, b) => (a.r ?? 1e9 + a.idx) - (b.r ?? 1e9 + b.idx))
    .map((x) => x.s);
}

/** Bölüm sırasında kullanılan anahtar: "Çok satanlar" için __top__, diğerleri başlık */
export function sectionToken(s: ShopSection): string {
  return s.key === "top" ? "__top__" : s.title;
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
