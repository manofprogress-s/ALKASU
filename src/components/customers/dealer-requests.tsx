"use client";
import { useState } from "react";
import { Check, Send, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Alert, Badge, Card } from "@/components/ui/card";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input, Textarea } from "@/components/ui/field";
import { LocationField } from "@/components/geo/location-field";
import { useRpc } from "@/lib/use-action";
import { formatDateTime } from "@/lib/format";
import { toLatLng, type LatLng } from "@/lib/geo";

export interface CustomerRequest {
  id: string;
  customer_id: string | null;
  data: { name?: string; phone?: string; address?: string; note?: string; latitude?: number; longitude?: number };
  status: "bekliyor" | "onaylandi" | "reddedildi" | "iptal";
  requested_at: string;
  decided_at: string | null;
  decision_note: string | null;
  requester?: string | null;
}

export interface CardValues {
  name: string;
  phone: string | null;
  address: string | null;
  note: string | null;
  latitude: number | null;
  longitude: number | null;
}

const STATUS: Record<CustomerRequest["status"], { label: string; tone: "warn" | "ok" | "danger" | "neutral" }> = {
  bekliyor: { label: "Bayi onayı bekliyor", tone: "warn" },
  onaylandi: { label: "Bayi onayladı", tone: "ok" },
  reddedildi: { label: "Bayi reddetti", tone: "danger" },
  iptal: { label: "Geri çekildi", tone: "neutral" },
};

const FIELDS: [keyof CardValues, string][] = [["name", "Ad"], ["phone", "Telefon"], ["address", "Adres"], ["note", "Not"]];

/** Önerinin mevcut karttan farkı: "Adres: eski → yeni" */
function diffLines(req: CustomerRequest, current: CardValues | null) {
  const lines: { label: string; from: string | null; to: string }[] = [];
  for (const [k, label] of FIELDS) {
    const to = req.data[k as keyof CustomerRequest["data"]];
    if (to === undefined) continue;
    const from = current ? (current[k] as string | null) : null;
    if (current && String(from ?? "") === String(to)) continue;
    lines.push({ label, from, to: String(to) });
  }
  if (req.data.latitude !== undefined && (!current || current.latitude !== req.data.latitude || current.longitude !== req.data.longitude)) {
    lines.push({ label: "Konum", from: current?.latitude != null ? "var" : null, to: `${req.data.latitude}, ${req.data.longitude}` });
  }
  return lines;
}

/** Merkez: bayinin listesine müşteri önerir ya da bayinin müşterisinde değişiklik önerir (G-14, G-15) */
export function ProposeCustomer({ dealerId, dealerName, customerId, current, label }: {
  dealerId: string; dealerName: string; customerId?: string; current?: CardValues; label?: string;
}) {
  const { call, busy } = useRpc();
  const [open, setOpen] = useState(false);
  const [name, setName] = useState(current?.name ?? "");
  const [phone, setPhone] = useState(current?.phone ?? "");
  const [address, setAddress] = useState(current?.address ?? "");
  const [note, setNote] = useState(current?.note ?? "");
  const [location, setLocation] = useState<LatLng | null>(current ? toLatLng(current.latitude, current.longitude) : null);

  async function send() {
    const ok = await call("propose_dealer_customer", {
      p_dealer: dealerId,
      p_customer: customerId ?? null,
      p: { name, phone, address, note, latitude: location?.lat ?? null, longitude: location?.lng ?? null },
    }, { success: `Öneri ${dealerName} bayisinin onayına gönderildi` });
    if (ok) setOpen(false);
  }

  return (
    <>
      <Button variant="secondary" onClick={() => setOpen(true)}><Send className="h-4 w-4" /> {label ?? (customerId ? "Değişiklik öner" : "Müşteri öner")}</Button>
      <Dialog open={open} onClose={() => setOpen(false)} title={customerId ? "Değişiklik öner" : `${dealerName} listesine müşteri öner`}
        footer={<Button className="w-full" loading={busy} disabled={name.trim().length < 2} onClick={() => void send()}>Bayinin onayına gönder</Button>}>
        <div className="space-y-3">
          <Alert tone="neutral">Bu müşteri {dealerName} bayisine ait. Değişiklik bayi onaylayınca uygulanır.</Alert>
          <Field label="Ad soyad / firma"><Input value={name} onChange={(e) => setName(e.target.value)} /></Field>
          <Field label="Telefon"><Input type="tel" inputMode="tel" value={phone} onChange={(e) => setPhone(e.target.value)} /></Field>
          <Field label="Açık adres"><Textarea value={address} onChange={(e) => setAddress(e.target.value)} /></Field>
          <LocationField value={location} onChange={setLocation} address={address} />
          <Field label="Not"><Input value={note} onChange={(e) => setNote(e.target.value)} /></Field>
        </div>
      </Dialog>
    </>
  );
}

