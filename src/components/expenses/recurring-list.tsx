"use client";
import { useState } from "react";
import { Repeat } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge, Card } from "@/components/ui/card";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input } from "@/components/ui/field";
import { useAppContext } from "@/components/shell/context";
import { useRpc } from "@/lib/use-action";
import { formatTRY, parseAmount } from "@/lib/format";
import { monthLabel } from "@/lib/profit";

export interface Recurring {
  id: string; category_id: string; amount: number; payee: string | null; description: string | null;
  day_of_month: number; start_month: string; active: boolean;
}

/** Her ay düzenli giderler (K-15..K-17): liste, tutar/gün düzenleme, durdur/başlat */
export function RecurringList({ items, catName }: { items: Recurring[]; catName: Record<string, string> }) {
  const monthlyTotal = items.filter((r) => r.active).reduce((s, r) => s + Number(r.amount), 0);
  return (
    <Card>
      <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
        <h2 className="flex items-center gap-1.5 font-semibold"><Repeat className="h-4 w-4 text-brand" /> Her ay düzenli giderler</h2>
        <span className="text-sm text-muted">Aylık toplam {formatTRY(monthlyTotal)}</span>
      </div>
      {items.length ? (
        <ul className="divide-y divide-border text-sm">
          {items.map((r) => <Row key={r.id} r={r} name={catName[r.category_id] ?? "Gider"} />)}
        </ul>
      ) : (
        <p className="text-sm text-muted">Henüz yok. “Gider ekle”de <b>Her ay düzenli</b> kutucuğunu işaretleyerek maaş, kira gibi giderleri bir kez tanımlayın.</p>
      )}
    </Card>
  );
}

function Row({ r, name }: { r: Recurring; name: string }) {
  const ctx = useAppContext();
  const { call, busy } = useRpc();
  const [open, setOpen] = useState(false);
  const [amount, setAmount] = useState(String(r.amount).replace(".", ","));
  const [day, setDay] = useState(String(r.day_of_month));
  const [payee, setPayee] = useState(r.payee ?? "");
  const amt = parseAmount(amount);
  const dayN = Number.parseInt(day, 10);
  return (
    <li className="flex flex-wrap items-center justify-between gap-2 py-2">
      <span className="min-w-0">
        <span className="font-medium">{name}{r.payee ? ` · ${r.payee}` : ""}</span>
        <span className="block text-xs text-muted">
          Her ayın {r.day_of_month}. günü · {monthLabel(r.start_month.slice(0, 7))}’dan beri{r.description ? ` · ${r.description}` : ""}
        </span>
      </span>
      <span className="flex items-center gap-2">
        {!r.active ? <Badge tone="neutral">Durduruldu</Badge> : null}
        <span className="num font-medium">{formatTRY(r.amount)}</span>
        <Button size="sm" variant="ghost" onClick={() => setOpen(true)}>Düzenle</Button>
        <Button size="sm" variant="ghost" className={r.active ? "text-danger" : "text-ok"} loading={busy}
          onClick={() => void call("set_recurring_active", { p_id: r.id, p_active: !r.active }, { success: r.active ? "Düzenli gider durduruldu" : "Düzenli gider yeniden başladı" })}>
          {r.active ? "Durdur" : "Başlat"}
        </Button>
      </span>
      <Dialog open={open} onClose={() => setOpen(false)} title={`${name} · düzenli gider`}
        footer={<Button className="w-full" loading={busy} disabled={!amt || !(dayN >= 1 && dayN <= 31)}
          onClick={async () => {
            const ok = await call("upsert_recurring_expense", {
              p_business: ctx.businessId,
              p: { id: r.id, category_id: r.category_id, amount: amt, payee, description: r.description, day_of_month: dayN },
            }, { success: "Kaydedildi; yeni tutar sonraki aylara yansır" });
            if (ok) setOpen(false);
          }}>Kaydet</Button>}>
        <div className="space-y-3">
          <Field label="Aylık tutar ₺"><Input inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} /></Field>
          <Field label="Her ayın kaçında?"><Input inputMode="numeric" value={day} onChange={(e) => setDay(e.target.value.replace(/\D/g, "").slice(0, 2))} /></Field>
          <Field label="Kime"><Input value={payee} maxLength={120} onChange={(e) => setPayee(e.target.value)} /></Field>
          <p className="text-xs text-muted">Değişiklik yalnızca sonraki aylara yansır; önceden oluşan gider kayıtları değişmez (gerekirse listeden iptal edip yeniden girin).</p>
        </div>
      </Dialog>
    </li>
  );
}
