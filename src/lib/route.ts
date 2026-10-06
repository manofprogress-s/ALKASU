// Rota planlama (D-056): ücretsiz, tarayıcıda çalışır. Kuş uçuşu mesafeyle (haversine) en yakın komşu
// sıralaması yapılır, sonra 2-opt ile kesişen yollar düzeltilir. Yol sürüşü Google Maps'te açılır.
import type { LatLng } from "./geo";

export interface Stop<T = unknown> {
  id: string;
  point: LatLng;
  data: T;
}

export interface PlannedRoute<T> {
  stops: Stop<T>[];
  /** Her durağa bir öncekinden (ilk durak için başlangıçtan) kuş uçuşu km */
  legsKm: number[];
  totalKm: number;
}

const R = 6371; // km
export function distanceKm(a: LatLng, b: LatLng): number {
  const rad = (d: number) => (d * Math.PI) / 180;
  const dLat = rad(b.lat - a.lat);
  const dLng = rad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

function pathLength(start: LatLng, pts: LatLng[], back: boolean): number {
  let d = 0;
  let prev = start;
  for (const p of pts) {
    d += distanceKm(prev, p);
    prev = p;
  }
  return back && pts.length ? d + distanceKm(prev, start) : d;
}

/**
 * Başlangıç noktasından tüm duraklara en kısa sıralama (yaklaşık).
 * back = true ise depoya dönüş de hesaba katılır.
 */
export function planRoute<T>(start: LatLng, stops: Stop<T>[], back = false): PlannedRoute<T> {
  // 1) En yakın komşu
  const left = [...stops];
  const order: Stop<T>[] = [];
  let cur = start;
  while (left.length) {
    let best = 0;
    let bestD = Infinity;
    left.forEach((s, i) => {
      const d = distanceKm(cur, s.point);
      if (d < bestD - 1e-12 || (Math.abs(d - bestD) <= 1e-12 && s.id < left[best]!.id)) {
        bestD = d;
        best = i;
      }
    });
    const [s] = left.splice(best, 1);
    order.push(s!);
    cur = s!.point;
  }

  // 2) 2-opt iyileştirme (başlangıç sabit)
  let improved = true;
  let guard = 0;
  while (improved && guard++ < 200) {
    improved = false;
    for (let i = 0; i < order.length - 1; i++) {
      for (let k = i + 1; k < order.length; k++) {
        const cand = [...order.slice(0, i), ...order.slice(i, k + 1).reverse(), ...order.slice(k + 1)];
        if (pathLength(start, cand.map((s) => s.point), back) + 1e-9 < pathLength(start, order.map((s) => s.point), back)) {
          order.splice(0, order.length, ...cand);
          improved = true;
        }
      }
    }
  }

  const legsKm: number[] = [];
  let prev = start;
  for (const s of order) {
    legsKm.push(distanceKm(prev, s.point));
    prev = s.point;
  }
  const totalKm = legsKm.reduce((a, b) => a + b, 0) + (back && order.length ? distanceKm(prev, start) : 0);
  return { stops: order, legsKm, totalKm };
}

/**
 * Google Maps yol tarifi bağlantıları. Google bir bağlantıda en fazla 9 ara durak kabul eder;
 * fazlası sıradaki bağlantıya bölünür (her parça bir öncekinin son durağından başlar).
 */
export function googleRouteLinks(start: LatLng, points: LatLng[], back = false, perLink = 10): string[] {
  const all = back && points.length ? [...points, start] : points;
  const links: string[] = [];
  let origin = start;
  for (let i = 0; i < all.length; i += perLink) {
    const part = all.slice(i, i + perLink);
    const dest = part[part.length - 1]!;
    const way = part.slice(0, -1).map((p) => `${p.lat},${p.lng}`).join("|");
    const u = new URL("https://www.google.com/maps/dir/");
    u.searchParams.set("api", "1");
    u.searchParams.set("origin", `${origin.lat},${origin.lng}`);
    u.searchParams.set("destination", `${dest.lat},${dest.lng}`);
    if (way) u.searchParams.set("waypoints", way);
    u.searchParams.set("travelmode", "driving");
    links.push(u.toString());
    origin = dest;
  }
  return links;
}
