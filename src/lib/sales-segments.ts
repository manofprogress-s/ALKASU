// Satış listesinde kurumsal / perakende / bayi ayrımı (S-26). Saf fonksiyonlar, birim testli.
export type Segment = "kurumsal" | "perakende" | "bayi";
export const SEGMENTS: { key: Segment; label: string; hint: string }[] = [
  { key: "kurumsal", label: "Kurumsal", hint: "Kurumsal müşteri kartına yapılan satışlar" },
  { key: "perakende", label: "Perakende", hint: "Ev müşterisi ve müşterisiz (tezgâh) satışlar" },
  { key: "bayi", label: "Bayi", hint: "Bayilere yapılan satışlar" },
];

/** Müşteri kanalına göre grup: müşterisiz satış perakendedir */
export function segmentOf(channel: string | null | undefined): Segment {
  return channel === "kurumsal" ? "kurumsal" : channel === "bayi" ? "bayi" : "perakende";
}

export interface SegmentTotals { count: number; total: number }

/**
 * Grup ve genel toplamlar: yalnızca tamamlanan satışlar, her satış (id) bir kez sayılır.
 * Tutarlar kuruş hassasiyetinde toplanır.
 */
export function segmentTotals<T extends { id: string; status: string; grand_total: number | string; channel: string | null }>(rows: T[]) {
  const seen = new Set<string>();
  const out: Record<Segment | "all", { count: number; kurus: number }> = {
    kurumsal: { count: 0, kurus: 0 }, perakende: { count: 0, kurus: 0 }, bayi: { count: 0, kurus: 0 }, all: { count: 0, kurus: 0 },
  };
  for (const r of rows) {
    if (r.status !== "tamamlandi" || seen.has(r.id)) continue;
    seen.add(r.id);
    const k = Math.round(Number(r.grand_total) * 100);
    const g = out[segmentOf(r.channel)];
    g.count += 1; g.kurus += k;
    out.all.count += 1; out.all.kurus += k;
  }
  const t = (x: { count: number; kurus: number }): SegmentTotals => ({ count: x.count, total: x.kurus / 100 });
  return { kurumsal: t(out.kurumsal), perakende: t(out.perakende), bayi: t(out.bayi), all: t(out.all) };
}
