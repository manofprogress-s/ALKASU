"use server";
import { isShortMapsLink, parseLocation, type LatLng } from "@/lib/geo";

/**
 * Kısa Google Maps bağlantısını (maps.app.goo.gl/…) açıp koordinatı bulur.
 * Yalnızca Google'ın kısa bağlantı alan adlarına istek atılır (başka adrese istek atılamaz). Herkese açık
 * sipariş sayfası da kullandığı için oturum gerekmez; istek yalnızca Google'a gider ve yanıt boyutu sınırlıdır.
 */
export async function resolveMapsLink(url: string): Promise<LatLng | null> {
  if (typeof url !== "string" || url.length > 500) return null;
  const direct = parseLocation(url);
  if (direct) return direct;
  if (!isShortMapsLink(url)) return null;
  try {
    const res = await fetch(url.trim(), { redirect: "follow", signal: AbortSignal.timeout(6000), headers: { "User-Agent": "Mozilla/5.0" } });
    const fromUrl = parseLocation(res.url);
    if (fromUrl) return fromUrl;
    const body = (await res.text()).slice(0, 200_000);
    const m = body.match(/https:\/\/www\.google\.com\/maps\/[^"'\s\\]+/);
    return m ? parseLocation(m[0]) : null;
  } catch {
    return null;
  }
}
