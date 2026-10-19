"use client";
import { useState } from "react";
import Link from "next/link";
import { FileSpreadsheet } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Alert, Card, Stat } from "@/components/ui/card";
import { useAppContext } from "@/components/shell/context";
import { useToast } from "@/components/ui/toast";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import { readWorkbook } from "@/lib/excel/read";
import { subscriberRows } from "@/lib/customer-status";

interface Issue { row: number; field: string; message: string }
interface Matched { row: number; abone: number; ad: string; eslesen: string }
interface Summary { rows: number; new: number; updated: number; phone_match: number; no_phone: number; with_location: number }
interface Result { ok: boolean; applied: boolean; errors: Issue[]; matched: Matched[]; summary: Summary }

const CHUNK = 1000;

function merge(a: Result | null, b: Result): Result {
  if (!a) return b;
  const s = { ...a.summary };
  for (const k of Object.keys(s) as (keyof Summary)[]) s[k] += b.summary[k];
  return { ok: a.ok && b.ok, applied: a.applied && b.applied, errors: [...a.errors, ...b.errors], matched: [...a.matched, ...b.matched], summary: s };
}

/** Eski sistemin abone listesini (Excel) içe aktarır (M-20). Önce kontrol, sonra onayla aktarım; 1000'erli parçalar. */
export function SubscriberImport() {
  const ctx = useAppContext();
  const toast = useToast();
  const [rows, setRows] = useState<Record<string, unknown>[] | null>(null);
  const [check, setCheck] = useState<Result | null>(null);
  const [done, setDone] = useState<Result | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function run(list: Record<string, unknown>[], dry: boolean) {
    let acc: Result | null = null;
    for (let i = 0; i < list.length; i += CHUNK) {
      const { data, error } = await supabaseBrowser().rpc("import_subscribers", { p_business: ctx.businessId, p_rows: list.slice(i, i + CHUNK), p_dry_run: dry });
      if (error) throw error;
      acc = merge(acc, data as Result);
      if (!dry && !(data as Result).ok) break;
    }
    return acc;
  }

  async function pick(f: File) {
    setError(null); setCheck(null); setDone(null); setRows(null);
    if (/\.xls$/i.test(f.name)) {
      setError("Bu dosya eski Excel biçiminde (.xls). Excel'de açıp “Farklı kaydet → Excel Çalışma Kitabı (.xlsx)” ile kaydedip tekrar seçin.");
      return;
    }
    setBusy(true);
    try {
      const wb = await readWorkbook(f);
      const first = Object.values(wb)[0] ?? [];
      const list = subscriberRows(first);
      if (!list.length) throw new Error("Dosyada abone satırı bulunamadı. İlk satır başlık olmalı (Abone, Abone/Firma Adı, Telefon1…).");
      setRows(list);
      setCheck(await run(list, true));
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  async function apply() {
    if (!rows) return;
    setBusy(true);
    try {
      const r = await run(rows, false);
      setDone(r);
      if (r?.ok) toast(`${r.summary.new} yeni, ${r.summary.updated} güncellenen abone`, "ok");
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  const r = done ?? check;
  return (
    <div className="space-y-4">
      <Card className="space-y-3">
        <label className="flex cursor-pointer items-center gap-3 rounded-xl border border-dashed border-border p-4 hover:bg-surface-2">
          <FileSpreadsheet className="h-8 w-8 text-brand" />
          <span className="min-w-0 flex-1">
            <span className="block font-medium">Excel dosyası seçin (.xlsx)</span>
            <span className="block text-sm text-muted">Sütunlar: Abone, Abone/Firma Adı, Adres, Telefon1–5, Son Satış Tarihi, Alım Periyodu, Konum…</span>
          </span>
          <input type="file" accept=".xlsx,.xls,.csv" className="sr-only" disabled={busy}
            onChange={(e) => { const f = e.target.files?.[0]; if (f) void pick(f); e.target.value = ""; }} />
        </label>
        <p className="text-xs text-muted">
          Eski borç bakiyesi cariye <b>işlenmez</b>, yalnızca bilgi olarak görünür. Elle açılmış bir müşterinin telefonu tutarsa yeni kart açılmaz, o karta bağlanır.
        </p>
        {busy ? <Alert tone="neutral">İşleniyor…</Alert> : null}
        {error ? <Alert>{error}</Alert> : null}
      </Card>

      {r ? (
        <Card className="space-y-3">
          <h2 className="font-semibold">{done ? (done.ok ? "Aktarıldı" : "Aktarılamadı") : "Kontrol sonucu"}</h2>
          <div className="grid grid-cols-2 gap-2 md:grid-cols-5">
            <Stat label="Satır" value={r.summary.rows} />
            <Stat label="Yeni müşteri" value={r.summary.new} tone="ok" />
            <Stat label="Güncellenecek" value={r.summary.updated} hint={r.summary.phone_match ? `${r.summary.phone_match} telefonla eşleşti` : undefined} />
            <Stat label="Telefonsuz" value={r.summary.no_phone} tone={r.summary.no_phone ? "warn" : undefined} />
            <Stat label="Konumlu" value={r.summary.with_location} />
          </div>
          {r.errors.length ? (
            <div>
              <Alert>{r.errors.length} hata var; düzeltip tekrar yükleyin.</Alert>
              <ul className="mt-2 max-h-60 overflow-y-auto text-sm">
                {r.errors.slice(0, 100).map((e, i) => <li key={i}>Satır {e.row} · {e.field}: {e.message}</li>)}
              </ul>
            </div>
          ) : null}
          {r.matched.length ? (
            <details className="text-sm">
              <summary className="cursor-pointer text-brand">Telefonla mevcut karta bağlananlar ({r.matched.length})</summary>
              <ul className="mt-2 max-h-60 overflow-y-auto">
                {r.matched.map((m) => <li key={m.abone}>Abone {m.abone} “{m.ad}” → {m.eslesen}</li>)}
              </ul>
            </details>
          ) : null}
          {!done && r.ok ? (
            <Button size="lg" className="w-full" loading={busy} onClick={() => void apply()}>
              {r.summary.rows} satırı aktar
            </Button>
          ) : null}
          {done?.ok ? <Link href="/musteriler/durum" className="inline-flex h-11 items-center rounded-xl bg-brand px-4 font-medium text-white">Durum raporuna git</Link> : null}
        </Card>
      ) : null}
    </div>
  );
}
