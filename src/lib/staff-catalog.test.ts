import { describe, expect, it } from "vitest";
import { priceFor, type CatalogUnit } from "./catalog";
import { buildSections } from "./shop";
import { shopInfo, staffItems, type StaffProduct } from "./staff-catalog";

const unit = (id: string, name: string, factor: number, price: number | null, extra: Partial<CatalogUnit> = {}): CatalogUnit => ({
  id, name, factor, price, listPrices: {}, isBase: factor === 1, ...extra,
});
const prod = (id: string, name: string, brand: string | null, category: string, units: CatalogUnit[], stock = 10): StaffProduct & { stock: number } => ({
  id, code: id, name, deposit: null, shopBrand: brand, category, imagePath: null, units, stock,
});

const products = [
  prod("GP-05", "Gürpınar 0,5 L Su", "Gürpınar", "Su", [unit("GP-05-k", "Koli", 24, 120, { listPrices: { bayi: 100 } }), unit("GP-05-a", "Adet", 1, 6)]),
  prod("FS-15", "Fuska 1,5 L Su", "Fuska", "Su", [unit("FS-15-p", "Paket", 6, 60, { layout: { popularity: 5, sort: null, section: null, sectionRank: 10, topRank: 20 } })], 0),
  prod("PM-1", "Pompa", null, "Pompa", [unit("PM-1-a", "Adet", 1, null)]),
];

describe("personel kataloğu (W-13)", () => {
  it("her fiyatlı birim bir kart; fiyatı olmayan birim gösterilmez", () => {
    const items = staffItems(products, (u) => u.price);
    expect(items.map((i) => i.unitId)).toEqual(["GP-05-k", "GP-05-a", "FS-15-p"]);
  });
  it("fiyat müşterinin listesine göre (bayi), özel fiyat önce", () => {
    const items = staffItems(products, (u) => priceFor(u, "bayi", { "GP-05-a": 5 }));
    expect(items.find((i) => i.unitId === "GP-05-k")!.price).toBe(100);
    expect(items.find((i) => i.unitId === "GP-05-a")!.price).toBe(5);
  });
  it("mağaza düzeni uygulanır: bölüm sırası ve çok satanlar", () => {
    const s = buildSections(staffItems(products, (u) => u.price));
    expect(s.map((x) => x.title)).toEqual(["Fuska çeşitleri", "Çok satanlar", "Gürpınar çeşitleri"]);
  });
  it("kartta stok notu", () => {
    const items = staffItems(products, (u) => u.price, (p, u) => ({ text: `Stok ${Math.floor(p.stock / u.factor)}`, danger: p.stock <= 0 }));
    expect(items.find((i) => i.unitId === "FS-15-p")).toMatchObject({ note: "Stok 0", noteDanger: true });
  });
  it("mağazada gösterilmeyen marka kategoriye düşer", () => {
    expect(shopInfo({ brands: { name: "X", show_in_shop: false }, categories: { name: "Su" } })).toEqual({ shopBrand: null, category: "Su", imagePath: null });
    expect(shopInfo({ brands: { name: "Fuska", show_in_shop: true }, categories: null, image_path: "a.webp" }).shopBrand).toBe("Fuska");
  });
});
