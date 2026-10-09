import { describe, expect, it } from "vitest";
import { buildSections, productKind, shortName, toShopItems, unitLabel, type CatalogRow } from "./shop";

const row = (code: string, name: string, unit: string, factor: number, brand: string | null, cat: string | null, pop = 0): CatalogRow => ({
  product_id: code, product_name: name, unit_id: `${code}-${unit}`, unit_name: unit, factor, price: "60.00", has_deposit: false,
  product_code: code, brand_name: brand, category_name: cat, image_path: null, popularity: pop,
});

const items = toShopItems([
  row("GP-15", "Gürpınar 1,5 L Su", "Paket", 6, "Gürpınar", "Su", 10),
  row("DM-GP", "Gürpınar 19 L Damacana", "Damacana", 1, "Gürpınar", "Damacana", 40),
  row("GP-5", "Gürpınar 5 L Su", "Paket", 2, "Gürpınar", "Su"),
  row("FS-15", "Fuska 1,5 L Su", "Paket", 6, "Fuska", "Su", 3),
  row("BP-SADE", "Beypazarı Maden Suyu Sade", "Koli", 24, "Beypazarı", "Maden suyu"),
  row("EN-BPOMPA", "Basma Pompa", "Adet", 1, null, "Pompa", 1),
  row("EN-EPOMPA", "Elektrikli Pompa", "Adet", 1, null, "Pompa"),
  row("TP-B", "Büyük Tüp (dolu)", "Tüp", 1, null, "Tüp"),
]);

describe("mağaza", () => {
  it("marka önekini atar", () => {
    expect(shortName(items[0])).toBe("1,5 L Su");
    expect(shortName(items[5])).toBe("Basma Pompa");
  });
  it("birim açıklaması", () => {
    expect(unitLabel(items[0])).toBe("Paket · 6 adet");
    expect(unitLabel(items[1])).toBe("Damacana");
  });
  it("ürün türünü tanır", () => {
    expect(items.map(productKind)).toEqual(["sise", "damacana", "bidon", "sise", "soda", "pompa", "epompa", "tup"]);
    expect(productKind({ productName: "Gürpınar Bardak Su", unitName: "Koli", category: "Su" })).toBe("bardak");
    expect(productKind({ productName: "Karton Bardak", unitName: "Paket", category: "Sarf" })).toBe("kutu");
  });
  it("bölümler: markalar, çok satanlar, kategoriler", () => {
    const s = buildSections(items, 3);
    expect(s.map((x) => x.title)).toEqual(["Gürpınar çeşitleri", "Beypazarı çeşitleri", "Fuska çeşitleri", "Çok satanlar", "Pompa", "Tüp"]);
    expect(s[0].items.map((i) => i.productCode)).toEqual(["DM-GP", "GP-15", "GP-5"]);
    expect(s[3].items.map((i) => i.productCode)).toEqual(["DM-GP", "GP-15", "FS-15"]);
  });
  it("satış yoksa çok satanlar bölümü açılmaz", () => {
    const s = buildSections(items.map((i) => ({ ...i, popularity: 0 })));
    expect(s.some((x) => x.key === "top")).toBe(false);
  });
});
