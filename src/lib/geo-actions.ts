"use server";
import { isShortMapsLink, parseLocation, type LatLng } from "@/lib/geo";
import { getContext } from "@/lib/session";

/**
 * Kısa Google Maps bağlantısını (maps.app.goo.gl/…) açıp koordinatı bulur.
 * Yalnızca Google'ın kısa bağlantı alan adlarına istek atılır (başka adrese istek atılamaz).
 */
export async function resolveMapsLink(url: string): Promise<LatLng | null> {
  await getContext(); // yalnızca oturum açmış kullanıcılar
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
