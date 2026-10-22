"use client";
import { useState } from "react";
import { Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { useAppContext } from "@/components/shell/context";
import { useRpc } from "@/lib/use-action";
import { addDaysISO, formatTRY, parseAmount, todayISO } from "@/lib/format";
import { cn } from "@/lib/cn";

export interface ExpenseCategory { id: string; name: string; code: string | null; restricted: boolean }

/** Gider ekleme (K-11..K-13). Personel kısıtlı kategorileri (maaş, kira, vergi) görmez; veritabanı da engeller. */
export function ExpenseForm({ categories, isAdmin, label = "Gider ekle" }: { categories: ExpenseCategory[]; isAdmin: boolean; label?: string }) {
  const ctx = useAppContext();
  const { call, busy } = useRpc();
  const [open, setOpen] = useState(false);
  const [cat, setCat] = useState("");
  const [amount, setAmount] = useState("");
  const [method, setMethod] = useState<"kasa" | "banka">("banka");
  const [date, setDate] = useState(() => todayISO());
  const [payee, setPayee] = useState("");
  const [desc, setDesc] = useState("");
  const [monthly, setMonthly] = useState(false);
  const [day, setDay] = useState("");
  const selected = categories.find((c) => c.id === cat);
  const amt = parseAmount(amount);
  const today = todayISO();
  const isSalary = selected?.code === "maas";

  function reset() { setCat(""); setAmount(""); setPayee(""); setDesc(""); setDate(todayISO()); setMethod("banka"); setMonthly(false); setDay(""); }
  const dayN = Number.parseInt(day || date.slice(8, 10), 10);

  async function save() {
    if (!selected || !amt) return;
    if (monthly) {
      // K-15: her ay düzenli — şablon kaydedilir, vadesi gelen aylar gidere işlenir
      const ok = await call("upsert_recurring_expense", {
        p_business: ctx.businessId,
        p: { category_id: selected.id, amount: amt, payee, description: desc, day_of_month: dayN, start_month: `${date.slice(0, 7)}-01` },
      }, { success: `${selected.name}: her ayın ${dayN}. günü otomatik gidere işlenecek` });
      if (ok) { reset(); setOpen(false); }
      return;
    }
    const ok = await call("add_expense", {
      p_business: ctx.businessId,
      p: { id: crypto.randomUUID(), category_id: selected.id, amount: amt, method, expense_date: date, payee, description: desc },
    }, { success: `${selected.name} gideri kaydedildi` });
    if (ok) { reset(); setOpen(false); }
  }

  return (
    <>
      <Button onClick={() => setOpen(true)}><Plus className="h-4 w-4" /> {label}</Button>
      <Dialog open={open} onClose={() => setOpen(false)} title="Gider ekle"
        footer={<Button className="w-full" loading={busy} disabled={!selected || !amt || !date || (monthly && !(dayN >= 1 && dayN <= 31))} onClick={() => void save()}>
          {monthly ? (amt ? `Her ay ${formatTRY(amt)} olarak kaydet` : "Düzenli gider olarak kaydet") : amt ? `${formatTRY(amt)} kaydet` : "Kaydet"}</Button>}>
        <div className="space-y-3">
          <div>
            <div className="mb-1 text-sm font-medium">Ne için?</div>
            <div className="flex flex-wrap gap-1.5">
              {categories.map((c) => (
                <button key={c.id} type="button" onClick={() => setCat(c.id)}
                  className={cn("rounded-full border px-3 py-1.5 text-sm", cat === c.id ? "border-brand bg-brand text-white" : "border-border bg-surface hover:bg-surface-2")}>
                  {c.name}
                </button>
              ))}
            </div>
          </div>
          <Field label="Tutar ₺ (KDV dahil, ödenen)">
            <Input inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0,00" autoFocus />
          </Field>
          {isSalary || selected?.code === "kira" ? (
            <Field label={isSalary ? "Personel" : "Kime ödendi"}>
              <Input value={payee} onChange={(e) => setPayee(e.target.value)} maxLength={120} placeholder={isSalary ? "Örn. Hüseyin Topaloğlu" : "Örn. ev sahibi"} />
            </Field>
          ) : null}
          {isAdmin ? (
            <label className="flex items-start gap-2 rounded-xl border border-border p-2.5 text-sm">
              <input type="checkbox" className="mt-0.5 h-4 w-4 accent-[var(--brand)]" checked={monthly} onChange={(e) => setMonthly(e.target.checked)} />
              <span>
                <span className="font-medium">Her ay düzenli</span>
                <span className="block text-xs text-muted">Maaş, kira gibi. Her ay seçilen günde kendiliğinden gidere işlenir; tek tek girmeniz gerekmez.</span>
              </span>
            </label>
          ) : null}
          {monthly ? (
            <div className="grid grid-cols-2 gap-2">
              <Field label="İlk ay (başlangıç tarihi)">
                <Input type="date" value={date} onChange={(e) => setDate(e.target.value)} />
              </Field>
              <Field label="Her ayın kaçında?" hint="31 seçilirse kısa aylarda ayın son günü">
                <Input inputMode="numeric" value={day || String(Number(date.slice(8, 10)) || "")} onChange={(e) => setDay(e.target.value.replace(/\D/g, "").slice(0, 2))} />
              </Field>
            </div>
          ) : (
          <div className="grid grid-cols-2 gap-2">
            <Field label="Tarih">
              <Input type="date" value={date} max={today} min={isAdmin ? undefined : addDaysISO(today, -31)} onChange={(e) => setDate(e.target.value)} />
            </Field>
            <Field label="Nasıl ödendi?">
              <Select value={method} onChange={(e) => setMethod(e.target.value as "kasa" | "banka")}>
                <option value="banka">Banka / kart</option>
                <option value="kasa">Dükkân kasasından nakit</option>
              </Select>
            </Field>
          </div>
          )}
          {monthly ? <p className="text-xs text-muted">Düzenli giderler banka/havale ödemesi olarak işlenir, kasayı etkilemez. Bu ayın günü geçtiyse bu ayki kayıt hemen oluşur.</p> : null}
          {!monthly && method === "kasa" ? <p className="text-xs text-muted">Kasadan nakit ödenen gider, günün kasasından düşülür.</p> : null}
          <Field label="Açıklama (isteğe bağlı)">
            <Input value={desc} onChange={(e) => setDesc(e.target.value)} maxLength={300}
              placeholder={selected?.code === "yakit" ? "Örn. 34 ABC 123 mazot" : selected?.code === "arac" ? "Örn. lastik değişimi" : "Örn. fatura / fiş bilgisi"} />
          </Field>
          {!isAdmin ? <p className="text-xs text-muted">Maaş, kira ve vergi/SGK giderlerini yönetici girer.</p> : null}
        </div>
      </Dialog>
    </>
  );
}

/** Gider iptali: yönetici her zaman, personel kendi girdiğini aynı gün. */
export function ExpenseCancel({ id }: { id: string }) {
  const { call, busy } = useRpc();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  return (
    <>
      <Button size="sm" variant="ghost" className="text-danger" onClick={() => setOpen(true)}>İptal</Button>
      <Dialog open={open} onClose={() => setOpen(false)} title="Gideri iptal et"
        footer={<Button variant="danger" className="w-full" loading={busy} disabled={reason.trim().length < 2}
          onClick={async () => { if (await call("cancel_expense", { p_expense: id, p_reason: reason }, { success: "Gider iptal edildi" })) setOpen(false); }}>
          İptal et</Button>}>
        <Field label="İptal nedeni"><Input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Örn. yanlış tutar" /></Field>
      </Dialog>
    </>
  );
}
