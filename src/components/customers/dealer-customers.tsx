"use client";
import { useMemo, useState } from "react";
import Link from "next/link";
import { Phone, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge, Card } from "@/components/ui/card";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input, Textarea } from "@/components/ui/field";
import { useAppContext } from "@/components/shell/context";
import { LocationField } from "@/components/geo/location-field";
import { useRpc } from "@/lib/use-action";
import { searchKey } from "@/lib/catalog";
import { toLatLng, type LatLng } from "@/lib/geo";

export interface DealerCustomer {
  id: string;
  code: string;
  name: string;
  phone: string | null;
  address: string | null;
  note: string | null;
  latitude: number | null;
  longitude: number | null;
  active: boolean;
}

interface Draft {
  id?: string;
  name: string;
  phone: string;
  address: string;
  note: string;
  location: LatLng | null;
  active: boolean;
}

const EMPTY: Draft = { name: "", phone: "", address: "", note: "", location: null, active: true };

export function DealerCustomers({ rows }: { rows: DealerCustomer[] }) {
  const ctx = useAppContext();
  const { call, busy } = useRpc();
  const [q, setQ] = useState("");
  const [draft, setDraft] = useState<Draft | null>(null);
  const shown = useMemo(() => {
    const k = searchKey(q.trim());
    return k ? rows.filter((r) => searchKey(`${r.name} ${r.phone ?? ""} ${r.address ?? ""}`).includes(k)) : rows;
  }, [rows, q]);
  const set = <K extends keyof Draft>(k: K, v: Draft[K]) => setDraft((d) => (d ? { ...d, [k]: v } : d));

  async function save() {
    if (!draft) return;
    const ok = await call(
      "dealer_upsert_customer",
      {
        p_business: ctx.businessId,
        p: {
          id: draft.id ?? null,
          name: draft.name,
          phone: draft.phone,
          address: draft.address,
          note: draft.note,
          active: draft.active,
          latitude: draft.location?.lat ?? null,
          longitude: draft.location?.lng ?? null,
        },
      },
      { success: draft.id ? "Müşteri güncellendi" : "Müşteri eklendi" },
    );
    if (ok) setDraft(null);
  }

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap gap-2">
        <Input className="max-w-xs" placeholder="Ad, telefon veya adres ara" value={q} onChange={(e) => setQ(e.target.value)} />
        <Button onClick={() => setDraft({ ...EMPTY })}>
          <Plus className="h-4 w-4" /> Yeni müşteri
        </Button>
      </div>
      {shown.length === 0 ? (
        <Card className="text-center text-muted">{rows.length ? "Aramaya uyan müşteri yok" : "Henüz müşteri eklemediniz."}</Card>
      ) : (
        <Card className="p-0">
          <ul className="divide-y divide-border">
            {shown.map((r) => (
              <li key={r.id} className="flex flex-wrap items-center justify-between gap-2 p-3">
                <button
                  type="button"
                  className="min-w-0 text-left"
                  onClick={() => setDraft({
                    id: r.id, name: r.name, phone: r.phone ?? "", address: r.address ?? "", note: r.note ?? "",
                    location: toLatLng(r.latitude, r.longitude), active: r.active,
                  })}
                >
                  <span className="block font-medium">{r.name} {!r.active ? <Badge>Pasif</Badge> : null} {r.latitude === null ? <Badge tone="warn">Konum yok</Badge> : null}</span>
                  <span className="line-clamp-1 block text-xs text-muted">{r.address ?? "Adres yok"}</span>
                </button>
                <span className="flex items-center gap-2">
                  {r.phone ? <a href={`tel:${r.phone}`} className="rounded-full p-2 text-brand hover:bg-surface-2" aria-label="Ara"><Phone className="h-4 w-4" /></a> : null}
                  {r.active ? (
                    <Link href={`/siparisler/yeni?musteri=${r.id}`} className="inline-flex h-9 items-center rounded-xl bg-brand px-3 text-sm font-medium text-white">Sipariş</Link>
                  ) : null}
                </span>
              </li>
            ))}
          </ul>
        </Card>
      )}

      <Dialog
        open={!!draft}
        onClose={() => setDraft(null)}
        title={draft?.id ? "Müşteriyi düzenle" : "Yeni müşteri"}
        footer={<Button className="w-full" loading={busy} disabled={!draft || draft.name.trim().length < 2} onClick={() => void save()}>Kaydet</Button>}
      >
        {draft ? (
          <div className="space-y-3">
            <Field label="Ad soyad / firma"><Input value={draft.name} onChange={(e) => set("name", e.target.value)} /></Field>
            <Field label="Telefon"><Input type="tel" inputMode="tel" value={draft.phone} onChange={(e) => set("phone", e.target.value)} /></Field>
            <Field label="Açık adres"><Textarea value={draft.address} onChange={(e) => set("address", e.target.value)} /></Field>
            <LocationField value={draft.location} onChange={(p) => set("location", p)} address={draft.address} />
            <Field label="Not"><Input value={draft.note} onChange={(e) => set("note", e.target.value)} /></Field>
            {draft.id ? (
              <label className="flex items-center gap-2 text-sm">
                <input type="checkbox" className="h-5 w-5" checked={draft.active} onChange={(e) => set("active", e.target.checked)} /> Aktif
              </label>
            ) : null}
          </div>
        ) : null}
      </Dialog>
    </div>
  );
}
