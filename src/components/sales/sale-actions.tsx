"use client";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { Alert, Card } from "@/components/ui/card";
import { useRpc } from "@/lib/use-action";
import { formatTRY } from "@/lib/format";
import type { Role } from "@/lib/roles";

export interface SaleItemForReturn {
  id: string;
  name: string;
  unit: string;
  qty: number;
  remaining: number;
  lineNet: number;
}

export function SaleActions({ saleId, role, canCancel, items, request }: {
  saleId: string;
  role: Role;
  canCancel: boolean;
  hasCustomer: boolean;
  items: SaleItemForReturn[];
  request: { id: string; reason: string } | null;
}) {
  const { call, busy } = useRpc();
  const [cancelOpen, setCancelOpen] = useState(false);
  const [returnOpen, setReturnOpen] = useState(!!request);
  const [reason, setReason] = useState(request?.reason ?? "");
  const [qty, setQty] = useState<Record<string, string>>({});
  const [cond, setCond] = useState<Record<string, "saglam" | "kusurlu">>({});
  const isAdmin = role === "yonetici";
  const anyRemaining = items.some((i) => i.remaining > 0);

  const selected = items
    .map((i) => ({ i, q: Math.min(parseInt(qty[i.id] ?? "0", 10) || 0, i.remaining) }))
    .filter((x) => x.q > 0);
  const estimate = selected.reduce((s, x) => s + (x.q === x.i.remaining ? x.i.lineNet * (x.i.remaining / x.i.qty) : x.i.lineNet * (x.q / x.i.qty)), 0);

  async function submitReturn() {
    const payloadItems = selected.map((x) => ({ sale_item_id: x.i.id, qty: x.q, condition: cond[x.i.id] ?? "saglam" }));
    if (isAdmin) {
      const r = await call("create_return", {
        p: { id: crypto.randomUUID(), sale_id: saleId, reason, request_id: request?.id ?? null, items: payloadItems },
      }, { success: "İade kaydedildi" });
      if (r) setReturnOpen(false);
    } else {
      const r = await call("request_return", { p: { id: crypto.randomUUID(), sale_id: saleId, reason, items: payloadItems } }, { success: "İade talebi yöneticiye iletildi" });
      if (r) setReturnOpen(false);
    }
  }

  return (
    <Card className="flex flex-wrap gap-2">
      {isAdmin && canCancel ? (
        <Button variant="danger" onClick={() => setCancelOpen(true)}>Satışı iptal et</Button>
      ) : null}
      {anyRemaining ? (
        <Button variant="secondary" onClick={() => setReturnOpen(true)}>{isAdmin ? "İade al" : "İade talebi oluştur"}</Button>
      ) : null}
      {isAdmin && !canCancel ? <p className="w-full text-xs text-muted">Kasa günü kapandığı veya iade yapıldığı için iptal edilemez; iade kullanın.</p> : null}
      {request && isAdmin ? (
        <Button variant="ghost" loading={busy} onClick={() => call("reject_return_request", { p_request: request.id, p_note: "Reddedildi" }, { success: "Talep reddedildi" })}>
          Talebi reddet
        </Button>
      ) : null}

      <Dialog open={cancelOpen} onClose={() => setCancelOpen(false)} title="Satışı iptal et"
        footer={<Button variant="danger" className="w-full" loading={busy} disabled={!reason.trim()}
          onClick={async () => { if (await call("cancel_sale", { p_sale: saleId, p_reason: reason }, { success: "Satış iptal edildi" })) setCancelOpen(false); }}>
          İptal et
        </Button>}>
        <Alert tone="warn">Stok, kasa, veresiye ve depozito hareketleri ters kayıtla geri alınır. Satış silinmez.</Alert>
        <Field label="İptal nedeni" className="mt-3"><Textarea value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      </Dialog>

      <Dialog open={returnOpen} onClose={() => setReturnOpen(false)} title={isAdmin ? "İade" : "İade talebi"} wide
        footer={<Button className="w-full" loading={busy} disabled={!reason.trim() || selected.length === 0} onClick={submitReturn}>
          {isAdmin ? `İadeyi kaydet · ~${formatTRY(estimate)}` : "Talebi gönder"}
        </Button>}>
        <div className="space-y-3">
          {items.map((i) => (
            <div key={i.id} className="grid grid-cols-[1fr_80px_120px] items-center gap-2">
              <div className="text-sm">
                <div className="font-medium">{i.name}</div>
                <div className="text-xs text-muted">{i.remaining} / {i.qty} {i.unit} iade edilebilir</div>
              </div>
              <Input inputMode="numeric" placeholder="0" disabled={i.remaining === 0} value={qty[i.id] ?? ""}
                onChange={(e) => setQty((q) => ({ ...q, [i.id]: e.target.value.replace(/\D/g, "") }))} aria-label="İade miktarı" />
              <Select value={cond[i.id] ?? "saglam"} disabled={i.remaining === 0} onChange={(e) => setCond((c) => ({ ...c, [i.id]: e.target.value as "saglam" | "kusurlu" }))} aria-label="Durum">
                <option value="saglam">Sağlam → stok</option>
                <option value="kusurlu">Kusurlu → fire</option>
              </Select>
            </div>
          ))}
          <Field label="Neden"><Textarea value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
          {isAdmin ? <p className="text-xs text-muted">Para iadesi orijinal ödemeye göre yapılır: önce veresiye bakiyesinden, sonra POS, sonra nakit.</p> : null}
        </div>
      </Dialog>
    </Card>
  );
}
