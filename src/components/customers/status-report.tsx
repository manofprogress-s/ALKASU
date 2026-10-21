"use client";
import { CustomerMessage } from "./customer-message";
import { useState } from "react";
import Link from "next/link";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { MessageCircle, Phone, PhoneCall, ShoppingCart } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge, Empty } from "@/components/ui/card";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { useToast } from "@/components/ui/toast";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import { formatTRY, todayISO } from "@/lib/format";
import { formatPhone } from "@/lib/username";
import {
  BUCKET_LABEL, BUCKET_TONE, OUTCOME_LABEL, OUTCOMES, agoText, reasonText, telUrl, whatsappUrl, type Outcome, type StatusRow,
} from "@/lib/customer-status";

export function AreaSelect({ areas, value }: { areas: string[]; value: string }) {
  const router = useRouter();
  const path = usePathname();
  const params = useSearchParams();
  return (
    <Select aria-label="Bölge" value={value} onChange={(e) => {
      const p = new URLSearchParams(params.toString());
      if (e.target.value) p.set("bolge", e.target.value); else p.delete("bolge");
      p.delete("s");
      router.replace(`${path}?${p.toString()}`);
    }}>
      <option value="">Tüm bölgeler</option>
      {areas.map((a) => <option key={a} value={a}>{a}</option>)}
    </Select>
  );
}

function addDays(n: number) {
  const d = new Date(`${todayISO()}T12:00:00`);
  d.setDate(d.getDate() + n);
  return d.toISOString().slice(0, 10);
}

function shortDate(iso: string) {
  const [, m, d] = iso.slice(0, 10).split("-");
  return `${d}.${m}`;
}

