"use client";
import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { CheckCircle2, XCircle } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Alert, Card } from "@/components/ui/card";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { useAppContext } from "@/components/shell/context";
import { useToast } from "@/components/ui/toast";
import { useRpc } from "@/lib/use-action";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import { computeCart, type CartLine, type ContainerBalances, type PaymentMethod } from "@/lib/cart";
import { formatTRY, fromKurus, parseAmount, toKurus } from "@/lib/format";
import { cn } from "@/lib/cn";
import type { Assignee } from "@/lib/orders";

export interface DeliverItem {
  id: string;
  productId: string;
  unitId: string;
  productName: string;
  unitName: string;
  factor: number;
  qty: number;
  unitPrice: number;
  deposit: number | null;
  emptyProductId: string | null;
}

const METHODS: { key: PaymentMethod; label: string }[] = [
  { key: "veresiye", label: "Veresiye (cari)" },
  { key: "nakit", label: "Nakit" },
  { key: "pos", label: "POS / kart" },
];

export function OrderActions(props: {
  orderId: string;
  orderNo: number;
  customerName: string;
  assignee: string | null;
  assignees: Assignee[];
  canAssign: boolean;
  canDeliver: boolean;
  items: DeliverItem[];
  balance: number;
  creditLimit: number | null;
  containers: { productId: string; qty: number; amount: number }[];
}) {
  const ctx = useAppContext();
  const router = useRouter();
  const toast = useToast();
  const { call, busy } = useRpc();
  const [cancelOpen, setCancelOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [deliverOpen, setDeliverOpen] = useState(false);

  return (
    <Card className="space-y-3">
      {props.canDeliver ? (
        <Button size="lg" variant="ok" className="w-full" onClick={() => setDeliverOpen(true)}>
          <CheckCircle2 className="h-5 w-5" /> Teslim edildi
        </Button>
      ) : null}
      {props.canAssign ? (
        <Field label="Sorumlu">
          <Select
            value={props.assignee ?? ""}
            disabled={busy}
            onChange={(e) => void call("assign_order", { p_order: props.orderId, p_assignee: e.target.value || null }, { success: "Sipariş atandı" })}
          >
            <option value="">Atanmadı</option>
            {props.assignees.map((a) => <option key={a.user_id} value={a.user_id}>{a.display_name}</option>)}
          </Select>
        </Field>
      ) : null}
      <Button variant="secondary" className="w-full" onClick={() => setCancelOpen(true)}>
        <XCircle className="h-4 w-4" /> Siparişi iptal et
      </Button>

      <Dialog
        open={cancelOpen}
        onClose={() => setCancelOpen(false)}
        title={`Sipariş #${props.orderNo} iptal`}
        footer={
          <Button
            variant="danger"
            className="w-full"
            loading={busy}
            disabled={!reason.trim()}
            onClick={async () => {
              const ok = await call("cancel_order", { p_order: props.orderId, p_reason: reason }, { success: "Sipariş iptal edildi" });
              if (ok) setCancelOpen(false);
            }}
          >
            İptal et
          </Button>
        }
      >
        <Field label="İptal nedeni" hint="Örn. müşteri vazgeçti, adreste kimse yoktu">
          <Input value={reason} onChange={(e) => setReason(e.target.value)} />
        </Field>
      </Dialog>

      {deliverOpen ? (
        <DeliverDialog
          {...props}
          onClose={() => setDeliverOpen(false)}
          onDone={(no) => {
            setDeliverOpen(false);
            toast(`Teslimat kaydedildi · Satış #${no}`, "ok");
            router.refresh();
          }}
          businessId={ctx.businessId}
        />
      ) : null}
    </Card>
  );
}

function DeliverDialog({
  orderId,
  orderNo,
  customerName,
  items,
  balance,
  creditLimit,
  containers,
  businessId,
  onClose,
  onDone,
}: {
  orderId: string;
  orderNo: number;
  customerName: string;
  items: DeliverItem[];
  balance: number;
  creditLimit: number | null;
  containers: { productId: string; qty: number; amount: number }[];
  businessId: string;
  onClose: () => void;
  onDone: (saleNo: number) => void;
}) {
  const [saleId] = useState(() => crypto.randomUUID());
  const [qty, setQty] = useState<Record<string, string>>(() => Object.fromEntries(items.map((i) => [i.id, String(i.qty)])));
  const [empties, setEmpties] = useState<Record<string, string>>({});
  const [method, setMethod] = useState<PaymentMethod | "bolunmus">("veresiye");
  const [split, setSplit] = useState({ nakit: "", pos: "", veresiye: "" });
  const [note, setNote] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const delivered = items.map((i) => ({ ...i, q: Number.parseInt(qty[i.id] ?? "0", 10) || 0 }));
  const cart: CartLine[] = delivered
    .filter((i) => i.q > 0)
    .map((i) => ({
      key: i.id,
      productId: i.productId,
      productName: i.productName,
      unitId: i.unitId,
      unitName: i.unitName,
      factor: i.factor,
      qty: i.q,
      unitPrice: i.unitPrice,
      lineDiscount: 0,
      depositAmount: i.deposit,
      emptyProductId: i.emptyProductId,
    }));
  const emptiesNum: Record<string, number> = {};
  for (const [pid, v] of Object.entries(empties)) if (v.trim() !== "") emptiesNum[pid] = Math.max(0, Number.parseInt(v, 10) || 0);
  const balances: ContainerBalances = useMemo(() => Object.fromEntries(containers.map((c) => [c.productId, { qty: c.qty, amount: c.amount }])), [containers]);
  const totals = computeCart(cart, 0, emptiesNum, balances);
  const total = fromKurus(totals.grandK);

  const payments =
    method === "bolunmus"
      ? (["nakit", "pos", "veresiye"] as const).map((m) => ({ method: m, amount: parseAmount(split[m]) ?? 0 }))
      : [{ method, amount: total }];
  const paidK = payments.reduce((s, p) => s + toKurus(p.amount), 0);
  const creditK = toKurus(payments.find((p) => p.method === "veresiye")?.amount ?? 0);
  const over = creditLimit !== null && creditK > 0 && balance + fromKurus(creditK) > creditLimit;

  let validation: string | null = null;
  if (cart.length === 0) validation = "Teslim edilen ürün yok; teslim edilmediyse siparişi iptal edin";
  else if (totals.errors.length) validation = totals.errors[0] ?? null;
  else if (paidK !== totals.grandK) validation = `Ödemeler toplamı ${formatTRY(fromKurus(paidK))}, teslimat tutarı ${formatTRY(total)}`;

  async function submit() {
    if (validation) return setError(validation);
    setSaving(true);
    setError(null);
    const depositProducts = [...new Set(cart.filter((l) => l.depositAmount !== null).map((l) => l.productId))];
    const { data, error } = await supabaseBrowser().rpc("deliver_order", {
      p_business: businessId,
      p: {
        order_id: orderId,
        sale_id: saleId,
        items: delivered.map((i) => ({ order_item_id: i.id, qty: i.q })),
        deposits: depositProducts.map((pid) => ({
          product_id: pid,
          empty_returned: emptiesNum[pid] ?? cart.filter((l) => l.productId === pid).reduce((s, l) => s + l.qty * l.factor, 0),
        })),
        payments: payments.filter((p) => toKurus(p.amount) > 0).map((p) => ({ method: p.method, amount: fromKurus(toKurus(p.amount)) })),
        note: note.trim() || null,
      },
    });
    setSaving(false);
    if (error) return setError(errorMessage(error));
    onDone((data as { no: number }).no);
  }

  return (
    <Dialog
      open
      onClose={onClose}
      wide
      title={`Teslimat · #${orderNo} ${customerName}`}
      footer={
        <div className="space-y-2">
          {validation ? <div className="text-center text-sm text-muted">{validation}</div> : null}
          <Button size="lg" variant="ok" className="w-full" loading={saving} disabled={!!validation} onClick={() => void submit()}>
            Teslimatı kaydet · {formatTRY(total)}
          </Button>
        </div>
      }
    >
      <div className="space-y-4">
        <div>
          <h3 className="mb-2 text-sm font-semibold">Teslim edilen miktar</h3>
          <div className="space-y-2">
            {delivered.map((i) => (
              <div key={i.id} className="flex items-center justify-between gap-2">
                <span className="min-w-0 text-sm">
                  {i.productName}
                  <span className="block text-xs text-muted">Sipariş: {i.qty} {i.unitName} · {formatTRY(i.unitPrice)}</span>
                </span>
                <Input
                  inputMode="numeric"
                  className={cn("num h-11 w-24 text-center", i.q !== i.qty && "border-warn")}
                  value={qty[i.id] ?? ""}
                  onChange={(e) => setQty((x) => ({ ...x, [i.id]: e.target.value.replace(/\D/g, "") }))}
                  aria-label={`${i.productName} teslim miktarı`}
                />
              </div>
            ))}
          </div>
        </div>

        {totals.deposits.length ? (
          <div>
            <h3 className="mb-2 text-sm font-semibold">Alınan boş kap</h3>
            {totals.deposits.map((d) => (
              <div key={d.productId} className="flex items-center justify-between gap-2">
                <span className="text-sm">
                  {d.productName}
                  <span className="block text-xs text-muted">
                    Verilen {d.sold} · {d.net > 0 ? `müşteride kalan ${d.net} · depozito ${formatTRY(fromKurus(d.amountK))}` : d.net < 0 ? `fazla boş ${-d.net} · iade ${formatTRY(fromKurus(-d.amountK))}` : "değişim"}
                  </span>
                  {d.error ? <span className="block text-xs text-danger">{d.error}</span> : null}
                </span>
                <Input
                  inputMode="numeric"
                  className="num h-11 w-24 text-center"
                  placeholder={String(d.sold)}
                  value={empties[d.productId] ?? ""}
                  onChange={(e) => setEmpties((x) => ({ ...x, [d.productId]: e.target.value.replace(/\D/g, "") }))}
                  aria-label={`${d.productName} alınan boş`}
                />
              </div>
            ))}
          </div>
        ) : null}

        <div className="space-y-1 rounded-xl bg-surface-2 p-3 text-sm">
          <div className="flex justify-between"><span>Ürün</span><span className="num">{formatTRY(fromKurus(totals.goodsNetK))}</span></div>
          {totals.depositK !== 0 ? <div className="flex justify-between"><span>Depozito</span><span className="num">{formatTRY(fromKurus(totals.depositK))}</span></div> : null}
          <div className="flex justify-between text-base font-semibold"><span>Toplam</span><span className="num">{formatTRY(total)}</span></div>
        </div>

        <div>
          <h3 className="mb-2 text-sm font-semibold">Ödeme</h3>
          <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
            {[...METHODS, { key: "bolunmus" as const, label: "Bölünmüş" }].map((m) => (
              <Button key={m.key} variant={method === m.key ? "primary" : "secondary"} onClick={() => setMethod(m.key)}>{m.label}</Button>
            ))}
          </div>
          {method === "bolunmus" ? (
            <div className="mt-2 grid grid-cols-3 gap-2">
              {METHODS.map((m) => (
                <Field key={m.key} label={m.label}>
                  <Input inputMode="decimal" value={split[m.key]} onChange={(e) => setSplit((x) => ({ ...x, [m.key]: e.target.value }))} />
                </Field>
              ))}
            </div>
          ) : null}
          {over ? (
            <Alert tone="warn">
              Veresiye limiti aşılıyor (bakiye {formatTRY(balance)}, limit {formatTRY(creditLimit)}). Teslimat kaydedilir, yöneticiye uyarı gider.
            </Alert>
          ) : null}
        </div>
        <Field label="Not (isteğe bağlı)"><Input value={note} onChange={(e) => setNote(e.target.value)} /></Field>
        {error ? <Alert>{error}</Alert> : null}
      </div>
    </Dialog>
  );
}
