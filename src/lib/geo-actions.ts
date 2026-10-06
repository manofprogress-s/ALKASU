"use server";
import { isShortMapsLink, parseLocation, type LatLng } from "@/lib/geo";

const GOOGLE_HOST = /^(maps\.app\.goo\.gl|goo\.gl|(www\.|maps\.)?google\.[a-z.]+)$/i;
const MAX_BODY = 200_000;
const MAX_HOPS = 4;

/** Yanıt gövdesini en fazla MAX_BODY bayt okur. */
async function readCapped(res: Response): Promise<string> {
  const reader = res.body?.getReader();
  if (!reader) return "";
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (size < MAX_BODY) {
    const { done, value } = await reader.read();
    if (done || !value) break;
    chunks.push(value);
    size += value.length;
  }
  await reader.cancel().catch(() => undefined);
  return new TextDecoder().decode(Buffer.concat(chunks).subarray(0, MAX_BODY));
}

/**
 * Kısa Google Maps bağlantısını (maps.app.goo.gl/…) açıp koordinatı bulur.
 * Herkese açık sipariş sayfası da kullandığı için oturum gerekmez. Güvenlik: yalnızca Google alan adlarına,
 * en fazla 4 yönlendirmeyle istek atılır; yanıt boyutu sınırlıdır.
 */
export async function resolveMapsLink(url: string): Promise<LatLng | null> {
  if (typeof url !== "string" || url.length > 500) return null;
  const direct = parseLocation(url);
  if (direct) return direct;
  if (!isShortMapsLink(url)) return null;
  try {
    let current = new URL(url.trim());
    for (let hop = 0; hop <= MAX_HOPS; hop++) {
      if (current.protocol !== "https:" || !GOOGLE_HOST.test(current.hostname)) return null;
      const fromUrl = parseLocation(current.toString());
      if (fromUrl) return fromUrl;
      const res = await fetch(current, { redirect: "manual", signal: AbortSignal.timeout(6000), headers: { "User-Agent": "Mozilla/5.0" } });
      const loc = res.headers.get("location");
      if (res.status >= 300 && res.status < 400 && loc) {
        await res.body?.cancel().catch(() => undefined);
        current = new URL(loc, current);
        continue;
      }
      const body = await readCapped(res);
      const m = body.match(/https:\/\/www\.google\.com\/maps\/[^"'\s\\]+/);
      return m ? parseLocation(m[0]) : null;
    }
    return null;
  } catch {
    return null;
  }
}
