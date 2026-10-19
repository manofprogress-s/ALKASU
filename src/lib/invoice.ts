/** Fatura arayüzü (F-20…F-27). Logo İşbaşı bağlantısı henüz yok: bu sürüm hiçbir veriyi dışarı göndermez. */

export type InvoiceStatus = "taslak" | "hazir" | "gonderiliyor" | "gonderildi" | "resmilesti" | "hatali" | "iptal";

export const INVOICE_STATUS: Record<InvoiceStatus, { label: string; tone: "neutral" | "warn" | "ok" | "danger" | "brand"; hint: string }> = {
  taslak: { label: "Taslak", tone: "neutral", hint: "ALKASU'da kayıtlı; Logo'ya gönderilmedi" },
  hazir: { label: "Gönderime hazır", tone: "brand", hint: "Bilgiler tamam; Logo bağlantısı kurulunca gönderilecek" },
  gonderiliyor: { label: "Gönderiliyor", tone: "warn", hint: "Logo'ya iletiliyor" },
  gonderildi: { label: "Logo'da", tone: "ok", hint: "Logo İşbaşı'na iletildi; resmîleştirme Logo'da" },
  resmilesti: { label: "Resmîleşti", tone: "ok", hint: "e-Fatura / e-Arşiv olarak düzenlendi" },
  hatali: { label: "Hatalı", tone: "danger", hint: "Gönderimde hata; ayrıntıya bakın" },
  iptal: { label: "İptal", tone: "neutral", hint: "Kayıt iptal edildi; satış yeniden faturalanabilir" },
};

export const INVOICE_EVENT: Record<string, string> = {
  taslak: "Taslak oluşturuldu", yenile: "Bilgiler güncellendi", hazirla: "Gönderime hazırlandı",
  taslaga: "Taslağa geri alındı", iptal: "İptal edildi",
};

export interface InvoiceIssue { level: "error" | "warning"; field: string; message: string }

export interface InvoiceLine {
  line_no: number; product_code: string; name: string; unit: string; qty: number; unit_price: number; discount: number;
  vat_rate: number; gross: number; net: number; vat: number; unit_price_net: number;
}

export interface InvoiceCustomer {
  kind: "vkn" | "tckn" | "yok" | "nihai"; id?: string; code?: string; name: string; legal_title?: string; tax_no?: string | null;
  tax_office?: string | null; address?: string | null; district?: string | null; city?: string | null; email?: string | null;
  phone?: string | null; channel?: string;
}

export interface InvoiceTotals {
  net: number; vat: number; gross: number; deposit: number; by_rate: { rate: number; net: number; vat: number; gross: number }[];
}

export interface InvoicePreview {
  sale: { id: string; no: number; sold_at: string; status: string; grand_total: number };
  customer: InvoiceCustomer; lines: InvoiceLine[]; totals: InvoiceTotals; issues: InvoiceIssue[];
  invoice_id: string | null; doc_type_hint: string;
}

/** VKN (10 hane, GİB algoritması) / TCKN (11 hane) — veritabanındaki app.tax_id_kind ile aynı */
export function taxIdKind(input: string | null | undefined): "vkn" | "tckn" | null {
  const d = (input ?? "").replace(/\D/g, "");
  const n = (i: number) => Number(d[i]);
  if (d.length === 10) {
    let s = 0;
    for (let i = 0; i < 9; i++) {
      const t = (n(i) + 9 - i) % 10;
      const o = (t * 2 ** (9 - i)) % 9;
      s += t !== 0 && o === 0 ? 9 : o;
    }
    return (10 - (s % 10)) % 10 === n(9) ? "vkn" : null;
  }
  if (d.length === 11) {
    if (d[0] === "0") return null;
    const odd = n(0) + n(2) + n(4) + n(6) + n(8);
    const even = n(1) + n(3) + n(5) + n(7);
    if ((((odd * 7 - even) % 10) + 10) % 10 !== n(9)) return null;
    let s = 0;
    for (let i = 0; i < 10; i++) s += n(i);
    return s % 10 === n(10) ? "tckn" : null;
  }
  return null;
}

export const TAX_KIND_LABEL = { vkn: "VKN (şirket)", tckn: "TCKN (şahıs)", yok: "Vergi no yok", nihai: "Nihai tüketici" } as const;
