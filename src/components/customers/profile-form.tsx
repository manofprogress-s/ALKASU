"use client";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Field, Input, Textarea } from "@/components/ui/field";
import { useAppContext } from "@/components/shell/context";
import { LocationField } from "@/components/geo/location-field";
import { useRpc } from "@/lib/use-action";
import type { LatLng } from "@/lib/geo";

/** Müşteri / bayi kendi ad, adres ve konumunu günceller. Bayi için bu konum rotanın başlangıç noktasıdır. */
export function ProfileForm({ initial, isDealer }: { initial: { name: string; address: string | null; location: LatLng | null }; isDealer: boolean }) {
  const ctx = useAppContext();
  const { call, busy } = useRpc();
  const [name, setName] = useState(initial.name);
  const [address, setAddress] = useState(initial.address ?? "");
  const [location, setLocation] = useState<LatLng | null>(initial.location);
  return (
    <Card className="space-y-3">
      <h2 className="font-semibold">{isDealer ? "Bayi bilgilerim" : "Bilgilerim"}</h2>
      <Field label={isDealer ? "Firma / bayi adı" : "Ad soyad"}><Input value={name} onChange={(e) => setName(e.target.value)} /></Field>
      <Field label={isDealer ? "Depo adresi" : "Teslimat adresi"}><Textarea value={address} onChange={(e) => setAddress(e.target.value)} /></Field>
      <LocationField value={location} onChange={setLocation} address={address} />
      {isDealer ? <p className="text-xs text-muted">Bu konum, teslimat rotanızın başlangıç noktası olarak kullanılır.</p> : null}
      <Button loading={busy} onClick={() => void call("update_my_profile", {
        p_business: ctx.businessId,
        p: { name, address, latitude: location?.lat ?? null, longitude: location?.lng ?? null },
      }, { success: "Bilgileriniz kaydedildi" })}>Kaydet</Button>
    </Card>
  );
}
