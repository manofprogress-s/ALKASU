import { describe, expect, it } from "vitest";
import { toCsv } from "./write";

describe("CSV dışa aktarma", () => {
  it("BOM, noktalı virgül, ondalık virgül ve tırnak kaçışı", () => {
    const csv = toCsv([{ Ürün: 'Su "0,5 L"', Tutar: 12.5, Adet: 3 }]);
    expect(csv.startsWith("﻿")).toBe(true);
    expect(csv).toBe('﻿Ürün;Tutar;Adet\r\n"Su ""0,5 L""";12,5;3');
  });
});
