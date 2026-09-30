import { describe, expect, it } from "vitest";
import { normalizeHeader, normalizeNumberText, parseCsv } from "./read";

describe("excel okuma", () => {
  it("başlıklar", () => {
    expect(normalizeHeader("urun_kodu *")).toBe("urun_kodu");
    expect(normalizeHeader(" KDV Orani ")).toBe("kdv_orani");
  });
  it("sayı metinleri", () => {
    expect(normalizeNumberText("25,50")).toBe("25.50");
    expect(normalizeNumberText("1.234,5")).toBe("1234.5");
    expect(normalizeNumberText("8690000000011")).toBe("8690000000011");
  });
  it("noktalı virgüllü CSV", () => {
    const rows = parseCsv('﻿urun_kodu;urun_adi;satis_fiyati\nA-1;"Su; 0,5 L";10,5\n\n');
    expect(rows).toEqual([{ row: "2", urun_kodu: "A-1", urun_adi: "Su; 0,5 L", satis_fiyati: "10.5" }]);
  });
});
