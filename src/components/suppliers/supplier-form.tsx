"use client";
import { useState } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { Alert, Card } from "@/components/ui/card";
import { Field, Input, Textarea } from "@/components/ui/field";
import { useAppContext } from "@/components/shell/context";
import { useToast } from "@/components/ui/toast";
import { LocationField } from "@/components/geo/location-field";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import type { LatLng } from "@/lib/geo";

export interface SupplierValue {
  id?: string;
  name: string;
  contact_name: string | null;
  phone: string | null;
  tax_no: string | null;
  address: string | null;
  note: string | null;
  active: boolean;
  location: LatLng | null;
}

const EMPTY: SupplierValue = { name: "", contact_name: "", phone: "", tax_no: "", address: "", note: "", active: true, location: null };

export function SupplierForm({ initial }: { initial: SupplierValue | null }) {
  const ctx = useAppContext();
  const router = useRouter();
  const toast = useToast();
  const [v, setV] = useState<SupplierValue>(initial ?? EMPTY);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const set = <K extends keyof SupplierValue>(k: K, val: SupplierValue[K]) => setV((x) => ({ ...x, [k]: val }));

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setSaving(true);
    setError(null);
    const { location, ...rest } = v;
    const { data, error } = await supabaseBrowser().rpc("upsert_supplier", {
      p_business: ctx.businessId,
      p: { ...rest, id: v.id ?? null, latitude: location?.lat ?? null, longitude: location?.lng ?? null },
    });
    setSaving(false);
    if (error) return setError(errorMessage(error));
    toast("Tedarikçi kaydedildi", "ok");
    if (!v.id) router.push(`/tedarikciler/${data as string}`);
    else router.refresh();
  }

  return (
    <form onSubmit={save}>
      <Card className="grid gap-3 md:grid-cols-2">
        <Field label="Firma adı"><Input required value={v.name} onChange={(e) => set("name", e.target.value)} /></Field>
        <Field label="Yetkili kişi"><Input value={v.contact_name ?? ""} onChange={(e) => set("contact_name", e.target.value)} /></Field>
        <Field label="Telefon"><Input inputMode="tel" value={v.phone ?? ""} onChange={(e) => set("phone", e.target.value)} /></Field>
        <Field label="Vergi no"><Input value={v.tax_no ?? ""} onChange={(e) => set("tax_no", e.target.value)} /></Field>
        <Field label="Adres" className="md:col-span-2"><Textarea value={v.address ?? ""} onChange={(e) => set("address", e.target.value)} /></Field>
        <div className="md:col-span-2">
          <LocationField value={v.location} onChange={(p) => set("location", p)} address={v.address} />
        </div>
        <Field label="Not" className="md:col-span-2"><Input value={v.note ?? ""} onChange={(e) => set("note", e.target.value)} /></Field>
        {v.id ? (
          <label className="flex items-center gap-2 md:col-span-2">
            <input type="checkbox" className="h-5 w-5" checked={v.active} onChange={(e) => set("active", e.target.checked)} /> Aktif
          </label>
        ) : null}
        {error ? <div className="md:col-span-2"><Alert>{error}</Alert></div> : null}
        <Button type="submit" className="md:col-span-2" loading={saving}>Kaydet</Button>
      </Card>
    </form>
  );
}