/** Önerilerin listesi. mode="dealer": bayi onaylar/reddeder; mode="staff": merkez durumunu görür, bekleyeni geri çeker. */
export function RequestList({ rows, mode, currentById, nameById }: {
  rows: CustomerRequest[];
  mode: "dealer" | "staff";
  currentById: Record<string, CardValues>;
  nameById?: Record<string, string>;
}) {
  const { call, busy } = useRpc();
  const [reject, setReject] = useState<CustomerRequest | null>(null);
  const [reason, setReason] = useState("");
  if (!rows.length) return null;
  return (
    <Card className="space-y-3">
      <h2 className="font-semibold">{mode === "dealer" ? "Merkezden gelen öneriler" : "Bayiye gönderilen öneriler"}</h2>
      <ul className="divide-y divide-border">
        {rows.map((r) => {
          const current = r.customer_id ? currentById[r.customer_id] ?? null : null;
          const lines = diffLines(r, current);
          const st = STATUS[r.status];
          return (
            <li key={r.id} className="space-y-2 py-3">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span className="font-medium">
                  {r.customer_id ? `Değişiklik: ${current?.name ?? nameById?.[r.customer_id] ?? "müşteri"}` : `Yeni müşteri: ${r.data.name ?? ""}`}
                </span>
                <Badge tone={st.tone}>{st.label}</Badge>
              </div>
              <ul className="space-y-0.5 text-sm">
                {lines.map((l) => (
                  <li key={l.label}><span className="text-muted">{l.label}:</span> {l.from ? <><s className="text-muted">{l.from}</s> → </> : null}<span className="font-medium">{l.to}</span></li>
                ))}
                {lines.length === 0 ? <li className="text-muted">Değişiklik yok</li> : null}
              </ul>
              <div className="text-xs text-muted">
                {formatDateTime(r.requested_at)}{r.requester ? ` · ${r.requester}` : ""}
                {r.decision_note ? ` · Not: ${r.decision_note}` : ""}
              </div>
              {r.status === "bekliyor" && mode === "dealer" ? (
                <div className="flex gap-2">
                  <Button size="sm" variant="ok" loading={busy} onClick={() => void call("decide_customer_request", { p_request: r.id, p_approve: true }, { success: "Öneri onaylandı" })}>
                    <Check className="h-4 w-4" /> Onayla
                  </Button>
                  <Button size="sm" variant="secondary" onClick={() => { setReason(""); setReject(r); }}><X className="h-4 w-4" /> Reddet</Button>
                </div>
              ) : null}
              {r.status === "bekliyor" && mode === "staff" ? (
                <Button size="sm" variant="ghost" loading={busy} onClick={() => void call("cancel_customer_request", { p_request: r.id }, { success: "Öneri geri çekildi" })}>Geri çek</Button>
              ) : null}
            </li>
          );
        })}
      </ul>
      <Dialog open={!!reject} onClose={() => setReject(null)} title="Öneriyi reddet"
        footer={<Button className="w-full" variant="danger" loading={busy} onClick={async () => {
          if (!reject) return;
          const ok = await call("decide_customer_request", { p_request: reject.id, p_approve: false, p_note: reason }, { success: "Öneri reddedildi" });
          if (ok) setReject(null);
        }}>Reddet</Button>}>
        <Field label="Neden (isteğe bağlı)"><Input value={reason} maxLength={300} onChange={(e) => setReason(e.target.value)} /></Field>
      </Dialog>
    </Card>
  );
}
