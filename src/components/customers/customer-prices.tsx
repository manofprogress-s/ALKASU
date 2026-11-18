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
export function CustomerPrices({ customerId, prices, deposits, products, priceList, canEdit }: {
  customerId: string;
  prices: Record<string, number>;
  /** Müşteriye özel depozito (F-37): ürün → kap başına tutar */
  deposits: Record<string, number>;
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
      <CustomerDeposits customerId={customerId} deposits={deposits} products={products} canEdit={canEdit} />
    </Card>
  );
}

/** Müşteriye özel depozito (F-37): ör. bayiye tüp depozitosu. Boşsa ürün kartındaki depozito uygulanır. */
function CustomerDeposits({ customerId, deposits, products, canEdit }: {
  customerId: string; deposits: Record<string, number>; products: OrderProduct[]; canEdit: boolean;
}) {
  const { call, busy } = useRpc();
  const [productId, setProductId] = useState("");
  const [amount, setAmount] = useState("");
  const withDeposit = products.filter((p) => p.deposit !== null);
  const rows = withDeposit.filter((p) => deposits[p.id] !== undefined);
  const parsed = parseAmount(amount);
  if (!rows.length && !canEdit) return null;
  return (
    <div className="space-y-2 border-t border-border pt-3">
      <h3 className="text-sm font-semibold">Özel depozito</h3>
      {rows.length === 0 ? <p className="text-sm text-muted">Yok; ürün kartındaki depozito uygulanır.</p> : (
        <ul className="divide-y divide-border text-sm">
          {rows.map((p) => (
            <li key={p.id} className="flex items-center justify-between gap-2 py-1.5">
              <span>{p.name}</span>
              <span className="flex items-center gap-3">
                <span className="num font-semibold">{formatTRY(deposits[p.id]!)}</span>
                <span className="num text-xs text-muted">normal {formatTRY(p.deposit ?? 0)}</span>
                {canEdit ? (
                  <Button size="sm" variant="ghost" aria-label="Kaldır" disabled={busy}
                    onClick={() => void call("set_customer_deposit", { p_customer: customerId, p_product: p.id, p_amount: null }, { success: "Özel depozito kaldırıldı" })}>
                    <Trash2 className="h-4 w-4" />
                  </Button>
                ) : null}
              </span>
            </li>
          ))}
        </ul>
      )}
      {canEdit ? (
        <div className="flex flex-wrap items-end gap-2 rounded-xl bg-surface-2 p-3">
          <Select className="h-10 min-w-0 flex-1 basis-48" value={productId} onChange={(e) => setProductId(e.target.value)} aria-label="Depozitolu ürün">
            <option value="">Depozitolu ürün seçin…</option>
            {withDeposit.map((p) => <option key={p.id} value={p.id}>{p.name} (normal {formatTRY(p.deposit ?? 0)})</option>)}
          </Select>
          <Input className="num h-10 w-28 text-right" inputMode="decimal" placeholder="₺" value={amount} onChange={(e) => setAmount(e.target.value)} aria-label="Özel depozito" />
          <Button disabled={!productId || parsed === null || parsed <= 0} loading={busy} onClick={async () => {
            const ok = await call("set_customer_deposit", { p_customer: customerId, p_product: productId, p_amount: parsed }, { success: "Özel depozito kaydedildi" });
            if (ok) { setAmount(""); setProductId(""); }
          }}>Kaydet</Button>
        </div>
      ) : null}
    </div>
  );
}
