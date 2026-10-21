// Müşteriye hazır mesaj taslakları (M-27). Mesajı sistem göndermez; telefonun WhatsApp / SMS uygulaması hazır metinle açılır.
export type MessageTemplate = "tanitim" | "hatirlatma";
export type MessageChannel = "whatsapp" | "sms";

export const ORDER_LINK = "https://alkasu.vercel.app/giris";

export const TEMPLATES: Record<MessageTemplate, { label: string; hint: string; text: string }> = {
  tanitim: {
    label: "Taslak 1 · Tanıtım",
    hint: "Uygulamadan sipariş verilebildiğini duyurur",
    text: [
      "Değerli Müşterimiz,",
      "ALKASU siparişlerinizi artık mobil uygulamamızdan veya internet üzerinden kolayca oluşturabilirsiniz.",
      `Sipariş ver: ${ORDER_LINK}`,
      "Siparişin kolay, suyun kapında, teslimatın takipte.",
      "ALKASU — Alay Ticaret’in 10 yıllık tecrübesiyle.",
    ].join("\n"),
  },
  hatirlatma: {
    label: "Taslak 2 · Tekrar sipariş hatırlatma",
    hint: "Bir süredir sipariş vermeyen müşteriye",
    text: [
      "Değerli Müşterimiz,",
      "Bir süredir siparişinizi alamadık. Yeniden ihtiyaç duyduğunuzda siparişinizi ALKASU mobil uygulaması veya internet üzerinden kolayca verebilirsiniz.",
      `Sipariş ver: ${ORDER_LINK}`,
      "Siparişin kolay, suyun kapında, teslimatın takipte.",
      "ALKASU — Alay Ticaret’in 10 yıllık tecrübesiyle.",
      "Bu otomatik bir bilgilendirme mesajıdır.",
    ].join("\n"),
  },
};

/** Cep telefonu → uluslararası biçim (905XXXXXXXXX); cep değilse null (WhatsApp/SMS yalnızca cep) */
export function mobileIntl(phone: string | null | undefined): string | null {
  let d = (phone ?? "").replace(/\D/g, "");
  if (d.length === 12 && d.startsWith("90")) d = d.slice(2);
  if (d.length === 11 && d.startsWith("0")) d = d.slice(1);
  return /^5\d{9}$/.test(d) ? `90${d}` : null;
}

export function whatsappLink(phone: string, text: string): string {
  return `https://wa.me/${phone}?text=${encodeURIComponent(text)}`;
}

/** iOS ve Android'de çalışan biçim */
export function smsLink(phone: string, text: string): string {
  return `sms:+${phone}?&body=${encodeURIComponent(text)}`;
}
