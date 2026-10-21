"use client";
import { useState } from "react";
import { Crosshair, MapPin, Search, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Field, Input } from "@/components/ui/field";
import { locationInput, type LatLng } from "@/lib/geo";
import { resolveMapsLink } from "@/lib/geo-actions";
import { LocationView } from "./location-view";
import { LOCATION_NOTICE } from "@/lib/kvkk";

/**
 * Konum alanı: Google Maps bağlantısı / koordinat yapıştırılır ya da cihazın konumu alınır.
 * Adres metni verilirse "Haritada bul" ile Google Maps'te aranıp iğne bırakılabilir.
 */
export function LocationField({ value, onChange, address, customer = false }: {
  value: LatLng | null;
  onChange: (v: LatLng | null) => void;
  address?: string | null;
  /** Müşteriye gösterilen form: cihaz konumu öncesi açıklama (K-05) */
  customer?: boolean;
}) {
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function apply(input: string) {
    setError(null);
    if (!input.trim()) return;
    const found = locationInput(input);
    let p = found.point;
    if (!p && found.link) {
      setBusy(true);
      try {
        p = await resolveMapsLink(found.link);
      } catch {
        p = null; // sunucuya ulaşılamadı (ör. uygulama güncellendi): aşağıdaki açıklama gösterilir
      } finally {
        setBusy(false);
      }
      if (!p) {
        return setError("Kısa Google Maps bağlantısı açılamadı. Bağlantıyı tarayıcıda açıp adres çubuğundaki uzun bağlantıyı kopyalayın ya da haritada yere uzun basıp çıkan '40.76, 29.94' koordinatını yapıştırın. Konum kaydedilmedi.");
      }
    }
    if (!p) return setError("Konum okunamadı; konum kaydedilmedi. Google Maps'te yeri işaretleyip 'Paylaş → Bağlantıyı kopyala' ile aldığınız bağlantıyı veya '40.76, 29.94' biçiminde koordinat yapıştırın.");
    onChange(p);
    setText("");
  }

  function useDevice() {
    if (!("geolocation" in navigator)) return setError("Bu cihaz konum vermiyor.");
    setBusy(true);
    setError(null);
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        setBusy(false);
        onChange({ lat: Math.round(pos.coords.latitude * 1e6) / 1e6, lng: Math.round(pos.coords.longitude * 1e6) / 1e6 });
      },
      () => {
        setBusy(false);
        setError("Konum alınamadı. Tarayıcıda konum iznini açın.");
      },
      { enableHighAccuracy: true, timeout: 15000 },
    );
  }

  return (
    <div className="space-y-2">
      <Field
        label={customer ? "Konum (isteğe bağlı)" : "Konum (Google Maps)"}
        error={error}
        hint={customer ? "Google Maps'te evinizi bulup 'Paylaş → Bağlantıyı kopyala' ile aldığınız bağlantıyı yapıştırın." : "Bağlantı veya koordinat yapıştırın; müşterinin yanındaysanız 'Bulunduğum konum'a basın."}
      >
        <div className="flex gap-2">
          <Input
            value={text}
            placeholder="https://maps.app.goo.gl/… veya 40.76, 29.94"
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => {
              // Enter formu (müşteriyi) konum uygulanmadan kaydetmesin: önce konumu uygula
              if (e.key === "Enter") {
                e.preventDefault();
                void apply(text);
              }
            }}
            onBlur={() => { if (text.trim()) void apply(text); }}
            onPaste={(e) => {
              const t = e.clipboardData.getData("text");
              if (t) {
                e.preventDefault();
                setText(t);
                void apply(t);
              }
            }}
          />
          <Button variant="secondary" loading={busy} disabled={!text.trim()} onClick={() => void apply(text)}>Uygula</Button>
        </div>
      </Field>
      {customer ? <p className="text-xs text-muted">{LOCATION_NOTICE}</p> : null}
      <div className="flex flex-wrap gap-2">
        <Button size="sm" variant="secondary" onClick={useDevice} loading={busy}>
          <Crosshair className="h-4 w-4" /> {customer ? "Konumumu kullan" : "Bulunduğum konum"}
        </Button>
        {address?.trim() ? (
          <a
            className="inline-flex h-9 items-center gap-1 rounded-xl border border-border bg-surface px-3 text-sm"
            href={`https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(address.trim())}`}
            target="_blank"
            rel="noreferrer"
          >
            <Search className="h-4 w-4" /> {customer ? "Haritada kendim işaretle" : "Adresi haritada bul"}
          </a>
        ) : null}
        {value ? (
          <Button size="sm" variant="ghost" onClick={() => onChange(null)}>
            <X className="h-4 w-4" /> Konumu kaldır
          </Button>
        ) : null}
      </div>
      {value ? <LocationView point={value} map /> : (
        <div className="flex items-center gap-2 text-sm text-muted"><MapPin className="h-4 w-4" /> Konum girilmedi</div>
      )}
    </div>
  );
}
