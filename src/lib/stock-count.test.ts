import { describe, expect, it } from "vitest";
import { countReportText, diffSentence } from "./stock-count";

const l = (name: string, system: number, counted: number, unit = "Damacana") => ({ product_id: name, name, unit, system, counted, diff: counted - system });

describe("sayım fark raporu (T-04/6)", () => {
  it("fark cümlesi", () => {
    expect(diffSentence(l("Fuska 19 L", 1080, 1075))).toBe("Sayım sonrası 5 damacana çıkarılmıştır");
    expect(diffSentence(l("Viyol", 10, 13, "Adet"))).toBe("Sayım sonrası 3 adet eklenmiştir");
    expect(diffSentence(l("X", 4, 4))).toBe("Fark yok");
  });
  it("rapor metni", () => {
    const t = countReportText(1, [l("Fuska 19 L", 1080, 1075), l("Su", 10, 10, "Şişe")], { by: "Selin" });
    expect(t).toContain("Sayım #1 onayınızı bekliyor (gönderen: Selin)");
    expect(t).toContain("2 ürün sayıldı, 1 üründe fark var (net -5)");
    expect(t).toContain("Sayımdan önceki miktar = 1.080 damacana");
    expect(t).toContain("Güncel sayım miktarı = 1.075 damacana");
    expect(t).toContain("5 damacana çıkarılmıştır (-5)");
    expect(countReportText(1, [l("A", 1, 2), l("B", 3, 3)], { onlyChanged: true })).not.toContain("B\n");
  });
});
