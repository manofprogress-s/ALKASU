// Veritabanı fonksiyonları Türkçe, kullanıcıya gösterilebilir hata mesajları üretir.
// Burada yalnızca teknik hataları sade Türkçeye çeviriyoruz.
export function errorMessage(err: unknown): string {
  if (!err) return "Bilinmeyen hata";
  const e = err as { message?: string; code?: string; details?: string };
  const msg = e.message ?? String(err);
  if (/Failed to fetch|NetworkError|network/i.test(msg)) return "İnternet bağlantısı yok veya sunucuya ulaşılamıyor.";
  if (/JWT expired|invalid JWT|not authenticated/i.test(msg)) return "Oturumunuzun süresi doldu. Lütfen yeniden giriş yapın.";
  if (e.code === "42501" && /permission denied/i.test(msg)) return "Bu işlem için yetkiniz yok.";
  if (/duplicate key/i.test(msg)) return "Bu kayıt zaten var.";
  return msg;
}

export function isNetworkError(err: unknown): boolean {
  const msg = (err as { message?: string })?.message ?? String(err);
  return /Failed to fetch|NetworkError|Load failed|network/i.test(msg);
}
