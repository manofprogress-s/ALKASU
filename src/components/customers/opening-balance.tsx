"use client";
import { useState } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/field";
import { useAppContext } from "@/components/shell/context";
import { useToast } from "@/components/ui/toast";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import { formatTRY, parseAmount } from "@/lib/format";

/** Yönetici: açılış bakiyesini düzeltir / sıfırlar (M-22). Kayıt silinmez; fark yeni açılış satırı olarak ekstreye düşer. */
export function OpeningBalance({ customerId, current, legacyDebt }: { customerId: string; current: number; legacyDebt: number | null }) {
  const ctx = useAppContext();
  const router = useRouter();
  const toast = useToast();
  const [open, setOpen] = useState(false);
  const [amount, setAmount] = useState(String(current).replace(".", ","));
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);

  async function save(value: number) {
    setBusy(true);
    const { error } = await supabaseBrowser().rpc("set_opening_balance", {
      p_business: ctx.businessId, p_customer: customerId, p_amount: value, p_note: note.trim() || null,
    });
    setBusy(false);
    if (error) return toast(errorMessage(error), "danger");
    toast(value === 0 ? "Açılış bakiyesi sıfırlandı" : `Açılış bakiyesi ${formatTRY(value)} oldu`, "ok");
    setOpen(false);
    setNote("");
    router.refresh();
  }

  if (!current && !legacyDebt && !open) {
    return (
      <button type="button" onClick={() => setOpen(true)} className="text-sm text-brand">Açılış bakiyesi gir</button>
    );
  }
  return (
    <Card className="space-y-2">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 className="font-semibold">Açılış bakiyesi</h2>
          <p className="text-sm text-muted">
            Şu an <b className="num text-text">{formatTRY(current)}</b>
            {legacyDebt ? <> · eski sistemdeki borç {formatTRY(legacyDebt)}</> : null}
          </p>
        </div>
        {!open ? <Button size="sm" variant="secondary" onClick={() => { setAmount(String(current).replace(".", ",")); setOpen(true); }}>Düzelt</Button> : null}
      </div>
      {open ? (
        <div className="space-y-2">
          <div className="grid gap-2 sm:grid-cols-2">
            <Field label="Doğru açılış tutarı (borç +, alacak −)">
              <Input inputMode="decimal" className="num" value={amount} onChange={(e) => setAmount(e.target.value)} />
            </Field>
            <Field label="Not (isteğe bağlı)">
              <Input value={note} maxLength={200} onChange={(e) => setNote(e.target.value)} placeholder="Örn. müşteriyle mutabık kalındı" />
            </Field>
          </div>
          <div className="flex flex-wrap gap-2">
            <Button loading={busy} onClick={() => { const v = parseAmount(amount.replace(/^-/, "")); if (v === null) return toast("Tutarı kontrol edin", "danger"); void save(amount.trim().startsWith("-") ? -v : v); }}>Kaydet</Button>
            <Button variant="danger" loading={busy} disabled={!current} onClick={() => void save(0)}>Sıfırla</Button>
            <Button variant="ghost" onClick={() => setOpen(false)}>Vazgeç</Button>
          </div>
          <p className="text-xs text-muted">Cari kayıtları silinmez: fark ekstreye “Açılış bakiyesi” satırı olarak eklenir.</p>
        </div>
      ) : null}
    </Card>
  );
}
