import { normalizePhone } from "@/lib/username";

/** Müşteri durum raporu (M-21…M-26) */
export type Bucket = "ara" | "ertelenen" | "sirasi_geldi" | "gecikti" | "duzenli" | "siparis_var" | "geri_kazan" | "uyuyan" | "hic" | "tumu";
export type Outcome = "siparis" | "sonra" | "ulasilamadi" | "istemiyor" | "yanlis_numara";

export const BUCKETS: { key: Bucket; label: string; hint: string }[] = [
  { key: "ara", label: "Bugün aranacak", hint: "Sırası gelen ve geciken; ertelenenler hariç. Önce en değerli ve en çok geciken." },
  { key: "duzenli", label: "Düzenli alıyor", hint: "Alışılmış aralığı henüz dolmadı." },
  { key: "siparis_var", label: "Açık siparişi var", hint: "Bekleyen siparişi olanlar aranmaz." },
  { key: "geri_kazan", label: "Geri kazan", hint: "3 ay ile 1 yıl arasında alım yok." },
  { key: "uyuyan", label: "Uyuyan", hint: "1 yıldan uzun süredir alım yok." },
  { key: "hic", label: "Hiç almamış", hint: "Kayıtlı ama alımı yok." },
  { key: "ertelenen", label: "Ertelenen", hint: "Arandı; tekrar arama günü gelmedi." },
  { key: "tumu", label: "Tümü", hint: "Bütün müşteriler." },
];
export const BUCKET_LABEL: Record<string, string> = {
  sirasi_geldi: "Sırası geldi", gecikti: "Gecikti", duzenli: "Düzenli", siparis_var: "Açık sipariş",
  geri_kazan: "Geri kazan", uyuyan: "Uyuyan", hic: "Hiç almamış",
};
export const BUCKET_TONE: Record<string, "ok" | "warn" | "danger" | "neutral" | "brand"> = {
  sirasi_geldi: "warn", gecikti: "danger", duzenli: "ok", siparis_var: "brand", geri_kazan: "neutral", uyuyan: "neutral", hic: "neutral",
};

export const OUTCOMES: { key: Outcome; label: string; hint: string }[] = [
  { key: "siparis", label: "Sipariş verdi", hint: "Sipariş ekranı açılır; 7 gün aranmaz" },
  { key: "sonra", label: "Sonra arayın dedi", hint: "Seçtiğiniz gün tekrar listede (varsayılan 3 gün)" },
  { key: "ulasilamadi", label: "Ulaşılamadı", hint: "Yarın tekrar listede" },
  { key: "istemiyor", label: "Şimdilik istemiyor", hint: "60 gün aranmaz" },
  { key: "yanlis_numara", label: "Yanlış numara", hint: "1 yıl aranmaz; kartta numarayı düzeltin" },
];
export const OUTCOME_LABEL: Record<string, string> = Object.fromEntries(OUTCOMES.map((o) => [o.key, o.label]));

export interface StatusRow {
  id: string;
  code: string;
  name: string;
  phone: string | null;
  extra_phones: string[];
  district: string | null;
  area: string | null;
  address: string | null;
  channel: string;
  segment: string | null;
  brand_pref: string | null;
  preferred_product: string | null;
  last_at: string | null;
  days: number | null;
  period: number;
  orders: number;
  total: number | null;
  open_order: boolean;
  next_call_on: string | null;
  last_call_at: string | null;
  last_outcome: string | null;
  last_caller: string | null;
  legacy_debt: number | null;
  bucket: string;
  priority: number;
}

export interface StatusSummary {
  total: number;
  active30: number;
  new30: number;
  call_now: number;
  snoozed: number;
  buckets: Record<string, number>;
  areas: string[];
  callers: { name: string; today: number; today_orders: number; week: number; week_orders: number }[];
}

/** "18 gün önce", "bugün", "1 yıl 2 ay önce" */
export function agoText(days: number | null): string {
  if (days === null) return "Hiç alım yok";
  if (days <= 0) return "Bugün aldı";
  if (days === 1) return "Dün aldı";
  if (days < 60) return `${days} gün önce aldı`;
  if (days < 365) return `${Math.round(days / 30)} ay önce aldı`;
  const y = Math.floor(days / 365);
  const m = Math.round((days - y * 365) / 30);
  return `${y} yıl${m ? ` ${m} ay` : ""} önce aldı`;
}

/** Arama satırındaki kısa neden: "Her ~25 günde alır, 9 gün gecikti" */
export function reasonText(r: Pick<StatusRow, "days" | "period" | "orders" | "bucket">): string {
  if (r.days === null) return "Kayıtlı, henüz alım yok";
  const late = r.days - r.period;
  const every = r.orders >= 2 ? `Her ~${r.period} günde alır` : "Tek alım";
  if (late > 0) return `${every}, ${late} gün gecikti`;
  return `${every}, ${-late} gün sonra sırası gelir`;
}

/** WhatsApp yalnızca cep telefonu için */
export function whatsappUrl(phone: string | null): string | null {
  const p = normalizePhone(phone);
  return p ? `https://wa.me/90${p}` : null;
}

export function telUrl(phone: string | null): string | null {
  const d = (phone ?? "").replace(/\D/g, "");
  return d.length >= 10 ? `tel:${d.startsWith("0") ? d : `0${d}`}` : null;
}

/** Eski sistemin abone listesi (Excel) → içe aktarma satırları. Başlıklar normalizeHeader ile küçültülmüş gelir. */
export function subscriberRows(rows: Record<string, string>[]): Record<string, unknown>[] {
  const pick = (r: Record<string, string>, ...keys: string[]) => {
    for (const k of keys) {
      const v = (r[k] ?? "").trim();
      if (v && v !== "-") return v;
    }
    return null;
  };
  return rows
    .map((r, i) => ({
      row: Number(r.row ?? i + 2),
      abone: pick(r, "abone", "abone_no"),
      tur: pick(r, "türü", "tür"),
      tip: pick(r, "abone_tipi"),
      ad: pick(r, "abone/firma_adı", "ad", "firma_adı"),
      adres: pick(r, "adres"),
      ilce: pick(r, "ilçe"),
      tarif: pick(r, "kısa_adres_tarifi"),
      marka: pick(r, "kullandığı_marka"),
      saha: pick(r, "saha_elemanı"),
      son_satis: pick(r, "son_satış_tarihi"),
      telefonlar: ["telefon1", "telefon2", "telefon3", "telefon4", "telefon5"].map((k) => pick(r, k)).filter((x): x is string => !!x && x !== "0"),
      kayit: pick(r, "kayıt_tarihi"),
      periyot: pick(r, "alım_periyodu_(gün)"),
      siparis_sayisi: pick(r, "sipariş_verme_sayısı"),
      toplam_satis: pick(r, "toplam_satış_tutarı"),
      borc: pick(r, "borç_bakiyesi"),
      konum: pick(r, "konum"),
      tercih: pick(r, "tercih_edilen_ürün"),
    }))
    .filter((r) => r.abone || r.ad);
}
