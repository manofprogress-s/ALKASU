/** D-045: kullanıcı adı → iç giriş e-postası. Türkçe karakterler sadeleştirilir, küçük harfe çevrilir. */
export const USERNAME_DOMAIN = "kullanici.alkasu.app";

const MAP: Record<string, string> = {
  ç: "c", Ç: "c", ğ: "g", Ğ: "g", ı: "i", I: "i", İ: "i", ö: "o", Ö: "o", ş: "s", Ş: "s", ü: "u", Ü: "u",
};

export function normalizeUsername(input: string): string {
  return input
    .trim()
    .replace(/[çÇğĞıIİöÖşŞüÜ]/g, (c) => MAP[c] ?? c)
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9._-]/g, "");
}

/** D-052: müşteri telefonla girer; telefon → iç e-posta (SMS/e-posta gönderilmez). */
export const PHONE_DOMAIN = "musteri.alkasu.app";

/** Türkiye cep telefonu: 0532 111 22 33, +90 532…, 532… → "5321112233"; geçersizse null. */
export function normalizePhone(input: string | null | undefined): string | null {
  let d = (input ?? "").replace(/\D/g, "");
  if (d.startsWith("90") && d.length === 12) d = d.slice(2);
  if (d.startsWith("0") && d.length === 11) d = d.slice(1);
  return /^5\d{9}$/.test(d) ? d : null;
}

export const phoneEmail = (phone: string) => `${phone}@${PHONE_DOMAIN}`;

/** Görüntüleme: 0532 111 22 33 */
export function formatPhone(input: string | null | undefined): string {
  const p = normalizePhone(input);
  return p ? `0${p.slice(0, 3)} ${p.slice(3, 6)} ${p.slice(6, 8)} ${p.slice(8)}` : (input ?? "");
}

/** Girişte yazılan değer: '@' içeriyorsa e-posta, cep telefonuysa müşteri, değilse kullanıcı adı. */
export function loginEmail(input: string): string {
  const v = input.trim();
  if (v.includes("@")) return v.toLowerCase();
  const phone = /^[\d\s()+-]+$/.test(v) ? normalizePhone(v) : null;
  if (phone) return phoneEmail(phone);
  return `${normalizeUsername(v)}@${USERNAME_DOMAIN}`;
}

export function isSyntheticEmail(email: string | null | undefined): boolean {
  return !!email && email.toLowerCase().endsWith(`@${USERNAME_DOMAIN}`);
}
