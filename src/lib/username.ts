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

/** Girişte yazılan değer: '@' içeriyorsa e-posta, değilse kullanıcı adı. */
export function loginEmail(input: string): string {
  const v = input.trim();
  if (v.includes("@")) return v.toLowerCase();
  return `${normalizeUsername(v)}@${USERNAME_DOMAIN}`;
}

export function isSyntheticEmail(email: string | null | undefined): boolean {
  return !!email && email.toLowerCase().endsWith(`@${USERNAME_DOMAIN}`);
}
