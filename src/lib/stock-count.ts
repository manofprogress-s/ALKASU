// Sayım fark raporu (T-04/6): onaya gönderimde yöneticilere gösterilen ve paylaşılabilen özet. Saf fonksiyonlar.
import { formatNumber } from "@/lib/format";

export interface CountDiffLine { product_id: string; name: string; unit: string; system: number; counted: number; diff: number }

export type CountStatus = "acik" | "onayda" | "onaylandi" | "iptal";
export const COUNT_STATUS: Record<CountStatus, { label: string; tone: "brand" | "warn" | "ok" | "neutral" }> = {
  acik: { label: "Sayılıyor · stoğa işlenmedi", tone: "brand" },
  onayda: { label: "Yönetim onayında · stoğa işlenmedi", tone: "warn" },
  onaylandi: { label: "Stoğa işlendi", tone: "ok" },
  iptal: { label: "İptal", tone: "neutral" },
};

const unit = (u: string) => u.toLocaleLowerCase("tr-TR");

/** Tek ürünün fark cümlesi: "5 damacana çıkarılmıştır" / "3 adet eklenmiştir" / "fark yok" */
export function diffSentence(l: CountDiffLine): string {
  if (l.diff === 0) return "Fark yok";
  return `Sayım sonrası ${formatNumber(Math.abs(l.diff))} ${unit(l.unit)} ${l.diff > 0 ? "eklenmiştir" : "çıkarılmıştır"}`;
}

/** Paylaşılabilir düz metin rapor (WhatsApp / kopyala) */
export function countReportText(no: number, lines: CountDiffLine[], opts: { by?: string | null; onlyChanged?: boolean } = {}): string {
  const shown = opts.onlyChanged ? lines.filter((l) => l.diff !== 0) : lines;
  const changed = lines.filter((l) => l.diff !== 0);
  const net = changed.reduce((s, l) => s + l.diff, 0);
  const head = [
    `ALKASU · Sayım #${no} onayınızı bekliyor${opts.by ? ` (gönderen: ${opts.by})` : ""}`,
    `${lines.length} ürün sayıldı, ${changed.length} üründe fark var${changed.length ? ` (net ${net > 0 ? "+" : ""}${formatNumber(net)})` : ""}.`,
  ];
  const body = shown.map((l) =>
    [`• Sayım yapılan ürün: ${l.name}`,
     `  Sayımdan önceki miktar = ${formatNumber(l.system)} ${unit(l.unit)}`,
     `  Güncel sayım miktarı = ${formatNumber(l.counted)} ${unit(l.unit)}`,
     `  ${diffSentence(l)}${l.diff ? ` (${l.diff > 0 ? "+" : ""}${formatNumber(l.diff)})` : ""}`].join("\n"));
  return [...head, "", ...body, "", "Stok, iki yönetici onayından sonra güncellenir."].join("\n");
}
