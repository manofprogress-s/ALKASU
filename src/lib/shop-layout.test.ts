import { describe, expect, it } from "vitest";
import { applyLayout } from "./shop-layout";
import { buildSections, toShopItems, type CatalogRow } from "./shop";

const row = (code: string, name: string, brand: string | null, cat: string): CatalogRow => ({
  product_id: code, product_name: name, unit_id: code, unit_name: "Paket", factor: 6, price: "60", has_deposit: false,
  product_code: code, brand_name: brand, category_name: cat, image_path: null, popularity: 0,
});
const base = toShopItems([
  row("GP-15", "Gürpınar 1,5 L Su", "Gürpınar", "Su"),
  row("GP-05", "Gürpınar 0,5 L Su", "Gürpınar", "Su"),
  row("GP-033", "Gürpınar 0,33 L Su", "Gürpınar", "Su"),
  row("KZ-05", "Kızılay 0,5 L Su", "Kızılay", "Su"),
]);
const codes = (items: ReturnType<typeof toShopItems>, title: string) =>
  buildSections(items, 0).find((s) => s.title === title)?.items.map((i) => i.productCode);

describe("mağaza düzeni", () => {
  it("başlangıç sırası", () => {
    expect(codes(base, "Gürpınar çeşitleri")).toEqual(["GP-033", "GP-05", "GP-15"]);
  });
  it("kaldırma: ürün müşteride görünmez", () => {
    const r = applyLayout(base, { op: "hide", unitId: "GP-05" });
    expect(codes(r.items, "Gürpınar çeşitleri")).toEqual(["GP-033", "GP-15"]);
    expect(r.changes).toEqual([{ unit_id: "GP-05", hidden: true }]);
    expect(codes(applyLayout(r.items, { op: "show", unitId: "GP-05" }).items, "Gürpınar çeşitleri")).toContain("GP-05");
  });
  it("aynı bölümde yer değiştirme (1,5 L ↔ 0,5 L)", () => {
    const r = applyLayout(base, { op: "swap", a: "GP-15", b: "GP-05" });
    expect(codes(r.items, "Gürpınar çeşitleri")).toEqual(["GP-033", "GP-15", "GP-05"]);
    expect(r.changes.every((c) => c.section === null)).toBe(true);
  });
  it("sola / sağa taşıma", () => {
    const r = applyLayout(base, { op: "move", unitId: "GP-15", dir: -1 });
    expect(codes(r.items, "Gürpınar çeşitleri")).toEqual(["GP-033", "GP-15", "GP-05"]);
    const r2 = applyLayout(r.items, { op: "move", unitId: "GP-033", dir: -1 });
    expect(codes(r2.items, "Gürpınar çeşitleri")).toEqual(["GP-033", "GP-15", "GP-05"]);
  });
  it("yerine başka ürün koyma (başka markadan)", () => {
    const r = applyLayout(base, { op: "replace", unitId: "GP-05", withUnitId: "KZ-05" });
    expect(codes(r.items, "Gürpınar çeşitleri")).toEqual(["GP-033", "KZ-05", "GP-15"]);
    expect(codes(r.items, "Kızılay çeşitleri")).toBeUndefined();
    expect(r.items.find((i) => i.unitId === "GP-05")!.hidden).toBe(true);
    expect(r.changes.find((c) => c.unit_id === "KZ-05")!.section).toBe("Gürpınar çeşitleri");
  });
  it("farklı bölümler arasında yer değiştirme", () => {
    const r = applyLayout(base, { op: "swap", a: "GP-15", b: "KZ-05" });
    expect(codes(r.items, "Gürpınar çeşitleri")).toEqual(["GP-033", "GP-05", "KZ-05"]);
    expect(codes(r.items, "Kızılay çeşitleri")).toEqual(["GP-15"]);
  });
  it("otomatik düzene dönüş", () => {
    const r = applyLayout(base, { op: "replace", unitId: "GP-05", withUnitId: "KZ-05" });
    const r2 = applyLayout(r.items, { op: "reset", unitId: "KZ-05" });
    expect(codes(r2.items, "Kızılay çeşitleri")).toEqual(["KZ-05"]);
  });
});
