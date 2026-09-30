"use client";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Field, Input, Select } from "@/components/ui/field";
import { useAppContext } from "@/components/shell/context";
import { useRpc } from "@/lib/use-action";
import type { LiteProduct } from "@/lib/products-lite";
import { ProductSelect } from "./product-select";

export function WasteForm({ products }: { products: LiteProduct[] }) {
  const ctx = useAppContext();
  const { call, busy } = useRpc();
  const [pick, setPick] = useState(false);
  const [product, setProduct] = useState<LiteProduct | null>(null);
  const [unitId, setUnitId] = useState("");
  const [qty, setQty] = useState("");
  const [reason, setReason] = useState("kirik");
  const [note, setNote] = useState("");

  async function save() {
    if (!product) return;
    const ok = await call("record_waste", {
      p_business: ctx.businessId,
      p: { id: crypto.randomUUID(), product_id: product.id, unit_id: unitId || null, qty: parseInt(qty, 10), reason, note },
    }, { success: "Fire kaydedildi" });
    if (ok) { setProduct(null); setQty(""); setNote(""); }
  }

  return (
    <Card className="grid gap-3 md:grid-cols-2">
      <Field label="Ürün">
        <Button variant="secondary" className="w-full justify-start" onClick={() => setPick(true)}>{product ? product.name : "Ürün seç"}</Button>
      </Field>
      <div className="grid grid-cols-2 gap-2">
        <Field label="Miktar"><Input inputMode="numeric" value={qty} onChange={(e) => setQty(e.target.value.replace(/\D/g, ""))} /></Field>
        <Field label="Birim">
          <Select value={unitId} onChange={(e) => setUnitId(e.target.value)} disabled={!product}>
            {product?.units.map((u) => <option key={u.id} value={u.factor === 1 ? "" : u.id}>{u.name}{u.factor > 1 ? ` (${u.factor})` : ""}</option>)}
          </Select>
        </Field>
      </div>
      <Field label="Neden">
        <Select value={reason} onChange={(e) => setReason(e.target.value)}>
          <option value="kirik">Kırık</option><option value="sizinti">Sızıntı</option><option value="skt">SKT geçmiş</option>
          <option value="kayip">Kayıp / çalıntı</option><option value="diger">Diğer</option>
        </Select>
      </Field>
      <Field label="Not"><Input value={note} onChange={(e) => setNote(e.target.value)} /></Field>
      <Button className="md:col-span-2" loading={busy} disabled={!product || !qty || qty === "0"} onClick={save}>Fireyi kaydet</Button>
      <ProductSelect open={pick} onClose={() => setPick(false)} products={products} onPick={(p) => { setProduct(p); setUnitId(""); setPick(false); }} />
    </Card>
  );
}
