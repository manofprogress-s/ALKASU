"use client";
import { useState } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { Alert, Card } from "@/components/ui/card";
import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { CHANNELS, PRICE_LISTS, type Channel, type PriceList } from "@/lib/roles";
import { LocationField } from "@/components/geo/location-field";
import type { LatLng } from "@/lib/geo";
import { useAppContext } from "@/components/shell/context";
import { useToast } from "@/components/ui/toast";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import { parseAmount } from "@/lib/format";

export interface CustomerValue {
  id?: string; code: string; name: string; phone: string | null; address: string | null; tax_no: string | null; note: string | null;
  credit_limit: number; unlimited_credit: boolean; active: boolean;
  channel: Channel; price_list: PriceList; regions: string | null; default_assignee: string | null;
  location: LatLng | null; dispenser_count: number;
}

export interface AssigneeOption {
  user_id: string;
  display_name: string;
}

export function CustomerForm({ initial, canSetLimit, assignees = [], defaultChannel }: { initial: CustomerValue | null; canSetLimit: boolean; assignees?: AssigneeOption[]; defaultChannel?: string }) {
  const ctx = useAppContext();
  const router = useRouter();
  const toast = useToast();
  const [v, setV] = useState<CustomerValue>(initial ?? { code: "", name: "", phone: "", address: "", tax_no: "", note: "", credit_limit: 0, unlimited_credit: false, active: true, channel: defaultChannel && defaultChannel in CHANNELS ? (defaultChannel as Channel) : "perakende", price_list: "perakende", regions: "", default_assignee: null, location: null, dispenser_count: 0 });
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
      p: {
        ...v,
        location: undefined,
        id: v.id ?? null,
        code: v.code || null,
        credit_limit: parseAmount(limit) ?? 0,
        latitude: v.location?.lat ?? null,
        longitude: v.location?.lng ?? null,
      },
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
        <div className="md:col-span-2">
          <LocationField value={v.location} onChange={(p) => set("location", p)} address={v.address} />
        </div>
        <Field label="Kanal">
          <Select value={v.channel} onChange={(e) => {
            const ch = e.target.value as Channel;
            setV((x) => ({ ...x, channel: ch, price_list: canSetLimit && ch === "bayi" && x.price_list === "perakende" ? "bayi" : x.price_list }));
          }}>
            {(Object.keys(CHANNELS) as Channel[]).map((k) => <option key={k} value={k}>{CHANNELS[k]}</option>)}
          </Select>
        </Field>
        <Field label="Fiyat listesi" hint={canSetLimit ? "Satış ve siparişte bu liste uygulanır" : "Yalnızca yönetici değiştirir"}>
          <Select value={v.price_list} disabled={!canSetLimit} onChange={(e) => set("price_list", e.target.value as PriceList)}>
            {(Object.keys(PRICE_LISTS) as PriceList[]).map((k) => <option key={k} value={k}>{PRICE_LISTS[k]}</option>)}
          </Select>
        </Field>
        {v.channel !== "perakende" ? (
          <Field label="Müşterideki sebil sayısı" hint="Bizim verdiğimiz sebil / su makinesi adedi">
            <Input inputMode="numeric" value={String(v.dispenser_count)} onChange={(e) => set("dispenser_count", Number.parseInt(e.target.value.replace(/\D/g, "") || "0", 10))} />
          </Field>
        ) : null}
        <Field label="Bölgeler" hint="Örn. Kartepe, Sapanca"><Input value={v.regions ?? ""} onChange={(e) => set("regions", e.target.value)} /></Field>
        <Field label="Varsayılan sevkiyat sorumlusu" hint="Bu müşterinin siparişleri otomatik atanır">
          <Select value={v.default_assignee ?? ""} onChange={(e) => set("default_assignee", e.target.value || null)}>
            <option value="">Yok</option>
            {assignees.map((a) => <option key={a.user_id} value={a.user_id}>{a.display_name}</option>)}
          </Select>
        </Field>
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
