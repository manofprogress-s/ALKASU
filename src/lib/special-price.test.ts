import { describe, expect, it } from "vitest";
import { applyDiscount, editableUnits, priceChanges, priceDiff } from "./special-price";

describe("özel fiyat ekranı (F-38)", () => {
  it("TL ve yüzde indirim, kuruşa yuvarlama, eksiye düşmez", () => {
    expect(applyDiscount(80, "tl", 2)).toBe(78);
    expect(applyDiscount(300, "yuzde", 5)).toBe(285);
    expect(applyDiscount(65, "yuzde", 7.5)).toBe(60.13);
    expect(applyDiscount(5, "tl", 10)).toBe(0);
  });
  it("fark: tutar ve yüzde", () => {
    expect(priceDiff(78, 80)).toEqual({ amount: -2, pct: -2.5 });
    expect(priceDiff(90, null)).toBeNull();
  });
  it("yalnızca değişenler; boş = kaldır", () => {
    expect(priceChanges({ a: 78, b: 95 }, { a: 78, b: 90, c: 10, d: null })).toEqual([
      { unit_id: "b", price: 90 },
      { unit_id: "c", price: 10 },
    ]);
    expect(priceChanges({ a: 78 }, { a: null })).toEqual([{ unit_id: "a", price: null }]);
  });
});

describe("editableUnits (D-116)", () => {
  const u = (id: string, isBase: boolean, price: number | null) => ({ id, isBase, price });
  const normal = (x: { price: number | null }) => x.price;
  it("fiyatsız ek birimi gizler, fiyatlıları listeler", () => {
    const r = editableUnits([u("a", true, 50), u("p", false, null)], normal, {});
    expect(r.map((x) => x.unit.id)).toEqual(["a"]);
  });
  it("hiç fiyatı olmayan ürünün ana birimini listeler", () => {
    const r = editableUnits([u("a", false, null), u("p", true, null)], normal, {});
    expect(r.map((x) => [x.unit.id, x.normal])).toEqual([["p", null]]);
  });
  it("özel fiyatı olan fiyatsız birimi listeler", () => {
    const r = editableUnits([u("a", true, 50), u("p", false, null)], normal, { p: 1200 });
    expect(r.map((x) => x.unit.id)).toEqual(["a", "p"]);
  });
});
