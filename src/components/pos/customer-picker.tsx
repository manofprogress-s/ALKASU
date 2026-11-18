"use client";
import { useEffect, useRef, useState } from "react";
import { TriangleAlert, UserPlus } from "lucide-react";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input } from "@/components/ui/field";
import { Button } from "@/components/ui/button";
import { Alert, Badge } from "@/components/ui/card";
import { useAppContext } from "@/components/shell/context";
import type { PosCustomer } from "@/lib/catalog";
import { rankLocal, rowContainers, rowToPosCustomer, type CustomerSearchRow } from "@/lib/customer-search";
import { formatTRY } from "@/lib/format";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";

export type PickedContainers = ReturnType<typeof rowContainers>;

/**
 * Satış ekranı müşteri seçimi (M-29): arama sunucuda (tüm müşteriler, bayi kartları üstte).
 * Bağlantı yoksa son seçilen müşterilerde aranır (çevrimdışı satış).
 */
export function CustomerPicker({
  open,
  onClose,
  recent,
  onPick,
  onCreated,
}: {
  open: boolean;
  onClose: () => void;
  recent: PosCustomer[];
  onPick: (c: PosCustomer, containers: PickedContainers | null) => void;
  onCreated: (c: PosCustomer) => void;
}) {
  const ctx = useAppContext();
  const [q, setQ] = useState("");
  const [found, setFound] = useState<{ q: string; list: PosCustomer[]; rows: Map<string, CustomerSearchRow>; total: number; offline: boolean } | null>(null);
  const [busy, setBusy] = useState(false);
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState("");
  const [phone, setPhone] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const seq = useRef(0);

  useEffect(() => () => { if (timer.current) clearTimeout(timer.current); }, []);

  function search(v: string) {
    setQ(v);
    if (timer.current) clearTimeout(timer.current);
    const query = v.trim();
    if (query.length < 2) { setFound(null); setBusy(false); return; }
    setBusy(true);
    timer.current = setTimeout(async () => {
      const n = ++seq.current;
      const { data, error } = await supabaseBrowser().rpc("search_customers", { p_business: ctx.businessId, p_q: query, p_limit: 15 });
      if (n !== seq.current) return;
      setBusy(false);
      if (error) {
        // Çevrimdışı ya da hata: son seçilen müşterilerde ara
        setFound({ q: query, list: rankLocal(recent, query, 15), rows: new Map(), total: 0, offline: true });
        return;
      }
      const rows = (data ?? []) as CustomerSearchRow[];
      setFound({ q: query, list: rows.map(rowToPosCustomer), rows: new Map(rows.map((r) => [r.id, r])), total: Number(rows[0]?.total ?? 0), offline: false });
    }, 250);
  }

  async function create() {
    if (!name.trim()) return setError("Ad zorunludur");
    setSaving(true);
    setError(null);
    const { data, error } = await supabaseBrowser().rpc("upsert_customer", {
      p_business: ctx.businessId,
      p: { name: name.trim(), phone: phone.trim() || null },
    });
    setSaving(false);
    if (error) return setError(errorMessage(error));
    onCreated({ id: data as string, code: "", name: name.trim(), phone: phone.trim() || null, creditLimit: 0, unlimited: false, balance: 0, priceList: "perakende" });
    setCreating(false);
    setName("");
    setPhone("");
  }

  const list = q.trim().length >= 2 ? (found?.q === q.trim() ? found.list : []) : recent.slice(-8).reverse();

  return (
    <Dialog open={open} onClose={onClose} title={creating ? "Yeni müşteri" : "Müşteri seç"}>
      {creating ? (
        <div className="space-y-3">
          <Field label="Ad / unvan">
            <Input autoFocus value={name} onChange={(e) => setName(e.target.value)} />
          </Field>
          <Field label="Telefon">
            <Input inputMode="tel" value={phone} onChange={(e) => setPhone(e.target.value)} />
          </Field>
          <p className="text-xs text-muted">Veresiye limiti yönetici tarafından müşteri kartından tanımlanır.</p>
          {error ? <Alert>{error}</Alert> : null}
          <div className="flex gap-2">
            <Button variant="secondary" onClick={() => setCreating(false)}>
              Vazgeç
            </Button>
            <Button className="flex-1" onClick={create} loading={saving}>
              Kaydet ve seç
            </Button>
          </div>
        </div>
      ) : (
        <div className="space-y-3">
          <Input autoFocus placeholder="Ad, kısaltma, kod veya telefon" value={q} onChange={(e) => search(e.target.value)} autoComplete="off" />
          <Button variant="secondary" className="w-full" onClick={() => { setCreating(true); setName(q); }}>
            <UserPlus className="h-4 w-4" /> Yeni müşteri ekle
          </Button>
          {found?.offline && found.q === q.trim() ? <p className="text-xs text-warn">Bağlantı yok: yalnızca son seçilen müşterilerde arandı.</p> : null}
          {q.trim().length < 2 && list.length ? <p className="text-xs text-muted">Son seçilenler</p> : null}
          <ul className="divide-y divide-border">
            {list.map((c) => (
              <li key={c.id}>
                <button className="flex w-full items-center justify-between gap-2 py-3 text-left" onClick={() => { const r = found?.rows.get(c.id); onPick(c, r ? rowContainers(r) : null); }}>
                  <span className="min-w-0">
                    <span className="flex items-center gap-1.5">
                      <span className="truncate font-medium">{c.name}</span>
                      {c.channel === "bayi" ? <Badge tone="brand">BAYİ</Badge> : null}
                    </span>
                    <span className="block text-xs text-muted">
                      {c.code} {c.phone ? `· ${c.phone}` : ""}
                    </span>
                    {c.dealerHint ? (
                      <span className="mt-0.5 flex items-center gap-1 text-xs text-warn">
                        <TriangleAlert className="h-3.5 w-3.5 shrink-0" /> Bayi kartı olabilir: {c.dealerHint.name} ({c.dealerHint.code})
                      </span>
                    ) : null}
                  </span>
                  <span className={`num text-sm ${c.balance > 0 ? "text-warn" : "text-muted"}`}>{formatTRY(c.balance)}</span>
                </button>
              </li>
            ))}
            {q.trim().length >= 2 && busy ? <li className="py-6 text-center text-muted">Aranıyor…</li> : null}
            {q.trim().length >= 2 && !busy && found?.q === q.trim() && list.length === 0 ? <li className="py-6 text-center text-muted">Müşteri bulunamadı</li> : null}
          </ul>
          {found && !found.offline && found.q === q.trim() && found.total > found.list.length ? (
            <p className="text-xs text-muted">{found.total} eşleşmeden ilk {found.list.length} gösteriliyor; aramayı daraltın.</p>
          ) : null}
        </div>
      )}
    </Dialog>
  );
}
