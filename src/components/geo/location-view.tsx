import { MapPin, Navigation } from "lucide-react";
import { directionsUrl, embedUrl, mapsUrl, type LatLng } from "@/lib/geo";

/** Konum gösterimi: Google Maps'te aç, yol tarifi; istenirse küçük harita. */
export function LocationView({ point, map = false }: { point: LatLng | null; map?: boolean }) {
  if (!point) return null;
  return (
    <div className="space-y-2">
      <div className="flex flex-wrap gap-2">
        <a className="inline-flex h-9 items-center gap-1 rounded-xl border border-border bg-surface px-3 text-sm text-brand" href={mapsUrl(point)} target="_blank" rel="noreferrer">
          <MapPin className="h-4 w-4" /> Haritada aç
        </a>
        <a className="inline-flex h-9 items-center gap-1 rounded-xl bg-brand px-3 text-sm font-medium text-white" href={directionsUrl(point)} target="_blank" rel="noreferrer">
          <Navigation className="h-4 w-4" /> Yol tarifi
        </a>
        <span className="num self-center text-xs text-muted">{point.lat.toFixed(5)}, {point.lng.toFixed(5)}</span>
      </div>
      {map ? (
        <iframe
          title="Konum haritası"
          src={embedUrl(point)}
          className="h-48 w-full rounded-xl border border-border"
          loading="lazy"
          referrerPolicy="no-referrer-when-downgrade"
        />
      ) : null}
    </div>
  );
}
