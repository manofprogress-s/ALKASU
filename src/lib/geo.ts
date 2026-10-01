// Konum yardımcıları (D-047): Google Maps bağlantısından veya "enlem, boylam" metninden koordinat çıkarır.
// API anahtarı gerektirmez; harita gösterimi ve yol tarifi Google Maps'in herkese açık URL'leriyle yapılır.

export interface LatLng {
  lat: number;
  lng: number;
}

const valid = (lat: number, lng: number): LatLng | null =>
  Number.isFinite(lat) && Number.isFinite(lng) && Math.abs(lat) <= 90 && Math.abs(lng) <= 180 && !(lat === 0 && lng === 0)
    ? { lat: Math.round(lat * 1e6) / 1e6, lng: Math.round(lng * 1e6) / 1e6 }
    : null;

const NUM = "(-?\\d{1,3}(?:\\.\\d+)?)";
const PATTERNS: RegExp[] = [
  new RegExp(`!3d${NUM}!4d${NUM}`), // işaretlenen yerin kendisi (en doğru)
  new RegExp(`[?&](?:q|query|ll|destination|daddr|center)=(?:loc:)?${NUM}\\s*,\\s*${NUM}`),
  new RegExp(`@${NUM},${NUM}`), // haritanın merkezi
];

/** Google Maps bağlantısı veya "40.76, 29.94" biçiminden koordinat; bulunamazsa null. */
export function parseLocation(input: string | null | undefined): LatLng | null {
  const s = (input ?? "").trim();
  if (!s) return null;
  // "40.76, 29.94" · "40.76 29.94" · "40,76; 29,94"
  const plain = s.match(/^(-?\d{1,3}(?:[.,]\d+)?)\s*[,;\s]\s*(-?\d{1,3}(?:[.,]\d+)?)$/);
  if (plain) return valid(Number(plain[1]!.replace(",", ".")), Number(plain[2]!.replace(",", ".")));
  let decoded = s;
  try {
    decoded = decodeURIComponent(s);
  } catch {
    /* bozuk kodlama: olduğu gibi dene */
  }
  for (const re of PATTERNS) {
    const m = decoded.match(re);
    if (m) {
      const v = valid(Number(m[1]), Number(m[2]));
      if (v) return v;
    }
  }
  return null;
}

/** Kısa bağlantı (maps.app.goo.gl) sunucuda açılmalıdır. */
export function isShortMapsLink(input: string): boolean {
  return /^https?:\/\/(maps\.app\.goo\.gl|goo\.gl\/maps)\//i.test(input.trim());
}

export const mapsUrl = (p: LatLng) => `https://www.google.com/maps/search/?api=1&query=${p.lat},${p.lng}`;
export const directionsUrl = (p: LatLng) => `https://www.google.com/maps/dir/?api=1&destination=${p.lat},${p.lng}`;
export const embedUrl = (p: LatLng) => `https://maps.google.com/maps?q=${p.lat},${p.lng}&z=16&output=embed`;

export function toLatLng(lat: number | string | null | undefined, lng: number | string | null | undefined): LatLng | null {
  if (lat === null || lat === undefined || lng === null || lng === undefined || lat === "" || lng === "") return null;
  return valid(Number(lat), Number(lng));
}
