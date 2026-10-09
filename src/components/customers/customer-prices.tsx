"use client";
import { useMemo, useState } from "react";
import { Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input, Select } from "@/components/ui/field";
import { useRpc } from "@/lib/use-action";
import { formatTRY, parseAmount } from "@/lib/format";
import { unitPrice } from "@/lib/catalog";
import type { OrderProduct } from "@/lib/orders";
import type { PriceList } from "@/lib/roles";

/** Firmaya özel fiyatlar (F-13): yönetici düzenler, satış personeli görür */
export function CustomerPrices({ customerId, prices, products, priceList, canEdit }: {
  customerId: string;
  prices: Record<string, number>;
  products: OrderProduct[];
  priceList: PriceList;
  canEdit: boolean;
}) {
  const { call, busy } = useRpc();
  const [productId, setProductId] = useState("");
  const [unitId, setUnitId] = useState("");
  const [price, setPrice] = useState("");

  const rows = useMemo(() => {
    const out: { unitId: string; product: string; unit: string; price: number; normal: number | null }[] = [];
    for (const p of products)
      for (const u of p.units)
        if (prices[u.id] !== undefined) out.push({ unitId: u.id, product: p.name, unit: u.name, price: prices[u.id]!, normal: unitPrice(u, priceList) });
    return out.sort((a, b) => a.product.localeCompare(b.product, "tr"));
  }, [products, prices, priceList]);

  const product = products.find((p) => p.id === productId);
  const parsed = parseAmount(price);

  return (
    <Card className="space-y-3">
      <h2 className="font-semibold">Firmaya özel fiyatlar</h2>
      {rows.length === 0 ? (
        <p className="text-sm text-muted">Özel fiyat yok; {priceList === "perakende" ? "perakende" : priceList} fiyatları uygulanır.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="text-left text-xs text-muted">
              <tr><th className="py-1">Ürün</th><th className="py-1">Birim</th><th className="py-1 text-right">Özel fiyat</th><th className="py-1 text-right">Normal</th>{canEdit ? <th /> : null}</tr>
            </thead>
            <tbody className="divide-y divide-border">
              {rows.map((r) => (
                <tr key={r.unitId}>
                  <td className="py-1.5">{r.product}</td>
                  <td className="py-1.5">{r.unit}</td>
                  <td className="num py-1.5 text-right font-semibold">{formatTRY(r.price)}</td>
                  <td className="num py-1.5 text-right text-muted">{r.normal !== null ? formatTRY(r.normal) : "—"}</td>
                  {canEdit ? (
                    <td className="py-1.5 text-right">
                      <Button size="sm" variant="ghost" aria-label="Kaldır" disabled={busy}
                        onClick={() => void call("set_customer_price", { p_customer: customerId, p_unit: r.unitId, p_price: null }, { success: "Özel fiyat kaldırıldı" })}>
                        <Trash2 className="h-4 w-4" />
                      </Button>
                    </td>
                  ) : null}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {canEdit ? (
        <div className="flex flex-wrap items-end gap-2 rounded-xl bg-surface-2 p-3">
          <Select className="h-10 min-w-0 flex-1 basis-48" value={productId} onChange={(e) => {
            const p = products.find((x) => x.id === e.target.value);
            setProductId(e.target.value);
            setUnitId(p?.units.find((u) => u.price !== null)?.id ?? p?.units[0]?.id ?? "");
          }} aria-label="Ürün">
            <option value="">Ürün seçin…</option>
            {products.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
          </Select>
          <Select className="h-10 w-32" value={unitId} onChange={(e) => setUnitId(e.target.value)} disabled={!product} aria-label="Birim">
            {(product?.units ?? []).map((u) => <option key={u.id} value={u.id}>{u.name}{u.factor > 1 ? ` (${u.factor})` : ""}</option>)}
          </Select>
          <Input className="num h-10 w-28 text-right" inputMode="decimal" placeholder="₺" value={price} onChange={(e) => setPrice(e.target.value)} aria-label="Özel fiyat" />
          <Button disabled={!unitId || parsed === null || parsed < 0} loading={busy} onClick={async () => {
            const ok = await call("set_customer_price", { p_customer: customerId, p_unit: unitId, p_price: parsed }, { success: "Özel fiyat kaydedildi" });
            if (ok) { setPrice(""); setProductId(""); setUnitId(""); }
          }}>Kaydet</Button>
        </div>
      ) : null}
    </Card>
  );
}
