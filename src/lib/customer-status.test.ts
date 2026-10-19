import { describe, expect, it } from "vitest";
import { agoText, reasonText, subscriberRows, telUrl, whatsappUrl } from "./customer-status";

describe("müşteri durum raporu (M-21…M-25)", () => {
  it("son alım metni", () => {
    expect(agoText(null)).toBe("Hiç alım yok");
    expect(agoText(0)).toBe("Bugün aldı");
    expect(agoText(18)).toBe("18 gün önce aldı");
    expect(agoText(120)).toBe("4 ay önce aldı");
    expect(agoText(400)).toBe("1 yıl 1 ay önce aldı");
  });
  it("arama nedeni", () => {
    expect(reasonText({ days: 34, period: 25, orders: 10, bucket: "sirasi_geldi" })).toBe("Her ~25 günde alır, 9 gün gecikti");
    expect(reasonText({ days: 5, period: 20, orders: 1, bucket: "duzenli" })).toBe("Tek alım, 15 gün sonra sırası gelir");
  });
  it("telefon bağlantıları", () => {
    expect(whatsappUrl("05063029835")).toBe("https://wa.me/905063029835");
    expect(whatsappUrl("02623312211")).toBeNull();
    expect(telUrl("5063029835")).toBe("tel:05063029835");
    expect(telUrl(null)).toBeNull();
  });
  it("eski sistemin Excel başlıkları", () => {
    const rows = subscriberRows([
      { row: "2", "abone": "333", "abone/firma_adı": "Ayşe Kaya", "telefon1": "05063029835", "telefon2": "0", "telefon3": "-",
        "alım_periyodu_(gün)": "25", "son_satış_tarihi": "2026-09-26", "borç_bakiyesi": "0", "konum": "40.73,30.00" },
      { row: "3", "abone": "", "abone/firma_adı": "" },
    ]);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ row: 2, abone: "333", ad: "Ayşe Kaya", telefonlar: ["05063029835"], periyot: "25", konum: "40.73,30.00" });
  });
});
