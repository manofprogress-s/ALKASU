"use client";
import { useState } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { Alert, Card } from "@/components/ui/card";
import { Field, Input, Textarea } from "@/components/ui/field";
import { useAppContext } from "@/components/shell/context";
import { useToast } from "@/components/ui/toast";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import { parseAmount } from "@/lib/format";

export interface CustomerValue {
  id?: string; code: string; name: string; phone: string | null; address: string | null; tax_no: string | null; note: string | null;
  credit_limit: number; unlimited_credit: boolean; active: boolean;
}

export function CustomerForm({ initial, canSetLimit }: { initial: CustomerValue | null; canSetLimit: boolean }) {
  const ctx = useAppContext();
  const router = useRouter();
  const toast = useToast();
  const [v, setV] = useState<CustomerValue>(initial ?? { code: "", name: "", phone: "", address: "", tax_no: "", note: "", credit_limit: 0, unlimited_credit: false, active: true });
  const [limit, setLimit] = useState(String(v.credit_limit).replace(".", ","));
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const set = <K extends keyof CustomerValue>(k: K, val: CustomerValue[K]) => setV((x) => ({ ...x, [k]: val }));

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setSaving(true);
    setError(null);
    const { data, error } = await supabaseBrowser().rpc("upsert_customer", {
      p_business: ctx.businessId,
      p: { ...v, id: v.id ?? null, code: v.code || null, credit_limit: parseAmount(limit) ?? 0 },
    });
    setSaving(false);
    if (error) return setError(errorMessage(error));
    toast("Müşteri kaydedildi", "ok");
    if (!v.id) router.push(`/musteriler/${data}`);
    else router.refresh();
  }

  return (
    <form onSubmit={save}>
      <Card className="grid gap-3 md:grid-cols-2">
        <Field label="Ad / unvan"><Input required value={v.name} onChange={(e) => set("name", e.target.value)} /></Field>
        <Field label="Müşteri kodu" hint="Boş bırakılırsa otomatik verilir"><Input value={v.code} onChange={(e) => set("code", e.target.value)} /></Field>
        <Field label="Telefon"><Input inputMode="tel" value={v.phone ?? ""} onChange={(e) => set("phone", e.target.value)} /></Field>
        <Field label="Vergi no"><Input value={v.tax_no ?? ""} onChange={(e) => set("tax_no", e.target.value)} /></Field>
        <Field label="Adres / teslimat notu" className="md:col-span-2"><Textarea value={v.address ?? ""} onChange={(e) => set("address", e.target.value)} /></Field>
        {canSetLimit ? (
          <>
            <Field label="Veresiye limiti ₺" hint="0 = veresiye kapalı"><Input inputMode="decimal" value={limit} disabled={v.unlimited_credit} onChange={(e) => setLimit(e.target.value)} /></Field>
            <div className="flex flex-col justify-end gap-2 pb-2">
              <label className="flex items-center gap-2"><input type="checkbox" className="h-5 w-5" checked={v.unlimited_credit} onChange={(e) => set("unlimited_credit", e.target.checked)} /> Limitsiz veresiye</label>
              <label className="flex items-center gap-2"><input type="checkbox" className="h-5 w-5" checked={v.active} onChange={(e) => set("active", e.target.checked)} /> Aktif</label>
            </div>
          </>
        ) : null}
        <Field label="Not" className="md:col-span-2"><Input value={v.note ?? ""} onChange={(e) => set("note", e.target.value)} /></Field>
        {error ? <div className="md:col-span-2"><Alert>{error}</Alert></div> : null}
        <Button type="submit" className="md:col-span-2" loading={saving}>Kaydet</Button>
      </Card>
    </form>
  );
}
