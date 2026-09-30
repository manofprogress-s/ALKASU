"use client";
import { useState } from "react";
import { useRouter } from "next/navigation";
import { X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/field";
import { useAppContext } from "@/components/shell/context";
import { useRpc } from "@/lib/use-action";
import type { LiteProduct } from "@/lib/products-lite";
import { ProductSelect } from "./product-select";

export function StartCount({ products }: { products: LiteProduct[] }) {
  const ctx = useAppContext();
  const router = useRouter();
  const { call, busy } = useRpc();
  const [selected, setSelected] = useState<LiteProduct[]>([]);
  const [pick, setPick] = useState(false);
  const [note, setNote] = useState("");

  async function start(full: boolean) {
    const id = crypto.randomUUID();
    const r = await call("start_stock_count", { p_business: ctx.businessId, p: { id, note, product_ids: full ? [] : selected.map((p) => p.id) } }, { refresh: false });
    if (r) router.push(`/stok/sayim/${id}`);
  }

  return (
    <Card className="space-y-3">
      <h2 className="font-semibold">Yeni sayım</h2>
      <p className="text-sm text-muted">Mümkünse satış yapılmayan bir saatte sayın. Sayım sırasında satış olursa fark yine doğru hesaplanır.</p>
      <Field label="Not"><Input value={note} onChange={(e) => setNote(e.target.value)} placeholder="Ör. Ay sonu sayımı" /></Field>
      <div className="flex flex-wrap gap-2">
        {selected.map((p) => (
          <span key={p.id} className="inline-flex items-center gap-1 rounded-full bg-surface-2 px-3 py-1 text-sm">
            {p.name}
            <button onClick={() => setSelected((s) => s.filter((x) => x.id !== p.id))} aria-label="Kaldır"><X className="h-3.5 w-3.5" /></button>
          </span>
        ))}
      </div>
      <div className="flex flex-wrap gap-2">
        <Button loading={busy} onClick={() => start(true)}>Tam sayım başlat</Button>
        <Button variant="secondary" onClick={() => setPick(true)}>Ürün seçerek kısmi sayım</Button>
        {selected.length ? <Button variant="secondary" loading={busy} onClick={() => start(false)}>Seçili {selected.length} ürünü say</Button> : null}
      </div>
      <ProductSelect open={pick} onClose={() => setPick(false)} products={products.filter((p) => !selected.some((s) => s.id === p.id))}
        onPick={(p) => setSelected((s) => [...s, p])} />
    </Card>
  );
}
