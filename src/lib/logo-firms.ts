// Logo İşbaşı müşteri (cari) listesini ALKASU kartlarıyla eşleştirme (F-28). Saf fonksiyonlar, birim testli.
import { normalizeHeader } from "@/lib/excel/read";

export interface LogoFirm {
  row: number;
  code: string;
  tip: "bireysel" | "kurumsal" | null;
  aktif: boolean;
  unvan: string;
  sehir: string | null;
  ilce: string | null;
  adres: string | null;
  telefon: string | null;
  vkn: string | null;
  vd: string | null;
  eposta: string | null;
}

type Field = "code" | "tip" | "aktif" | "unvan" | "ekran" | "sehir" | "ilce" | "adres" | "telefon" | "vkn" | "vd" | "eposta";

/** Başlıktan alan: İşbaşı dışa aktarım başlıkları ("Müşteri Kodu", "Müşteri Vkn - Tckn", "E Posta" …) */
export function headerField(raw: string): Field | null {
  const h = normalizeHeader(raw);
  if (h.startsWith("müşteri_kodu") || h === "cari_kodu" || h === "kod") return "code";
  if (h.startsWith("tipi") || h === "tip") return "tip";
  if (h.includes("aktif")) return "aktif";
  if (h.includes("vkn") || h.includes("tckn")) return "vkn";
  if (h.includes("ünvan") || h.includes("unvan")) return "unvan";
  if (h.includes("ekran_adı")) return "ekran";
  if (h === "şehir" || h === "il") return "sehir";
  if (h === "ilçe") return "ilce";
  if (h === "adres") return "adres";
  if (h.startsWith("telefon")) return "telefon";
  if (h.startsWith("vergi_dairesi")) return "vd";
  if (h.replace(/[_-]/g, "") === "eposta" || h === "email" || h === "e-mail") return "eposta";
  return null;
}

const clean = (s: string | undefined) => {
  const t = (s ?? "").replace(/\s+/g, " ").trim();
  return t && t !== "-" ? t : null;
};

/** Excel sayıya çevirdiyse baştaki sıfırlar kaybolur: kod 16, VKN 10 haneye tamamlanır */
export function padDigits(s: string | null, len: number): string | null {
  if (!s) return null;
  const d = s.replace(/\s/g, "");
  return /^\d+$/.test(d) && d.length < len ? d.padStart(len, "0") : d;
}

function toFirm(get: (f: Field) => string | undefined, row: number): LogoFirm | null {
  const code = padDigits(clean(get("code")), 16);
  const unvan = clean(get("unvan")) ?? clean(get("ekran"));
  if (!code || !unvan) return null;
  const tip = clean(get("tip"));
  let vkn = clean(get("vkn"))?.replace(/\D/g, "") || null;
  if (vkn && vkn.length < 10) vkn = vkn.padStart(10, "0"); // TCKN 0 ile başlamaz: kısa değer sıfırları düşmüş VKN'dir
  return {
    row, code, unvan,
    tip: tip === "1" || /bireysel/i.test(tip ?? "") ? "bireysel" : tip === "2" || /kurumsal/i.test(tip ?? "") ? "kurumsal" : null,
    aktif: !/pasif/i.test(clean(get("aktif")) ?? ""),
    sehir: clean(get("sehir")), ilce: clean(get("ilce")), adres: clean(get("adres")), telefon: clean(get("telefon")),
    vkn, vd: clean(get("vd")), eposta: clean(get("eposta"))?.toLowerCase() ?? null,
  };
}

/** Excel'den kopyalanıp yapıştırılan metin (sekmeyle ayrılmış, ilk satır başlık) */
export function parseLogoPaste(text: string): LogoFirm[] {
  const lines = text.replace(/\r/g, "").split("\n").filter((l) => l.trim() !== "");
  if (lines.length < 2) return [];
  const idx = new Map<Field, number>();
  lines[0].split("\t").forEach((h, i) => { const f = headerField(h); if (f && !idx.has(f)) idx.set(f, i); });
  if (!idx.has("code") || !(idx.has("unvan") || idx.has("ekran"))) return [];
  const out: LogoFirm[] = [];
  lines.slice(1).forEach((l, i) => {
    const cells = l.split("\t");
    const f = toFirm((k) => (idx.has(k) ? cells[idx.get(k)!] : undefined), i + 2);
    if (f) out.push(f);
  });
  return out;
}

/** readWorkbook satırları ({normalize edilmiş başlık: değer}) */
export function logoFirmsFromSheet(rows: Record<string, string>[]): LogoFirm[] {
  const out: LogoFirm[] = [];
  rows.forEach((r, i) => {
    const map = new Map<Field, string>();
    for (const [k, v] of Object.entries(r)) { const f = headerField(k); if (f && !map.has(f)) map.set(f, v); }
    const f = toFirm((k) => map.get(k), Number(r.row ?? i + 2));
    if (f) out.push(f);
  });
  return out;
}

export type MatchStatus = "bagli" | "kesin" | "olasi" | "coklu" | "yok";
export const MATCH_STATUS: Record<MatchStatus, { label: string; hint: string; tone: "ok" | "brand" | "warn" | "neutral" }> = {
  bagli: { label: "Zaten bağlı", hint: "Bu İşbaşı kodu bir ALKASU kartına bağlanmış.", tone: "ok" },
  kesin: { label: "Kesin eşleşme", hint: "Vergi numarası aynı.", tone: "ok" },
  olasi: { label: "Olası eşleşme", hint: "Telefon veya isim benziyor. Kontrol edip onaylayın.", tone: "warn" },
  coklu: { label: "Birden fazla aday", hint: "Birden çok kart benziyor; doğru kartı seçin.", tone: "warn" },
  yok: { label: "ALKASU’da yok", hint: "Eşleşen kart bulunamadı.", tone: "neutral" },
};

export interface MatchCandidate {
  id: string; code: string; name: string; legal_title: string | null; tax_no: string | null; tax_office: string | null;
  phone: string | null; city: string | null; district: string | null; address: string | null; email: string | null;
  channel: string; logo_code: string | null;
}
export interface MatchResult {
  row: number; code: string; unvan: string; vkn: string | null; vkn_ok: boolean;
  status: MatchStatus; reason: string | null; candidates: MatchCandidate[];
}

/** Bağlanınca karta yazılacak alanlar: yalnızca kartta boş olanlar (sunucu kuralıyla aynı, F-28) */
export function plannedFills(f: LogoFirm, c: MatchCandidate, vknOk: boolean): string[] {
  const out: string[] = [];
  if (!c.tax_no && f.vkn && vknOk) out.push("vergi no");
  if (!c.tax_office && f.vd) out.push("vergi dairesi");
  if (!c.legal_title && f.unvan) out.push("unvan");
  if (!c.city && f.sehir) out.push("il");
  if (!c.district && f.ilce) out.push("ilçe");
  if (!c.address && f.adres) out.push("adres");
  if (!c.email && f.eposta && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(f.eposta)) out.push("e-posta");
  return out;
}

/** Kartta farklı vergi no varsa (değiştirilmez, uyarı) */
export function taxConflict(f: LogoFirm, c: MatchCandidate): boolean {
  return !!(c.tax_no && f.vkn && c.tax_no !== f.vkn);
}
