import { describe, expect, it } from "vitest";
import { segmentOf, segmentTotals } from "./sales-segments";

describe("satış grupları (O-19)", () => {
  it("kanal → grup", () => {
    expect(segmentOf("kurumsal")).toBe("kurumsal");
    expect(segmentOf("bayi")).toBe("bayi");
    expect(segmentOf("perakende")).toBe("perakende");
    expect(segmentOf(null)).toBe("perakende");
  });
  it("toplamlar: iptal hariç, aynı satış bir kez", () => {
    const rows = [
      { id: "a", status: "tamamlandi", grand_total: "100.10", channel: "kurumsal" },
      { id: "a", status: "tamamlandi", grand_total: "100.10", channel: "kurumsal" },
      { id: "b", status: "tamamlandi", grand_total: 0.2, channel: null },
      { id: "c", status: "iptal", grand_total: 50, channel: "perakende" },
      { id: "d", status: "tamamlandi", grand_total: 0.1, channel: "perakende" },
    ];
    const t = segmentTotals(rows);
    expect(t.kurumsal).toEqual({ count: 1, total: 100.1 });
    expect(t.perakende).toEqual({ count: 2, total: 0.3 });
    expect(t.bayi).toEqual({ count: 0, total: 0 });
    expect(t.all).toEqual({ count: 3, total: 100.4 });
  });
});
