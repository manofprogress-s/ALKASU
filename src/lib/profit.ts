// Gelir-gider raporu yardımcıları (GG-01..GG-03). Hesap veritabanında (`profit_report`); burada yalnızca dönem/etiket/grafik.

export interface ProfitPeriod {
  start: string; // YYYY-MM-DD
  end: string;
  sales_count: number;
  income_invoiced: number;   // faturası kesilmiş satış (yeşil)
  income_uninvoiced: number; // faturası kesilmemiş satış / teslimat (turuncu)
  returns: number;
  income: number;            // faturalı + faturasız − iade
  purchases: number;         // mal kabul (alış fiyatı × miktar)
  purchase_count: number;
  expenses: number;          // işletme giderleri
  expense_categories: Record<string, number>;
  total_cost: number;        // mal alımı + gider (kırmızı)
  gross_profit: number;      // gelir − mal alımı
  net_profit: number;        // brüt − gider
  cogs: number;              // satılan malın maliyeti (bilgi)
  history_income: number;    // GG-04: Logo geçmiş satış faturaları (gelire dahil)
  history_purchases: number; // GG-04: Logo geçmiş alış faturaları (mal alımına dahil)
}

export interface ProfitReport { periods: ProfitPeriod[]; pending_purchases: number }

export const CHART_COLORS = { invoiced: "#1a9b5a", uninvoiced: "#f08c00", expense: "#d63b3b" } as const;

const MONTHS = ["Ocak", "Şubat", "Mart", "Nisan", "Mayıs", "Haziran", "Temmuz", "Ağustos", "Eylül", "Ekim", "Kasım", "Aralık"];
const MONTHS_SHORT = ["Oca", "Şub", "Mar", "Nis", "May", "Haz", "Tem", "Ağu", "Eyl", "Eki", "Kas", "Ara"];

/** "2026-10" biçimini doğrular; geçersizse bugünün ayını döner. */
export function parseMonth(v: string | undefined | null, today: string): string {
  return v && /^\d{4}-(0[1-9]|1[0-2])$/.test(v) ? v : today.slice(0, 7);
}

/** Ayın ilk ve son günü */
export function monthBounds(ym: string): { from: string; to: string } {
  const [y, m] = ym.split("-").map(Number) as [number, number];
  const last = new Date(Date.UTC(y, m, 0)).getUTCDate();
  return { from: `${ym}-01`, to: `${ym}-${String(last).padStart(2, "0")}` };
}

/** ym'den n ay kaydırır */
export function addMonths(ym: string, n: number): string {
  const [y, m] = ym.split("-").map(Number) as [number, number];
  const t = y * 12 + (m - 1) + n;
  return `${Math.floor(t / 12)}-${String((t % 12) + 1).padStart(2, "0")}`;
}

export function monthLabel(ym: string, short = false): string {
  const [y, m] = ym.split("-").map(Number) as [number, number];
  return short ? `${MONTHS_SHORT[m - 1]} ${String(y).slice(2)}` : `${MONTHS[m - 1]} ${y}`;
}

/** Hafta etiketi: "6–12 Eki" (ay içinde kırpılmış) */
export function weekLabel(start: string, end: string): string {
  const d1 = Number(start.slice(8, 10));
  const d2 = Number(end.slice(8, 10));
  const m = MONTHS_SHORT[Number(end.slice(5, 7)) - 1];
  return d1 === d2 ? `${d1} ${m}` : `${d1}–${d2} ${m}`;
}

export function num(v: unknown): number {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

/** Veritabanından gelen satırı sayıya çevirir (numeric alanlar metin gelebilir). */
export function normalizePeriod(p: Record<string, unknown>): ProfitPeriod {
  const cats: Record<string, number> = {};
  for (const [k, v] of Object.entries((p.expense_categories as Record<string, unknown> | null) ?? {})) cats[k] = num(v);
  return {
    start: String(p.start), end: String(p.end), sales_count: num(p.sales_count),
    income_invoiced: num(p.income_invoiced), income_uninvoiced: num(p.income_uninvoiced), returns: num(p.returns), income: num(p.income),
    purchases: num(p.purchases), purchase_count: num(p.purchase_count), expenses: num(p.expenses), expense_categories: cats,
    total_cost: num(p.total_cost), gross_profit: num(p.gross_profit), net_profit: num(p.net_profit), cogs: num(p.cogs),
    history_income: num(p.history_income), history_purchases: num(p.history_purchases),
  };
}

export function sumPeriods(ps: ProfitPeriod[]): Omit<ProfitPeriod, "start" | "end"> {
  const t = { sales_count: 0, income_invoiced: 0, income_uninvoiced: 0, returns: 0, income: 0, purchases: 0, purchase_count: 0, expenses: 0,
    expense_categories: {} as Record<string, number>, total_cost: 0, gross_profit: 0, net_profit: 0, cogs: 0, history_income: 0, history_purchases: 0 };
  for (const p of ps) {
    for (const k of ["sales_count", "income_invoiced", "income_uninvoiced", "returns", "income", "purchases", "purchase_count", "expenses",
      "total_cost", "gross_profit", "net_profit", "cogs", "history_income", "history_purchases"] as const) t[k] = Math.round((t[k] + p[k]) * 100) / 100;
    for (const [c, v] of Object.entries(p.expense_categories)) t.expense_categories[c] = Math.round(((t.expense_categories[c] ?? 0) + v) * 100) / 100;
  }
  return t;
}

/**
 * Grafik çubukları: gelir çubuğu = faturalı (yeşil, altta) + faturasız (turuncu, üstte); iade faturasızdan düşülür
 * (faturasız yetmezse faturalıdan). Gider çubuğu = mal alımı + gider (kırmızı).
 */
export function chartBars(p: ProfitPeriod): { green: number; orange: number; red: number } {
  let orange = p.income_uninvoiced - p.returns;
  let green = p.income_invoiced;
  if (orange < 0) { green = Math.max(0, green + orange); orange = 0; }
  return { green, orange, red: p.total_cost };
}

/** Brüt kâr marjı % (gelir yoksa null) */
export function marginPct(gross: number, income: number): number | null {
  return income > 0 ? Math.round((gross / income) * 1000) / 10 : null;
}

/** Eksen için "yuvarlak" üst sınır: 1, 2, 2.5, 5 × 10^n */
export function niceMax(v: number): number {
  if (v <= 0) return 1;
  const pow = 10 ** Math.floor(Math.log10(v));
  for (const f of [1, 2, 2.5, 5, 10]) if (v <= f * pow) return f * pow;
  return 10 * pow;
}

/** Kısa tutar: 12.500 → "12,5 B", 1.250.000 → "1,25 Mn" */
export function shortTRY(v: number): string {
  const a = Math.abs(v);
  const s = v < 0 ? "−" : "";
  const fmt = (x: number, d: number) => x.toLocaleString("tr-TR", { maximumFractionDigits: d });
  if (a >= 1_000_000) return `${s}${fmt(a / 1_000_000, 2)} Mn`;
  if (a >= 1_000) return `${s}${fmt(a / 1_000, 1)} B`;
  return `${s}${fmt(a, 0)}`;
}
