"use client";
import { useMemo, useState } from "react";
import Link from "next/link";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { MapPinOff, Navigation, Phone, Save } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge, Card, Stat } from "@/components/ui/card";
import { Input, Select } from "@/components/ui/field";
import { useRpc } from "@/lib/use-action";
import { googleRouteLinks, planRoute, type Stop } from "@/lib/route";
import type { LatLng } from "@/lib/geo";
import { formatNumber } from "@/lib/format";

export interface RouteOrder {
  id: string;
  no: number;
  customer: string;
  phone: string | null;
  address: string | null;
  late: boolean;
  point: LatLng | null;
  summary: string;
}

export function RoutePlanner({ start, orders, day, who, people, me, canChooseWho, businessId }: {
  start: LatLng | null;
  orders: RouteOrder[];
  day: string;
  who: string;
  people: { id: string; name: string }[];
  me: string;
  canChooseWho: boolean;
  businessId: string;
}) {
  const router = useRouter();
  const path = usePathname();
  const params = useSearchParams();
  const { call, busy } = useRpc();
  const [back, setBack] = useState(false);

  const missing = orders.filter((o) => !o.point);
  const plan = useMemo(() => {
    if (!start) return null;
    const stops: Stop<RouteOrder>[] = orders.flatMap((o) => (o.point ? [{ id: o.id, point: o.point, data: o }] : []));
    return planRoute(start, stops, back);
  }, [start, orders, back]);
  const links = plan && start ? googleRouteLinks(start, plan.stops.map((s) => s.point), back) : [];

  const go = (patch: Record<string, string>) => {
    const p = new URLSearchParams(params.toString());
    for (const [k, v] of Object.entries(patch)) p.set(k, v);
    router.push(`${path}?${p.toString()}`);
  };

  return (
    <div className="space-y-4">
      <Card className="flex flex-wrap items-end gap-3">
        <label className="space-y-1">
          <span className="block text-sm font-medium">Teslim günü (ve gecikmiş)</span>
          <Input type="date" className="h-10 w-auto" value={day} onChange={(e) => e.target.value && go({ gun: e.target.value })} />
        </label>
        {canChooseWho ? (
          <label className="space-y-1">
            <span className="block text-sm font-medium">Kimin rotası</span>
            <Select className="h-10 w-56" value={who} onChange={(e) => go({ kim: e.target.value })}>
              <option value={me}>Benim siparişlerim</option>
              {people.filter((p) => p.id !== me).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
              <option value="atanmamis">Atanmamış siparişler</option>
              <option value="hepsi">Tümü (bayiye verilmemiş)</option>
            </Select>
          </label>
        ) : null}
        <label className="flex h-10 items-center gap-2 text-sm">
          <input type="checkbox" className="h-5 w-5" checked={back} onChange={(e) => setBack(e.target.checked)} /> Depoya dönüş dahil
        </label>
      </Card>

      {plan ? (
        <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
          <Stat label="Durak" value={plan.stops.length} />
          <Stat label="Toplam mesafe (kuş uçuşu)" value={`${formatNumber(Math.round(plan.totalKm * 10) / 10)} km`} hint="Yol mesafesi biraz daha uzundur" />
          {missing.length ? <Stat label="Konumu olmayan" value={missing.length} tone="warn" /> : null}
        </div>
      ) : null}

      {plan && plan.stops.length ? (
        <Card className="space-y-3">
          <div className="flex flex-wrap gap-2">
            {links.map((u, i) => (
              <a key={u} href={u} target="_blank" rel="noreferrer" className="inline-flex h-11 items-center gap-2 rounded-xl bg-brand px-4 font-medium text-white">
                <Navigation className="h-4 w-4" /> {links.length > 1 ? `Google Maps ${i + 1}. kısım` : "Google Maps'te rotayı başlat"}
              </a>
            ))}
            <Button variant="secondary" loading={busy} onClick={() => void call("set_route", { p_business: businessId, p_orders: plan.stops.map((s) => s.id) }, { success: "Teslimat sırası kaydedildi" })}>
              <Save className="h-4 w-4" /> Sırayı kaydet
            </Button>
          </div>
          {links.length > 1 ? <p className="text-xs text-muted">Google Maps bir seferde en fazla 10 durak açar; rota parçalara bölündü. Bir parça bitince sonrakini açın.</p> : null}
          <ol className="divide-y divide-border">
            {plan.stops.map((s, i) => (
              <li key={s.id} className="flex items-start gap-3 py-2">
                <span className="num flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-brand text-sm font-semibold text-white">{i + 1}</span>
                <span className="min-w-0 flex-1">
                  <Link href={`/siparisler/${s.id}`} className="font-medium text-brand">#{s.data.no} · {s.data.customer}</Link>
                  {s.data.late ? <Badge tone="danger" className="ml-1">Gecikmiş</Badge> : null}
                  <span className="block text-sm">{s.data.summary}</span>
                  {s.data.address ? <span className="line-clamp-1 block text-xs text-muted">{s.data.address}</span> : null}
                </span>
                <span className="flex shrink-0 flex-col items-end gap-1">
                  <span className="num text-xs text-muted">+{formatNumber(Math.round(plan.legsKm[i]! * 10) / 10)} km</span>
                  {s.data.phone ? <a href={`tel:${s.data.phone}`} aria-label="Ara" className="rounded-full p-1.5 text-brand hover:bg-surface-2"><Phone className="h-4 w-4" /></a> : null}
                </span>
              </li>
            ))}
          </ol>
        </Card>
      ) : orders.length === 0 ? (
        <Card className="text-center text-muted">Bu seçimde açık sipariş yok.</Card>
      ) : null}

      {missing.length ? (
        <Card className="space-y-2">
          <h2 className="flex items-center gap-2 font-semibold"><MapPinOff className="h-5 w-5 text-warn" /> Konumu olmayan siparişler</h2>
          <p className="text-sm text-muted">Bunlar rotaya eklenemedi. Müşteri kartına konum girildiğinde otomatik eklenir.</p>
          <ul className="divide-y divide-border">
            {missing.map((o) => (
              <li key={o.id} className="py-2 text-sm">
                <Link href={`/siparisler/${o.id}`} className="font-medium text-brand">#{o.no} · {o.customer}</Link>
                <span className="block text-muted">{o.address ?? "Adres yok"}</span>
              </li>
            ))}
          </ul>
        </Card>
      ) : null}
    </div>
  );
}
