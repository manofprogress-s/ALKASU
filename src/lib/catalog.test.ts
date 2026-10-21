import { describe, expect, it } from "vitest";
import { orderList, priceFor, unitPrice, type CatalogUnit } from "./catalog";

const u = (price: number | null, listPrices: CatalogUnit["listPrices"] = {}): CatalogUnit => ({ id: "u1", name: "Damacana", factor: 1, price, listPrices, isBase: true });

describe("fiyat listeleri (F-14…F-15, app.unit_list_price ile aynı)", () => {
  it("gel al, eve teslim, kurumsal", () => {
    expect(unitPrice(u(80), "perakende")).toBe(80);
    expect(unitPrice(u(80), "ev")).toBe(120);            // listede yok: +40
    expect(unitPrice(u(80, { ev: 160 }), "ev")).toBe(160);
    expect(unitPrice(u(80), "kurumsal")).toBe(120);      // × 1,5
    expect(unitPrice(u(65.5), "kurumsal")).toBe(98.25);
    expect(unitPrice(u(80, { kurumsal: 110 }), "kurumsal")).toBe(110);
    expect(unitPrice(u(null), "ev")).toBeNull();
    expect(unitPrice(u(80), "bayi")).toBe(80);
  });
  it("firmaya özel fiyat önce", () => {
    expect(priceFor(u(80), "kurumsal", { u1: 100 })).toBe(100);
  });
  it("sipariş listesi", () => {
    expect(orderList("perakende")).toBe("ev");
    expect(orderList(null)).toBe("ev");
    expect(orderList("kurumsal")).toBe("kurumsal");
    expect(orderList("bayi")).toBe("bayi");
  });
});
