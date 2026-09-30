// Türkçe biçimlendirme yardımcıları (G-02, G-03). Tüm gösterimler Europe/Istanbul saat dilimindedir.
export const TIME_ZONE = "Europe/Istanbul";

const tryFormatter = new Intl.NumberFormat("tr-TR", {
  style: "currency",
  currency: "TRY",
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});
const numberFormatter = new Intl.NumberFormat("tr-TR", { maximumFractionDigits: 2 });

/** 1234.5 → "₺1.234,50" */
export function formatTRY(value: number | string | null | undefined): string {
  const n = typeof value === "string" ? Number(value) : value;
  if (n === null || n === undefined || Number.isNaN(n)) return "—";
  return tryFormatter.format(n);
}

export function formatNumber(value: number | string | null | undefined): string {
  const n = typeof value === "string" ? Number(value) : value;
  if (n === null || n === undefined || Number.isNaN(n)) return "—";
  return numberFormatter.format(n);
}

function parts(d: Date, withTime: boolean) {
  const p = new Intl.DateTimeFormat("tr-TR", {
    timeZone: TIME_ZONE,
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    ...(withTime ? { hour: "2-digit", minute: "2-digit", hour12: false } : {}),
  }).formatToParts(d);
  const get = (t: Intl.DateTimeFormatPartTypes) => p.find((x) => x.type === t)?.value ?? "";
  return { day: get("day"), month: get("month"), year: get("year"), hour: get("hour"), minute: get("minute") };
}

/** GG.AA.YYYY */
export function formatDate(value: string | Date | null | undefined): string {
  if (!value) return "—";
  const d = typeof value === "string" ? new Date(value.length === 10 ? `${value}T12:00:00Z` : value) : value;
  if (Number.isNaN(d.getTime())) return "—";
  const x = parts(d, false);
  return `${x.day}.${x.month}.${x.year}`;
}

/** GG.AA.YYYY SS:DD */
export function formatDateTime(value: string | Date | null | undefined): string {
  if (!value) return "—";
  const d = typeof value === "string" ? new Date(value) : value;
  if (Number.isNaN(d.getTime())) return "—";
  const x = parts(d, true);
  return `${x.day}.${x.month}.${x.year} ${x.hour}:${x.minute}`;
}

/** İstanbul'a göre bugünün tarihi: YYYY-MM-DD */
export function todayISO(now: Date = new Date()): string {
  const x = parts(now, false);
  return `${x.year}-${x.month}-${x.day}`;
}

export function addDaysISO(iso: string, days: number): string {
  const d = new Date(`${iso}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

/**
 * Kullanıcı girdisini sayıya çevirir. "1.234,50", "1234,5", "1234.50" ve "12" kabul edilir.
 * Geçersizse null döner.
 */
export function parseAmount(input: string | number | null | undefined): number | null {
  if (input === null || input === undefined) return null;
  if (typeof input === "number") return Number.isFinite(input) ? input : null;
  let s = input.trim().replace(/\s|₺|TL/gi, "");
  if (s === "") return null;
  const hasComma = s.includes(",");
  const hasDot = s.includes(".");
  if (hasComma && hasDot) {
    // Son görülen ayırıcı ondalıktır
    if (s.lastIndexOf(",") > s.lastIndexOf(".")) s = s.replace(/\./g, "").replace(",", ".");
    else s = s.replace(/,/g, "");
  } else if (hasComma) {
    s = s.replace(",", ".");
  } else if (hasDot && /^\d{1,3}(\.\d{3})+$/.test(s)) {
    s = s.replace(/\./g, ""); // "1.234" → 1234
  }
  if (!/^-?\d+(\.\d+)?$/.test(s)) return null;
  return Number(s);
}

/** Kuruş cinsinden tamsayıya çevirir (yarım yukarı). */
export function toKurus(value: number): number {
  return Math.sign(value) * Math.round(Math.abs(value) * 100 + 1e-9);
}
export function fromKurus(k: number): number {
  return k / 100;
}
