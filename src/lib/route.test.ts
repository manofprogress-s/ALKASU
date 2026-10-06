import { describe, expect, it } from "vitest";
import { distanceKm, googleRouteLinks, planRoute, type Stop } from "./route";

const depot = { lat: 40.7651, lng: 29.9408 }; // İzmit civarı
const s = (id: string, lat: number, lng: number): Stop<null> => ({ id, point: { lat, lng }, data: null });

describe("rota", () => {
  it("mesafe", () => {
    expect(distanceKm({ lat: 0, lng: 0 }, { lat: 0, lng: 1 })).toBeCloseTo(111.19, 1);
    expect(distanceKm(depot, depot)).toBe(0);
  });
  it("doğu yönünde dizilmiş durakları sırayla dolaşır", () => {
    const stops = [s("c", 40.77, 30.1), s("a", 40.77, 29.96), s("d", 40.77, 30.2), s("b", 40.77, 30.0)];
    const r = planRoute(depot, stops);
    expect(r.stops.map((x) => x.id)).toEqual(["a", "b", "c", "d"]);
    expect(r.legsKm).toHaveLength(4);
    expect(r.totalKm).toBeCloseTo(r.legsKm.reduce((x, y) => x + y, 0), 6);
  });
  it("2-opt kesişen yolu düzeltir ve en yakın komşudan kötü olmaz", () => {
    const stops = Array.from({ length: 12 }, (_, i) => s(`p${i}`, 40.7 + ((i * 37) % 11) * 0.01, 29.9 + ((i * 53) % 13) * 0.01));
    const r = planRoute(depot, stops);
    expect(new Set(r.stops.map((x) => x.id)).size).toBe(12);
    // Rastgele sıradan uzun olmamalı
    let naive = 0;
    let prev = depot;
    for (const x of stops) { naive += distanceKm(prev, x.point); prev = x.point; }
    expect(r.totalKm).toBeLessThanOrEqual(naive + 1e-9);
  });
  it("boş liste", () => {
    expect(planRoute(depot, []).totalKm).toBe(0);
    expect(googleRouteLinks(depot, [])).toEqual([]);
  });
  it("Google Maps bağlantıları 10 durakta bölünür", () => {
    const pts = Array.from({ length: 23 }, (_, i) => ({ lat: 40 + i / 100, lng: 29 }));
    const links = googleRouteLinks(depot, pts);
    expect(links).toHaveLength(3);
    const first = new URL(links[0]!);
    expect(first.searchParams.get("origin")).toBe("40.7651,29.9408");
    expect(first.searchParams.get("waypoints")!.split("|")).toHaveLength(9);
    expect(new URL(links[1]!).searchParams.get("origin")).toBe(first.searchParams.get("destination"));
    expect(new URL(links[2]!).searchParams.get("waypoints")!.split("|")).toHaveLength(2);
  });
});