/** Arama listesi: ara, WhatsApp, sipariş, sonuç yaz (M-23…M-25) */
export function StatusList({ rows, isAdmin, dealer, businessId }: { rows: StatusRow[]; isAdmin: boolean; dealer: boolean; businessId: string }) {
  const router = useRouter();
  const toast = useToast();
  const [target, setTarget] = useState<StatusRow | null>(null);
  const [outcome, setOutcome] = useState<Outcome | null>(null);
  const [next, setNext] = useState("");
  const [minDate, setMinDate] = useState("");
  const [note, setNote] = useState("");
  const [saving, setSaving] = useState(false);

  function open(r: StatusRow) {
    setTarget(r);
    setOutcome(null);
    setNext(addDays(3));
    setMinDate(addDays(1));
    setNote("");
  }

  async function save() {
    if (!target || !outcome) return;
    setSaving(true);
    const { error } = await supabaseBrowser().rpc("log_customer_call", {
      p_business: businessId, p_customer: target.id, p_outcome: outcome, p_note: note.trim() || null,
      p_next: outcome === "sonra" ? next : null,
    });
    setSaving(false);
    if (error) return toast(errorMessage(error), "danger");
    const t = target;
    setTarget(null);
    if (outcome === "siparis") {
      router.push(`/siparisler/yeni?musteri=${t.id}`);
      return;
    }
    toast(`${t.name}: ${OUTCOME_LABEL[outcome]}`, "ok");
    router.refresh();
  }

  if (!rows.length) return <Empty>Bu bölümde müşteri yok.</Empty>;
  return (
    <>
      <ul className="space-y-2">
        {rows.map((r) => {
          const tel = telUrl(r.phone);
          const wa = whatsappUrl(r.phone);
          const where = [r.area, r.district, r.brand_pref].filter(Boolean).join(" · ");
          return (
            <li key={r.id} className="rounded-2xl border border-border bg-surface p-3">
              <div className="flex items-start justify-between gap-2">
                <div className="min-w-0">
                  {dealer ? <div className="font-semibold leading-tight">{r.name}</div> : (
                    <Link href={`/musteriler/${r.id}`} className="font-semibold leading-tight hover:text-brand">{r.name}</Link>
                  )}
                  <div className="text-xs text-muted">{r.code}{where ? ` · ${where}` : ""}</div>
                </div>
                <Badge tone={BUCKET_TONE[r.bucket] ?? "neutral"} className="shrink-0">{BUCKET_LABEL[r.bucket] ?? r.bucket}</Badge>
              </div>
              <div className="mt-1.5 text-sm">
                <b>{agoText(r.days)}</b>
                <span className="text-muted"> · {reasonText(r)} · {r.orders} alım</span>
                {isAdmin && r.total ? <span className="num text-muted"> · {formatTRY(r.total)}</span> : null}
                {isAdmin && r.legacy_debt ? <span className="num text-warn"> · eski borç {formatTRY(r.legacy_debt)}</span> : null}
              </div>
              {r.preferred_product ? <div className="text-xs text-muted">Tercihi: {r.preferred_product}</div> : null}
              {r.last_call_at ? (
                <div className="mt-1 text-xs text-muted">
                  Son arama: {r.last_caller ?? "—"}, {shortDate(r.last_call_at)} · {OUTCOME_LABEL[r.last_outcome ?? ""] ?? r.last_outcome}
                  {r.next_call_on ? ` · tekrar ${shortDate(r.next_call_on)}` : ""}
                </div>
              ) : null}
              <div className="mt-2 flex flex-wrap gap-2">
                {tel ? (
                  <a href={tel} onClick={() => open(r)} className="inline-flex h-10 items-center gap-1.5 rounded-xl bg-brand px-3 text-sm font-semibold text-white">
                    <Phone className="h-4 w-4" /> {formatPhone(r.phone)}
                  </a>
                ) : <span className="inline-flex h-10 items-center rounded-xl bg-surface-2 px-3 text-sm text-muted">Telefon yok</span>}
                {r.extra_phones.slice(0, 2).map((p) => (
                  <a key={p} href={telUrl(p) ?? undefined} onClick={() => open(r)} className="inline-flex h-10 items-center gap-1 rounded-xl border border-border px-3 text-sm">
                    <Phone className="h-4 w-4" /> {formatPhone(p)}
                  </a>
                ))}
                {!dealer ? (
                  <CustomerMessage target={{ id: r.id, name: r.name, phones: [r.phone, ...r.extra_phones], channel: r.channel }} />
                ) : wa ? (
                  <a href={wa} target="_blank" rel="noreferrer" className="inline-flex h-10 items-center gap-1 rounded-xl border border-border px-3 text-sm" aria-label="WhatsApp">
                    <MessageCircle className="h-4 w-4 text-ok" /> WhatsApp
                  </a>
                ) : null}
                <Link href={`/siparisler/yeni?musteri=${r.id}`} className="inline-flex h-10 items-center gap-1 rounded-xl border border-border px-3 text-sm">
                  <ShoppingCart className="h-4 w-4" /> Sipariş
                </Link>
                <button type="button" onClick={() => open(r)} className="inline-flex h-10 items-center gap-1 rounded-xl border border-border px-3 text-sm">
                  <PhoneCall className="h-4 w-4" /> Sonucu yaz
                </button>
              </div>
            </li>
          );
        })}
      </ul>

      <Dialog open={!!target} onClose={() => setTarget(null)} title={target ? `${target.name} · arama sonucu` : ""}
        footer={<Button size="lg" className="w-full" disabled={!outcome} loading={saving} onClick={() => void save()}>
          {outcome === "siparis" ? "Kaydet ve sipariş aç" : "Kaydet"}
        </Button>}>
        <div className="space-y-3">
          <div className="grid gap-2">
            {OUTCOMES.map((o) => (
              <button key={o.key} type="button" onClick={() => setOutcome(o.key)}
                className={`rounded-xl border px-3 py-2 text-left ${outcome === o.key ? "border-brand bg-brand-soft" : "border-border"}`}>
                <span className="block font-medium">{o.label}</span>
                <span className="block text-xs text-muted">{o.hint}</span>
              </button>
            ))}
          </div>
          {outcome === "sonra" ? (
            <Field label="Ne zaman tekrar aranacak?">
              <Input type="date" min={minDate} value={next} onChange={(e) => setNext(e.target.value)} />
            </Field>
          ) : null}
          <Field label="Not (isteğe bağlı)">
            <Input value={note} maxLength={500} onChange={(e) => setNote(e.target.value)} placeholder="Örn. perşembe öğleden sonra arayın" />
          </Field>
        </div>
      </Dialog>
    </>
  );
}
