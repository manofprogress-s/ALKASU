"use client";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/field";
import { useRpc } from "@/lib/use-action";
import { formatTRY, parseAmount } from "@/lib/format";

export function ApproveCosts({ purchaseId, items }: { purchaseId: string; items: { id: string; name: string; unit: string; qty: number; free: number }[] }) {
  const { call, busy } = useRpc();
  const [cost, setCost] = useState<Record<string, string>>({});
  const parsed = items.map((i) => ({ i, c: parseAmount(cost[i.id] ?? "") }));
  const total = parsed.reduce((s, x) => s + (x.c ?? 0) * x.i.qty, 0);
  const ready = parsed.every((x) => x.c !== null && x.c >= 0);
  return (
    <Card className="space-y-3">
      <h2 className="font-semibold">Alış fiyatlarını onayla</h2>
      <p className="text-sm text-muted">Birim başına KDV dahil alış fiyatı. Onayla birlikte ağırlıklı ortalama maliyet güncellenir ve kayıt kilitlenir.</p>
      {items.map((i) => (
        <div key={i.id} className="grid grid-cols-[1fr_140px] items-center gap-2">
          <span className="text-sm">{i.name}<span className="block text-xs text-muted">{i.qty} {i.unit}{i.free ? ` + ${i.free} bedelsiz` : ""}</span></span>
          <Input inputMode="decimal" placeholder={`₺ / ${i.unit}`} value={cost[i.id] ?? ""} onChange={(e) => setCost((c) => ({ ...c, [i.id]: e.target.value }))} />
        </div>
      ))}
      <div className="num flex justify-between font-semibold"><span>Toplam</span><span>{formatTRY(total)}</span></div>
      <Button className="w-full" variant="ok" disabled={!ready} loading={busy}
        onClick={() => call("approve_purchase", { p_purchase: purchaseId, p_costs: parsed.map((x) => ({ item_id: x.i.id, unit_cost: x.c })) }, { success: "Mal kabul onaylandı" })}>
        Onayla
      </Button>
    </Card>
  );
}
