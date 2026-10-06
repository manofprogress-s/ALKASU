"use client";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { LocationField } from "@/components/geo/location-field";
import { useRpc } from "@/lib/use-action";
import type { LatLng } from "@/lib/geo";

/** Depo konumu: rota planlamanın başlangıç noktası (D-056) */
export function DepotLocation({ locationId, initial }: { locationId: string; initial: LatLng | null }) {
  const { call, busy } = useRpc();
  const [point, setPoint] = useState<LatLng | null>(initial);
  return (
    <Card className="space-y-3">
      <h2 className="font-semibold">Depo konumu</h2>
      <p className="text-sm text-muted">Dağıtım rotaları bu noktadan başlar. Depodaysanız “Bulunduğum konum” düğmesine basmanız yeterli.</p>
      <LocationField value={point} onChange={setPoint} />
      <Button loading={busy} onClick={() => void call("set_location_coords", { p_location: locationId, p_lat: point?.lat ?? null, p_lng: point?.lng ?? null }, { success: "Depo konumu kaydedildi" })}>
        Kaydet
      </Button>
    </Card>
  );
}
