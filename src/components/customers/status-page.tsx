import Link from "next/link";
import { supabaseServer } from "@/lib/supabase/server";
import { Alert, Card, PageHeader, Stat } from "@/components/ui/card";
import { SearchBox } from "@/components/ui/search-box";
import { BUCKETS, type Bucket, type StatusRow, type StatusSummary } from "@/lib/customer-status";
import { errorMessage } from "@/lib/errors";
import { AreaSelect, StatusList } from "./status-report";

const PAGE = 50;

export interface StatusParams { b?: string; q?: string; bolge?: string; s?: string }

/** Müşteri durum raporu (M-21): personel /musteriler/durum, bayi /musterilerim/durum */
export async function CustomerStatusPage({ businessId, base, sp, isAdmin, dealer }: {
  businessId: string; base: string; sp: StatusParams; isAdmin: boolean; dealer: boolean;
}) {
  const supabase = await supabaseServer();
  const bucket: Bucket = BUCKETS.some((x) => x.key === sp.b) ? (sp.b as Bucket) : "ara";
  const page = Math.max(0, Number.parseInt(sp.s ?? "0", 10) || 0);
  const [sum, list] = await Promise.all([
    supabase.rpc("customer_status_summary", { p_business: businessId }),
    supabase.rpc("customer_status_list", {
      p_business: businessId, p_bucket: bucket, p_q: sp.q?.trim() || null, p_area: sp.bolge || null, p_limit: PAGE + 1, p_offset: page * PAGE,
    }),
  ]);
  if (sum.error || list.error) return <Alert>{errorMessage(sum.error ?? list.error)}</Alert>;
  const s = sum.data as StatusSummary;
  const rows = (list.data ?? []) as StatusRow[];
  const more = rows.length > PAGE;
  const href = (p: Partial<StatusParams>) => {
    const q = new URLSearchParams();
    const m = { b: bucket, q: sp.q, bolge: sp.bolge, ...p };
    for (const [k, v] of Object.entries(m)) if (v) q.set(k, String(v));
    return `${base}?${q.toString()}`;
  };
  const count = (k: Bucket) =>
    k === "ara" ? s.call_now : k === "ertelenen" ? s.snoozed : k === "tumu" ? s.total : (s.buckets[k] ?? 0);
  const today = s.callers.reduce((n, c) => n + c.today, 0);
  const todayOrders = s.callers.reduce((n, c) => n + c.today_orders, 0);
  const pct = s.total ? Math.round((s.active30 / s.total) * 100) : 0;

  return (
    <div className="space-y-4">
      <PageHeader
        title="Müşteri durum raporu"
        subtitle="Kimin suyu bitmek üzere, kim uzun süredir almıyor: listeden arayın, sonucu yazın."
        actions={!dealer ? <Link href="/musteriler" className="inline-flex h-11 items-center rounded-xl border border-border bg-surface px-4">Müşteri listesi</Link> : undefined}
      />
      <div className="grid grid-cols-2 gap-2 md:grid-cols-4">
        <Stat label="Toplam müşteri" value={s.total} hint={`${s.buckets.hic ?? 0} hiç almamış`} />
        <Stat label="Aktif (son 30 gün)" value={s.active30} hint={`%${pct} · ${s.new30} yeni`} tone="ok" />
        <Stat label="Bugün aranacak" value={s.call_now} hint={`${s.buckets.sirasi_geldi ?? 0} sırası geldi · ${s.buckets.gecikti ?? 0} gecikti`} tone={s.call_now ? "warn" : undefined} />
        <Stat label="Bugünkü aramalar" value={today} hint={`${todayOrders} sipariş · ${s.snoozed} ertelenen`} />
      </div>

      {s.callers.length ? (
        <Card className="space-y-2">
          <h2 className="font-semibold">Arama tablosu</h2>
          <ul className="divide-y divide-border text-sm">
            {s.callers.map((c, i) => (
              <li key={`${c.name}-${i}`} className="flex items-center justify-between gap-2 py-1.5">
                <span className="font-medium">{i === 0 && c.today > 0 ? "🏆 " : ""}{c.name}</span>
                <span className="num text-muted">
                  Bugün <b className="text-text">{c.today}</b> arama · <b className="text-ok">{c.today_orders}</b> sipariş
                  <span className="hidden sm:inline"> · 7 gün {c.week} / {c.week_orders}</span>
                </span>
              </li>
            ))}
          </ul>
        </Card>
      ) : null}

      <nav className="-mx-3 flex gap-2 overflow-x-auto px-3 pb-1 [scrollbar-width:none]" aria-label="Bölümler">
        {BUCKETS.map((x) => (
          <Link key={x.key} href={href({ b: x.key, s: undefined })}
            className={`shrink-0 rounded-full px-3 py-1.5 text-sm ${bucket === x.key ? "bg-brand text-white" : "bg-surface-2"}`}>
            {x.label} <span className="num opacity-75">{count(x.key)}</span>
          </Link>
        ))}
      </nav>
      <p className="text-sm text-muted">{BUCKETS.find((x) => x.key === bucket)?.hint}</p>
      <div className="grid gap-2 sm:grid-cols-[1fr_220px]">
        <SearchBox placeholder="Ad, kod veya telefon" />
        {s.areas.length > 1 ? <AreaSelect areas={s.areas} value={sp.bolge ?? ""} /> : null}
      </div>

      <StatusList rows={rows.slice(0, PAGE)} isAdmin={isAdmin} dealer={dealer} businessId={businessId} />

      <div className="flex items-center justify-between">
        {page > 0 ? <Link href={href({ s: String(page - 1) })} className="text-brand">← Önceki</Link> : <span />}
        <span className="text-sm text-muted">Sayfa {page + 1}</span>
        {more ? <Link href={href({ s: String(page + 1) })} className="text-brand">Sonraki →</Link> : <span />}
      </div>
    </div>
  );
}
