// Geriye dönük kayıt (O-30..O-33): en fazla 14 gün geriye, ileri tarih yok.
export const BACKDATE_DAYS = 14;

/** datetime-local alanı için sınırlar */
export function backdateBounds(now: Date): { min: Date; max: Date } {
  return { min: new Date(now.getTime() - BACKDATE_DAYS * 24 * 60 * 60 * 1000), max: now };
}

/** Date → "YYYY-MM-DDTHH:mm" (yerel saat, datetime-local biçimi) */
export function toLocalInput(d: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}
