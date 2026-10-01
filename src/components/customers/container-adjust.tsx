"use client";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { useRpc } from "@/lib/use-action";

/** Yönetici: müşterideki damacana/kap sayısını açılış veya sayım için düzeltir (D-049). */
export function ContainerAdjust({ customerId, products, current }: {
  customerId: string;
  products: { id: string; name: string }[];
  current: Record<string, number>;
}) {
  const { call, busy } = useRpc();
  const [open, setOpen] = useState(false);
  const [product, setProduct] = useState(products[0]?.id ?? "");
  const [qty, setQty] = useState("");
  const [note, setNote] = useState("");
  if (products.length === 0) return null;
  const now = current[product] ?? 0;

  return (
    <>
      <Button variant="secondary" onClick={() => { setQty(String(current[product] ?? 0)); setOpen(true); }}>Kap sayısını düzelt</Button>
      <Dialog
        open={open}
        onClose={() => setOpen(false)}
        title="Müşterideki kap sayısı"
        footer={
          <Button
            className="w-full"
            loading={busy}
            disabled={qty.trim() === "" || Number(qty) === now}
            onClick={async () => {
              const ok = await call("set_customer_containers", { p_customer: customerId, p_product: product, p_qty: Number(qty), p_note: note || null }, { success: "Kap sayısı güncellendi" });
              if (ok) setOpen(false);
            }}
          >
            Kaydet
          </Button>
        }
      >
        <div className="space-y-3">
          <Field label="Ürün">
            <Select value={product} onChange={(e) => { setProduct(e.target.value); setQty(String(current[e.target.value] ?? 0)); }}>
              {products.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
            </Select>
          </Field>
          <Field label="Müşterideki adet" hint={`Şu an sistemde: ${now}. Fark, kap hareketlerine "açılış/düzeltme" olarak yazılır; geçmiş silinmez.`}>
            <Input inputMode="numeric" value={qty} onChange={(e) => setQty(e.target.value.replace(/\D/g, ""))} />
          </Field>
          <Field label="Not"><Input value={note} onChange={(e) => setNote(e.target.value)} placeholder="Örn. açılış sayımı" /></Field>
        </div>
      </Dialog>
    </>
  );
}
