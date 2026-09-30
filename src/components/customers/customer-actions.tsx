"use client";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { Card } from "@/components/ui/card";
import { useAppContext } from "@/components/shell/context";
import { useRpc } from "@/lib/use-action";
import { formatDateTime, formatTRY, parseAmount } from "@/lib/format";

export function CustomerActions({ customerId, isAdmin, containers, payments }: {
  customerId: string;
  isAdmin: boolean;
  containers: { product_id: string; product_name: string; qty: number; amount: number }[];
  payments: { id: string; method: string; amount: number; status: string; created_at: string }[];
}) {
  const ctx = useAppContext();
  const { call, busy } = useRpc();
  const [pay, setPay] = useState(false);
  const [amount, setAmount] = useState("");
  const [method, setMethod] = useState("nakit");
  const [note, setNote] = useState("");
  const [cr, setCr] = useState(false);
  const [crProduct, setCrProduct] = useState(containers[0]?.product_id ?? "");
  const [crQty, setCrQty] = useState("1");
  const [crKind, setCrKind] = useState("iade");
  const [crMethod, setCrMethod] = useState("nakit");
  const [payId] = useState(() => crypto.randomUUID());

  return (
    <Card className="space-y-3">
      <div className="flex flex-wrap gap-2">
        <Button onClick={() => setPay(true)}>Tahsilat al</Button>
        {containers.length ? <Button variant="secondary" onClick={() => setCr(true)}>Kap iadesi / depozito</Button> : null}
      </div>
      {payments.length ? (
        <details>
          <summary className="cursor-pointer text-sm text-muted">Son tahsilatlar</summary>
          <ul className="mt-2 space-y-1 text-sm">
            {payments.map((p) => (
              <li key={p.id} className="flex items-center justify-between gap-2">
                <span>{formatDateTime(p.created_at)} · {p.method === "nakit" ? "Nakit" : "POS"} {p.status === "iptal" ? "(iptal)" : ""}</span>
                <span className="flex items-center gap-2">
                  <span className="num">{formatTRY(p.amount)}</span>
                  {isAdmin && p.status === "gecerli" ? (
                    <Button size="sm" variant="ghost" onClick={() => {
                      const reason = prompt("İptal nedeni");
                      if (reason) void call("cancel_customer_payment", { p_payment: p.id, p_reason: reason }, { success: "Tahsilat iptal edildi" });
                    }}>İptal</Button>
                  ) : null}
                </span>
              </li>
            ))}
          </ul>
        </details>
      ) : null}

      <Dialog open={pay} onClose={() => setPay(false)} title="Tahsilat"
        footer={<Button className="w-full" loading={busy} disabled={!parseAmount(amount)}
          onClick={async () => {
            const ok = await call("record_customer_payment", { p_business: ctx.businessId, p: { id: payId, customer_id: customerId, method, amount: parseAmount(amount), note } }, { success: "Tahsilat kaydedildi" });
            if (ok) { setPay(false); setAmount(""); setNote(""); window.location.reload(); }
          }}>Kaydet</Button>}>
        <div className="space-y-3">
          <Field label="Tutar ₺"><Input autoFocus inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} /></Field>
          <Field label="Ödeme şekli"><Select value={method} onChange={(e) => setMethod(e.target.value)}><option value="nakit">Nakit</option><option value="pos">POS</option></Select></Field>
          <Field label="Not"><Input value={note} onChange={(e) => setNote(e.target.value)} /></Field>
        </div>
      </Dialog>

      <Dialog open={cr} onClose={() => setCr(false)} title="Kap iadesi / depozito"
        footer={<Button className="w-full" loading={busy} disabled={!parseInt(crQty, 10)}
          onClick={async () => {
            const r = await call<{ amount: number }>("container_return", { p_business: ctx.businessId, p: { id: crypto.randomUUID(), customer_id: customerId, product_id: crProduct, qty: parseInt(crQty, 10), kind: crKind, refund_method: crMethod } });
            if (r) { setCr(false); alert(crKind === "iade" ? `İade edilen depozito: ${formatTRY(r.amount)}` : "Kap kaybı işlendi"); }
          }}>Kaydet</Button>}>
        <div className="space-y-3">
          <Field label="Ürün"><Select value={crProduct} onChange={(e) => setCrProduct(e.target.value)}>{containers.map((c) => <option key={c.product_id} value={c.product_id}>{c.product_name} (elinde {c.qty})</option>)}</Select></Field>
          <Field label="Kap adedi"><Input inputMode="numeric" value={crQty} onChange={(e) => setCrQty(e.target.value.replace(/\D/g, ""))} /></Field>
          <Field label="İşlem">
            <Select value={crKind} onChange={(e) => setCrKind(e.target.value)}>
              <option value="iade">Boş kabı getirdi, depozito iade</option>
              {isAdmin ? <option value="kayip">Kap kayıp/kırık, depozito işletmede kalır</option> : null}
            </Select>
          </Field>
          {crKind === "iade" ? (
            <Field label="Depozito iadesi"><Select value={crMethod} onChange={(e) => setCrMethod(e.target.value)}><option value="nakit">Nakit öde</option><option value="veresiye">Veresiye bakiyesinden düş</option></Select></Field>
          ) : null}
        </div>
      </Dialog>
    </Card>
  );
}
