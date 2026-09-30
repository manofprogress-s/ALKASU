import { describe, expect, it } from "vitest";
import { addDaysISO, formatDate, formatDateTime, formatTRY, parseAmount, toKurus, todayISO } from "./format";

describe("format", () => {
  it("TL biçimi", () => {
    expect(formatTRY(1234.5).replace(/\s/g, " ")).toMatch(/1\.234,50/);
    expect(formatTRY(null)).toBe("—");
  });
  it("GG.AA.YYYY ve İstanbul saati", () => {
    expect(formatDate("2026-09-30")).toBe("30.09.2026");
    // UTC 21:30 → İstanbul ertesi gün 00:30
    expect(formatDateTime("2026-09-29T21:30:00Z")).toBe("30.09.2026 00:30");
    expect(todayISO(new Date("2026-09-29T21:30:00Z"))).toBe("2026-09-30");
    expect(addDaysISO("2026-02-28", 1)).toBe("2026-03-01");
  });
  it("tutar ayrıştırma", () => {
    expect(parseAmount("1.234,50")).toBe(1234.5);
    expect(parseAmount("1234,5")).toBe(1234.5);
    expect(parseAmount("1234.50")).toBe(1234.5);
    expect(parseAmount("1,234.50")).toBe(1234.5);
    expect(parseAmount("1.234")).toBe(1234);
    expect(parseAmount("₺ 12")).toBe(12);
    expect(parseAmount("abc")).toBeNull();
    expect(parseAmount("")).toBeNull();
  });
  it("kuruş yuvarlama", () => {
    expect(toKurus(1.005)).toBe(101);
    expect(toKurus(0.1 + 0.2)).toBe(30);
    expect(toKurus(-2.5)).toBe(-250);
  });
});
