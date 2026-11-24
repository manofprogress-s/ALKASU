import { describe, expect, it } from "vitest";
import { backdateBounds, toLocalInput } from "./backdate";

describe("geriye dönük kayıt sınırları (O-31)", () => {
  it("en fazla 14 gün geriye, ileri yok", () => {
    const now = new Date(2026, 10, 24, 10, 30);
    const b = backdateBounds(now);
    expect(b.max).toEqual(now);
    expect(toLocalInput(b.min)).toBe("2026-11-10T10:30");
  });
  it("datetime-local biçimi", () => {
    expect(toLocalInput(new Date(2026, 0, 5, 7, 4))).toBe("2026-01-05T07:04");
  });
});
