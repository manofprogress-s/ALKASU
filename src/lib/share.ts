// Uygulamayı paylaş (M-30): müşteriye internetten sipariş/kayıt bağlantısı gönderme
export const SHARE_PATH = "/siparis-ver";

export function shareText(url: string): string {
  return `ALKASU · Alay Ticaret: su ve damacana siparişinizi internetten verin, hesabınızı açın: ${url}`;
}

/** WhatsApp: kişi seçme ekranı açılır, mesaj hazır gelir */
export function whatsappUrl(text: string): string {
  return `https://wa.me/?text=${encodeURIComponent(text)}`;
}

/** SMS: telefonun mesaj uygulaması açılır (iOS ve Android ortak biçim) */
export function smsUrl(text: string): string {
  return `sms:?&body=${encodeURIComponent(text)}`;
}
