"use client";
import { useMemo, useState } from "react";
import { Banknote, CreditCard, NotebookPen, Split } from "lucide-react";
import { Dialog } from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Field, Input } from "@/components/ui/field";
import { Alert } from "@/components/ui/card";
import { useAppContext } from "@/components/shell/context";
import { cn } from "@/lib/cn";
import { buildSalePayload, type CartLine, type CartTotals, type Payment, type PaymentMethod } from "@/lib/cart";
import type { PosCustomer } from "@/lib/catalog";
import { formatTRY, fromKurus, parseAmount, toKurus } from "@/lib/format";
import { errorMessage, isNetworkError } from "@/lib/errors";
import { enqueueSale } from "@/lib/offline/queue";
import { supabaseBrowser } from "@/lib/supabase/client";

export interface SaleResult {
  id: string;
  no: number | null;
  offline: boolean;
  total: number;
  change: number | null;
  customerName: string | null;
  lines: { name: string; qty: number; unit: string; total: number }[];
  deposit: number;
  discount: number;
  payments: Payment[];
  at: string;
}

type Mode = PaymentMethod | "bolunmus";

export function PaymentDialog({
  onClose,
  cart,
  totals,
  customer,
  billDiscount,
  setBillDiscount,
  empties,
  onCompleted,
}: {
  onClose: () => void;
  cart: CartLine[];
  totals: CartTotals;
  customer: PosCustomer | null;
  billDiscount: number;
  setBillDiscount: (n: number) => void;
  empties: Record<string, number>;
  onCompleted: (r: SaleResult) => void;
}) {
  const ctx = useAppContext();
  const [mode, setMode] = useState<Mode>("nakit");
  const [given, setGiven] = useState("");
  const [split, setSplit] = useState({ nakit: "", pos: "", veresiye: "" });
  const [discountText, setDiscountText] = useState(billDiscount ? String(billDiscount).replace(".", ",") : "");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [needOverride, setNeedOverride] = useState(false);
  const [saleId] = useState(() => crypto.randomUUID());

  const total = fromKurus(totals.grandK);
  // D-07: fazla boş iadesi ürün tutarını aştı → ödeme alınmaz, fark müşterinin carisine alacak yazılır
  const accountCredit = totals.grandK < 0;
  const payments: Payment[] = useMemo(() => {
    if (accountCredit) return [];
    if (mode === "bolunmus")
      return (["nakit", "pos", "veresiye"] as const).map((m) => ({ method: m, amount: parseAmount(split[m]) ?? 0 }));
    return [{ method: mode, amount: total }];
  }, [mode, split, total, accountCredit]);
  const paidK = payments.reduce((s, p) => s + toKurus(p.amount), 0);
  const cashK = toKurus(payments.find((p) => p.method === "nakit")?.amount ?? 0);
  const givenN = parseAmount(given);
  const changeK = givenN !== null && cashK > 0 ? toKurus(givenN) - cashK : null;
  const creditK = toKurus(payments.find((p) => p.method === "veresiye")?.amount ?? 0);
  const creditAfter = customer ? customer.balance + fromKurus(creditK) : 0;
  const overLimit = !!customer && creditK > 0 && !customer.unlimited && creditAfter > customer.creditLimit;

  let validation: string | null = null;
  if (totals.errors.length) validation = totals.errors[0] ?? null;
  else if (accountCredit && !customer) validation = "Fazla boş iadesi için müşteri seçin";
  else if (accountCredit) validation = null;
  else if (paidK !== totals.grandK) validation = `Ödemeler toplamı ${formatTRY(fromKurus(paidK))}, fiş toplamı ${formatTRY(total)}`;
  else if (creditK > 0 && !customer) validation = "Veresiye için müşteri seçin";
  else if (changeK !== null && changeK < 0) validation = "Alınan nakit yetersiz";

  function applyDiscount(text: string) {
    setDiscountText(text);
    const n = parseAmount(text);
    setBillDiscount(n !== null && n >= 0 ? n : 0);
  }

  async function complete(override = false) {
    if (validation) return;
    setSaving(true);
    setError(null);
    const offline = typeof navigator !== "undefined" && !navigator.onLine;
    const payload = buildSalePayload({
      id: saleId,
      customerId: customer?.id ?? null,
      cart,
      billDiscount,
      emptiesReturned: empties,
      payments,
      cashGiven: givenN !== null && cashK > 0 ? givenN : null,
      offline,
      clientCreatedAt: new Date().toISOString(),
      limitOverride: override,
    });
    const result: SaleResult = {
      id: saleId,
      no: null,
      offline: false,
      total,
      change: changeK !== null ? fromKurus(changeK) : null,
      customerName: customer?.name ?? null,
      lines: totals.lines.map((l) => ({ name: l.productName, qty: l.qty, unit: l.unitName, total: fromKurus(l.netK) })),
      deposit: fromKurus(totals.depositK),
      discount: fromKurus(totals.discountK),
      payments: payments.filter((p) => p.amount > 0),
      at: new Date().toISOString(),
    };

    const queue = async () => {
      // C-03: çevrimdışı veresiye, son bilinen bakiyeyle kontrol edilir
      if (overLimit && ctx.role !== "yonetici") {
        setSaving(false);
        setError("Çevrimdışıyken limit aşan veresiye yapılamaz.");
        return;
      }
      await enqueueSale({ id: saleId, businessId: ctx.businessId, payload: { ...payload, offline: true }, total, createdAt: result.at });
      setSaving(false);
      onCompleted({ ...result, offline: true });
    };

    if (offline) return queue();
    const { data, error } = await supabaseBrowser().rpc("complete_sale", { p_business: ctx.businessId, p: payload });
    if (error) {
      if (isNetworkError(error)) return queue();
      setSaving(false);
      const msg = errorMessage(error);
      if (/limiti aşılıyor/i.test(msg) && ctx.role === "yonetici") setNeedOverride(true);
      setError(msg);
      return;
    }
    const r = data as { no: number; change: number | null };
    setSaving(false);
    onCompleted({ ...result, no: r.no, change: r.change ?? result.change });
  }

  const quickCash = useMemo(() => {
    const t = total;
    const opts = new Set<number>([t]);
    for (const step of [10, 50, 100, 200]) opts.add(Math.ceil(t / step) * step);
    return [...opts].filter((x) => x >= t).sort((a, b) => a - b).slice(0, 4);
  }, [total]);

  const modes: { m: Mode; label: string; icon: typeof Banknote; disabled?: boolean }[] = [
    { m: "nakit", label: "Nakit", icon: Banknote },
    { m: "pos", label: "POS", icon: CreditCard },
    { m: "veresiye", label: "Veresiye", icon: NotebookPen, disabled: !customer },
    { m: "bolunmus", label: "Bölünmüş", icon: Split },
  ];

  return (
    <Dialog
      open
      onClose={onClose}
      title="Ödeme"
      footer={
        <div className="space-y-2">
          {error ? <Alert>{error}</Alert> : null}
          {needOverride ? (
            <Button variant="danger" className="w-full" loading={saving} onClick={() => complete(true)}>
              Limiti aşarak onayla (yönetici)
            </Button>
          ) : null}
          <Button size="lg" variant="ok" className="w-full" disabled={!!validation} loading={saving} onClick={() => complete(false)}>
            {accountCredit ? `Kaydet · carisine ${formatTRY(-total)} alacak` : `Satışı tamamla · ${formatTRY(total)}`}
          </Button>
          {validation ? <div className="text-center text-xs text-muted">{validation}</div> : null}
        </div>
      }
    >
      {accountCredit ? (
        <div className="space-y-3">
          <div className="rounded-2xl bg-ok-soft p-4 text-center">
            <div className="text-sm text-ok">Müşterinin carisine alacak yazılacak</div>
            <div className="num text-3xl font-bold text-ok">{formatTRY(-total)}</div>
            <div className="num text-xs text-muted">Ürünler {formatTRY(fromKurus(totals.goodsNetK))} · depozito iadesi {formatTRY(fromKurus(totals.depositK))}</div>
          </div>
          <Alert tone="neutral">
            Getirilen fazla boşların depozitosu aldığı ürün tutarını aşıyor. Ödeme alınmaz; fark {customer?.name ?? "müşteri"} hesabında alacak olarak görünür.
          </Alert>
        </div>
      ) : (
      <div className="space-y-4">
        <div className="rounded-2xl bg-surface-2 p-4 text-center">
          <div className="text-sm text-muted">Ödenecek tutar</div>
          <div className="num text-3xl font-bold">{formatTRY(total)}</div>
          {totals.depositK !== 0 ? <div className="num text-xs text-muted">Depozito dahil: {formatTRY(fromKurus(totals.depositK))}</div> : null}
        </div>

        <div className="grid grid-cols-4 gap-2">
          {modes.map(({ m, label, icon: Icon, disabled }) => (
            <button
              key={m}
              disabled={disabled}
              onClick={() => setMode(m)}
              className={cn(
                "flex flex-col items-center gap-1 rounded-xl border p-3 text-sm disabled:opacity-40",
                mode === m ? "border-brand bg-brand-soft font-semibold text-brand" : "border-border",
              )}
            >
              <Icon className="h-6 w-6" />
              {label}
            </button>
          ))}
        </div>
        {!customer ? <p className="text-xs text-muted">Veresiye için sepetten müşteri seçin.</p> : null}

        {mode === "nakit" ? (
          <div className="space-y-2">
            <Field label="Alınan nakit (isteğe bağlı)">
              <Input inputMode="decimal" value={given} onChange={(e) => setGiven(e.target.value)} placeholder={formatTRY(total)} />
            </Field>
            <div className="flex flex-wrap gap-2">
              {quickCash.map((v) => (
                <Button key={v} variant="secondary" size="sm" onClick={() => setGiven(String(v))}>
                  {formatTRY(v)}
                </Button>
              ))}
            </div>
            {changeK !== null && changeK >= 0 ? (
              <div className="num rounded-xl bg-ok-soft p-3 text-center text-lg font-semibold text-ok">Para üstü: {formatTRY(fromKurus(changeK))}</div>
            ) : null}
          </div>
        ) : null}

        {mode === "bolunmus" ? (
          <div className="grid grid-cols-3 gap-2">
            {(["nakit", "pos", "veresiye"] as const).map((m) => (
              <Field key={m} label={m === "nakit" ? "Nakit" : m === "pos" ? "POS" : "Veresiye"}>
                <Input
                  inputMode="decimal"
                  disabled={m === "veresiye" && !customer}
                  value={split[m]}
                  onChange={(e) => setSplit((s) => ({ ...s, [m]: e.target.value }))}
                  onFocus={() => {
                    if (!split[m]) {
                      const rest = totals.grandK - (["nakit", "pos", "veresiye"] as const).filter((x) => x !== m).reduce((s, x) => s + toKurus(parseAmount(split[x]) ?? 0), 0);
                      if (rest > 0) setSplit((s) => ({ ...s, [m]: String(fromKurus(rest)).replace(".", ",") }));
                    }
                  }}
                />
              </Field>
            ))}
          </div>
        ) : null}

        {customer && creditK > 0 ? (
          <Alert tone={overLimit ? "warn" : "brand"}>
            {customer.name}: yeni bakiye {formatTRY(creditAfter)} / limit {customer.unlimited ? "limitsiz" : formatTRY(customer.creditLimit)}
            {overLimit ? " — limit aşılıyor" : ""}
          </Alert>
        ) : null}

        <details className="rounded-xl border border-border p-3">
          <summary className="cursor-pointer text-sm font-medium">İndirim</summary>
          <div className="mt-2">
            <Field label="Fiş indirimi (₺)" hint={ctx.role === "yonetici" ? undefined : "Satış personeli en fazla %5 indirim yapabilir"}>
              <Input inputMode="decimal" value={discountText} onChange={(e) => applyDiscount(e.target.value)} placeholder="0" />
            </Field>
          </div>
        </details>
      </div>
      )}
    </Dialog>
  );
}
