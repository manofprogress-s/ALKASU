// Özel fiyat ekranı (F-38): toplu indirim hesapları ve değişiklik listesi
export type DiscountMode = "tl" | "yuzde";

/** Normal fiyattan indirim: "tl" = X TL düşük, "yuzde" = %X düşük. Sonuç kuruşa yuvarlanır, eksiye düşmez. */
export function applyDiscount(normal: number, mode: DiscountMode, value: number): number {
  const raw = mode === "tl" ? normal - value : normal * (1 - value / 100);
  return Math.max(0, Math.round(raw * 100) / 100);
}

/** Özel fiyatın normalden farkı (negatif = indirim) */
export function priceDiff(price: number, normal: number | null): { amount: number; pct: number } | null {
  if (normal === null || normal <= 0) return null;
  const amount = Math.round((price - normal) * 100) / 100;
  return { amount, pct: Math.round((amount / normal) * 1000) / 10 };
}

/** Taslak ile kayıtlı fiyatlar arasındaki değişiklikler (boş = özel fiyat kaldırılır) */
export function priceChanges(original: Record<string, number>, draft: Record<string, number | null>): { unit_id: string; price: number | null }[] {
  const out: { unit_id: string; price: number | null }[] = [];
  for (const [unitId, price] of Object.entries(draft)) {
    const before = original[unitId] ?? null;
    if (price !== before) out.push({ unit_id: unitId, price });
  }
  return out;
}
