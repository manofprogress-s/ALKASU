"use client";
import { useState } from "react";
import { useRouter } from "next/navigation";
import { Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Alert, Card } from "@/components/ui/card";
import { Field, Input, Select } from "@/components/ui/field";
import { useAppContext } from "@/components/shell/context";
import { useToast } from "@/components/ui/toast";
import { ProductSelect } from "@/components/stock/product-select";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import { parseAmount, todayISO } from "@/lib/format";
import type { LiteProduct } from "@/lib/products-lite";

interface Line { key: string; product: LiteProduct; unitId: string; qty: string; free: string; cost: string }

export function PurchaseForm({ products, suppliers }: { products: LiteProduct[]; suppliers: { id: string; name: string }[] }) {
  const ctx = useAppContext();
  const router = useRouter();
  const toast = useToast();
  const isAdmin = ctx.role === "yonetici";
  const [id] = useState(() => crypto.randomUUID());
  const [supplierList, setSupplierList] = useState(suppliers);
  const [supplierId, setSupplierId] = useState("");
  const [docNo, setDocNo] = useState("");
  const [docDate, setDocDate] = useState(todayISO());
  const [lines, setLines] = useState<Line[]>([]);
  const [empties, setEmpties] = useState<{ key: string; product: LiteProduct; qty: string }[]>([]);
  const [pick, setPick] = useState<"item" | "empty" | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const upd = (key: string, patch: Partial<Line>) => setLines((l) => l.map((x) => (x.key === key ? { ...x, ...patch } : x)));

  async function addSupplier() {
    const name = prompt("Tedarikçi adı")?.trim();
    if (!name) return;
    const { data, error } = await supabaseBrowser().rpc("upsert_supplier", { p_business: ctx.businessId, p: { name } });
    if (error) return toast(errorMessage(error), "danger");
    setSupplierList((s) => [...s, { id: data as string, name }]);
    setSupplierId(data as string);
  }

  async function save() {
    setError(null);
    const items = lines.map((l) => ({
      product_id: l.product.id, unit_id: l.unitId, qty: parseInt(l.qty || "0", 10), free_qty: parseInt(l.free || "0", 10),
      unit_cost: isAdmin && l.cost.trim() ? parseAmount(l.cost) : null,
    }));
    if (items.some((i) => i.qty + i.free_qty <= 0)) return setError("Her kalem için miktar girin");
    if (isAdmin && lines.some((l) => l.cost.trim() && parseAmount(l.cost) === null)) return setError("Alış fiyatı geçersiz");
    setSaving(true);
    const { data, error } = await supabaseBrowser().rpc("receive_goods", {
      p_business: ctx.businessId,
      p: { id, supplier_id: supplierId || null, doc_no: docNo, doc_date: docDate, items,
           empties: empties.map((e) => ({ product_id: e.product.id, qty: parseInt(e.qty || "0", 10) })).filter((e) => e.qty > 0) },
    });
    setSaving(false);
    if (error) return setError(errorMessage(error));
    const r = data as { status: string };
    toast(r.status === "onaylandi" ? "Mal kabul kaydedildi ve onaylandı" : "Mal kabul kaydedildi, fiyat onayı bekliyor", "ok");
    router.push(`/mal-kabul/${id}`);
  }

  return (
    <div className="space-y-4">
      <Card className="grid gap-3 md:grid-cols-3">
        <Field label="Tedarikçi" hint={<button type="button" className="text-brand" onClick={addSupplier}>+ Yeni tedarikçi</button>}>
          <Select value={supplierId} onChange={(e) => setSupplierId(e.target.value)}>
            <option value="">Seçin (isteğe bağlı)</option>
            {supplierList.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </Select>
        </Field>
        <Field label="İrsaliye / fatura no"><Input value={docNo} onChange={(e) => setDocNo(e.target.value)} /></Field>
        <Field label="Belge tarihi"><Input type="date" value={docDate} onChange={(e) => setDocDate(e.target.value)} /></Field>
      </Card>

      <Card className="space-y-3">
        <h2 className="font-semibold">Gelen ürünler</h2>
        {lines.map((l) => (
          <div key={l.key} className="rounded-xl border border-border p-3">
            <div className="mb-2 flex items-center justify-between">
              <span className="font-medium">{l.product.name}</span>
              <Button variant="ghost" size="icon" onClick={() => setLines((x) => x.filter((y) => y.key !== l.key))} aria-label="Kaldır"><Trash2 className="h-4 w-4" /></Button>
            </div>
            <div className={`grid gap-2 ${isAdmin ? "grid-cols-2 md:grid-cols-4" : "grid-cols-3"}`}>
              <Field label="Birim">
                <Select value={l.unitId} onChange={(e) => upd(l.key, { unitId: e.target.value })}>
                  {l.product.units.map((u) => <option key={u.id} value={u.id}>{u.name}{u.factor > 1 ? ` (${u.factor})` : ""}</option>)}
                </Select>
              </Field>
              <Field label="Miktar"><Input inputMode="numeric" value={l.qty} onChange={(e) => upd(l.key, { qty: e.target.value.replace(/\D/g, "") })} /></Field>
              <Field label="Bedelsiz"><Input inputMode="numeric" value={l.free} onChange={(e) => upd(l.key, { free: e.target.value.replace(/\D/g, "") })} placeholder="0" /></Field>
              {isAdmin ? <Field label="Birim alış fiyatı ₺" hint="KDV dahil, seçili birim için"><Input inputMode="decimal" value={l.cost} onChange={(e) => upd(l.key, { cost: e.target.value })} /></Field> : null}
            </div>
          </div>
        ))}
        <Button variant="secondary" onClick={() => setPick("item")}><Plus className="h-4 w-4" /> Ürün ekle</Button>
      </Card>

      <Card className="space-y-3">
        <h2 className="font-semibold">Tedarikçiye verilen boş kaplar</h2>
        {empties.map((e) => (
          <div key={e.key} className="grid grid-cols-[1fr_100px_44px] items-center gap-2">
            <span>{e.product.name}</span>
            <Input inputMode="numeric" value={e.qty} onChange={(ev) => setEmpties((x) => x.map((y) => (y.key === e.key ? { ...y, qty: ev.target.value.replace(/\D/g, "") } : y)))} aria-label="Adet" />
            <Button variant="ghost" size="icon" onClick={() => setEmpties((x) => x.filter((y) => y.key !== e.key))} aria-label="Kaldır"><Trash2 className="h-4 w-4" /></Button>
          </div>
        ))}
        <Button variant="secondary" onClick={() => setPick("empty")}><Plus className="h-4 w-4" /> Boş kap ekle</Button>
      </Card>

      {error ? <Alert>{error}</Alert> : null}
      <Button size="lg" className="w-full" loading={saving} disabled={lines.length === 0 && empties.length === 0} onClick={save}>Mal kabulü kaydet</Button>

      <ProductSelect open={pick !== null} onClose={() => setPick(null)} products={products}
        filter={pick === "empty" ? (p) => p.isContainer : undefined}
        onPick={(p) => {
          if (pick === "empty") setEmpties((x) => [...x, { key: crypto.randomUUID(), product: p, qty: "" }]);
          else {
            const biggest = [...p.units].sort((a, b) => b.factor - a.factor)[0];
            setLines((x) => [...x, { key: crypto.randomUUID(), product: p, unitId: biggest?.id ?? "", qty: "", free: "", cost: "" }]);
          }
          setPick(null);
        }} />
    </div>
  );
}
