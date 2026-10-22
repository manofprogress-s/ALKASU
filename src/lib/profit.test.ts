import { describe, expect, it } from "vitest";
import { addMonths, marginPct, chartBars, monthBounds, monthLabel, niceMax, normalizePeriod, parseMonth, shortTRY, sumPeriods, weekLabel } from "./profit";

const base = normalizePeriod({
  start: "2026-10-01", end: "2026-10-31", sales_count: "3", income_invoiced: "1000", income_uninvoiced: "500.50", returns: "0.50", income: "1500",
  purchases: "800", purchase_count: 1, expenses: "200", expense_categories: { Yakıt: "200" }, total_cost: "1000", gross_profit: "700", net_profit: "500", cogs: "600",
});

describe("profit", () => {
  it("ay biçimi ve sınırları", () => {
    expect(parseMonth("2026-02", "2026-10-22")).toBe("2026-02");
    expect(parseMonth("2026-13", "2026-10-22")).toBe("2026-10");
    expect(parseMonth(undefined, "2026-10-22")).toBe("2026-10");
    expect(monthBounds("2026-02")).toEqual({ from: "2026-02-01", to: "2026-02-28" });
    expect(monthBounds("2028-02").to).toBe("2028-02-29");
    expect(monthBounds("2026-10").to).toBe("2026-10-31");
  });
  it("ay kaydırma ve etiket", () => {
    expect(addMonths("2026-10", -11)).toBe("2025-11");
    expect(addMonths("2026-12", 1)).toBe("2027-01");
    expect(addMonths("2026-01", -1)).toBe("2025-12");
    expect(monthLabel("2026-10")).toBe("Ekim 2026");
    expect(monthLabel("2026-02", true)).toBe("Şub 26");
    expect(weekLabel("2026-10-05", "2026-10-11")).toBe("5–11 Eki");
    expect(weekLabel("2026-10-31", "2026-10-31")).toBe("31 Eki");
  });
  it("sayılara çevirir ve toplar", () => {
    expect(base.income_uninvoiced).toBe(500.5);
    expect(base.expense_categories["Yakıt"]).toBe(200);
    const t = sumPeriods([base, base]);
    expect(t.net_profit).toBe(1000);
    expect(t.expense_categories["Yakıt"]).toBe(400);
  });
  it("grafik çubukları: iade faturasızdan düşer, gider kırmızı", () => {
    expect(chartBars(base)).toEqual({ green: 1000, orange: 500, red: 1000 });
    expect(chartBars({ ...base, income_uninvoiced: 100, returns: 300 })).toEqual({ green: 800, orange: 0, red: 1000 });
  });
  it("kâr marjı", () => {
    expect(marginPct(800, 1500)).toBe(53.3);
    expect(marginPct(-200, 1000)).toBe(-20);
    expect(marginPct(100, 0)).toBeNull();
    expect(sumPeriods([{ ...base, history_income: 10 }, base]).history_income).toBe(10);
  });
  it("eksen ve kısa tutar", () => {
    expect(niceMax(0)).toBe(1);
    expect(niceMax(1800)).toBe(2000);
    expect(niceMax(2100)).toBe(2500);
    expect(niceMax(73000)).toBe(100000);
    expect(shortTRY(12500)).toBe("12,5 B");
    expect(shortTRY(-1250000)).toBe("−1,25 Mn");
    expect(shortTRY(950)).toBe("950");
  });
});
