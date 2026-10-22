import Link from "next/link";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Alert, Card, PageHeader, Stat } from "@/components/ui/card";
import { DataTable } from "@/components/ui/table";
import { ExportButton } from "@/components/reports/export-button";
import { ProfitChart, type ProfitBar } from "@/components/reports/profit-chart";
import { formatDate, formatTRY, todayISO } from "@/lib/format";
import { addMonths, chartBars, monthBounds, monthLabel, marginPct, normalizePeriod, parseMonth, sumPeriods, weekLabel, type ProfitPeriod } from "@/lib/profit";

export const metadata = { title: "Gelir-gider" };

export default async function ProfitPage({ searchParams }: { searchParams: Promise<{ ay?: string; son?: string }> }) {
  const ctx = await requirePermission("profit");
  const sp = await searchParams;
  const today = todayISO();
  const thisMonth = today.slice(0, 7);
  const minM = (a: string, b: string) => (a < b ? a : b);
  const ay = minM(parseMonth(sp.ay, today), thisMonth);
  // 12 aylık pencere: seçili ayı içerir, bu aydan ileri gitmez
  let son = minM(parseMonth(sp.son, thisMonth), thisMonth);
  if (ay > son) son = ay;
  if (ay < addMonths(son, -11)) son = minM(addMonths(ay, 11), thisMonth);
  const first = addMonths(son, -11);
  const supabase = await supabaseServer();
  await supabase.rpc("post_due_recurring", { p_business: ctx.businessId });   // K-16: düzenli giderler zamanı gelince
  const mb = monthBounds(ay);
  const [{ data: md, error: e1 }, { data: wd, error: e2 }] = await Promise.all([
    supabase.rpc("profit_report", { p_business: ctx.businessId, p_from: `${first}-01`, p_to: monthBounds(son).to, p_grain: "ay" }),
    supabase.rpc("profit_report", { p_business: ctx.businessId, p_from: mb.from, p_to: mb.to, p_grain: "hafta" }),
  ]);
  type Raw = { periods?: Record<string, unknown>[]; pending_purchases?: number; history_until?: string | null } | null;
  const months = ((md as Raw)?.periods ?? []).map(normalizePeriod);
  const weeks = ((wd as Raw)?.periods ?? []).map(normalizePeriod);
  const pending = Number((wd as Raw)?.pending_purchases ?? 0);
  const historyUntil = (md as Raw)?.history_until ?? null;
  const pct = (g: number, i: number) => { const m = marginPct(g, i); return m === null ? "—" : `%${m.toLocaleString("tr-TR")}`; };
  const cur = sumPeriods(weeks);
  const year = sumPeriods(months);
  const href = (m: string, s = son) => `/raporlar/gelir-gider?ay=${m}&son=${s}`;

  const monthBars: ProfitBar[] = months.map((p) => ({
    key: p.start, label: monthLabel(p.start.slice(0, 7), true), href: href(p.start.slice(0, 7)), active: p.start.slice(0, 7) === ay,
    ...chartBars(p), net: p.net_profit,
  }));
  const weekBars: ProfitBar[] = weeks.map((p) => ({ key: p.start, label: weekLabel(p.start, p.end), ...chartBars(p), net: p.net_profit }));

  const tableCols = (kind: "ay" | "hafta") => [
    { key: "p", label: kind === "ay" ? "Ay" : "Hafta", render: (p: ProfitPeriod) => (kind === "ay" ? monthLabel(p.start.slice(0, 7)) : weekLabel(p.start, p.end)) },
    { key: "i", label: "Gelir", align: "right" as const, render: (p: ProfitPeriod) => formatTRY(p.income) },
    { key: "f", label: "Faturalı / bekleyen", align: "right" as const, hideOnMobile: true, render: (p: ProfitPeriod) => (
      <span><span className="text-ok">{formatTRY(p.income_invoiced)}</span> / <span className="text-warn">{formatTRY(p.income_uninvoiced)}</span></span>
    ) },
    { key: "m", label: "Mal alımı", align: "right" as const, render: (p: ProfitPeriod) => formatTRY(p.purchases) },
    { key: "b", label: "Brüt kâr", align: "right" as const, render: (p: ProfitPeriod) => <span className={p.gross_profit < 0 ? "text-danger" : ""}>{formatTRY(p.gross_profit)}</span> },
    { key: "bm", label: "Brüt marj", align: "right" as const, render: (p: ProfitPeriod) => (
      <span className="tabular-nums">
        {pct(p.gross_profit, p.income)}
        {p.income > 0 && p.purchases === 0 ? <span className="block text-[10px] text-warn">alış kaydı yok</span> : null}
      </span>
    ) },
    { key: "g", label: "Giderler", align: "right" as const, render: (p: ProfitPeriod) => formatTRY(p.expenses) },
    { key: "n", label: "Net kâr", align: "right" as const, render: (p: ProfitPeriod) => <span className={`font-semibold ${p.net_profit < 0 ? "text-danger" : "text-ok"}`}>{formatTRY(p.net_profit)}</span> },
    { key: "nm", label: "Net marj", align: "right" as const, hideOnMobile: true, render: (p: ProfitPeriod) => <span className="tabular-nums">{pct(p.net_profit, p.income)}</span> },
  ];
  const exportRows = (ps: ProfitPeriod[], kind: "ay" | "hafta") => ps.map((p) => ({
    Dönem: kind === "ay" ? monthLabel(p.start.slice(0, 7)) : `${p.start} – ${p.end}`,
    "Gelir (faturalı)": p.income_invoiced, "Gelir (fatura bekleyen)": p.income_uninvoiced, İade: p.returns, Gelir: p.income,
    "Mal alımı": p.purchases, "Brüt kâr": p.gross_profit, Giderler: p.expenses, "Net kâr": p.net_profit,
    ...Object.fromEntries(Object.entries(p.expense_categories).map(([k, v]) => [`Gider: ${k}`, v])),
  }));

  const navBtn = "inline-flex h-9 w-9 items-center justify-center rounded-xl border border-border bg-surface";
  return (
    <div className="space-y-4">
      <PageHeader title="Gelir-gider" subtitle="Aylık ve haftalık gelir, gider, brüt ve net kâr"
        actions={<Link href={`/giderler?ay=${ay}`} className="inline-flex h-11 items-center rounded-xl border border-border bg-surface px-4">Giderler</Link>} />
      <div className="no-print -mx-3 flex gap-2 overflow-x-auto px-3">
        <Link href="/raporlar" className="shrink-0 rounded-full bg-surface-2 px-3 py-1.5 text-sm">Satış raporları</Link>
        <span className="shrink-0 rounded-full bg-brand px-3 py-1.5 text-sm text-white">Gelir-gider</span>
      </div>
      {e1 || e2 ? <Alert>{(e1 ?? e2)?.message}</Alert> : null}

      <div className="flex items-center gap-2">
        <Link href={href(addMonths(ay, -1))} className={navBtn} aria-label="Önceki ay"><ChevronLeft className="h-4 w-4" /></Link>
        <span className="min-w-28 text-center text-lg font-semibold">{monthLabel(ay)}</span>
        {ay < thisMonth ? (
          <Link href={href(addMonths(ay, 1))} className={navBtn} aria-label="Sonraki ay"><ChevronRight className="h-4 w-4" /></Link>
        ) : null}
        {ay !== thisMonth ? <Link href="/raporlar/gelir-gider" className="text-sm text-brand">Bu ay</Link> : null}
      </div>
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Stat label="Gelir" value={formatTRY(cur.income)}
          hint={<><span className="text-ok">Faturalı {formatTRY(cur.income_invoiced)}</span> · <span className="text-warn">bekleyen {formatTRY(cur.income_uninvoiced)}</span></>} />
        <Stat label="Gider" value={formatTRY(cur.total_cost)} hint={`Mal alımı ${formatTRY(cur.purchases)} · diğer ${formatTRY(cur.expenses)}`} />
        <Stat label="Brüt kâr" value={formatTRY(cur.gross_profit)} tone={cur.gross_profit < 0 ? "danger" : undefined} hint={`Marj ${pct(cur.gross_profit, cur.income)} · gelir − mal alımı`} />
        <Stat label="Net kâr" value={formatTRY(cur.net_profit)} tone={cur.net_profit < 0 ? "danger" : "ok"} hint={`Marj ${pct(cur.net_profit, cur.income)} · brüt − giderler`} />
      </div>
      {pending ? <Alert tone="warn">Bu ay onay bekleyen {pending} mal kabul var; fiyatı onaylanınca mal alımına eklenir.</Alert> : null}

      <Card>
        <div className="mb-2 flex items-center justify-between gap-2">
          <h2 className="font-semibold">{monthLabel(ay)} · haftalık</h2>
          <ExportButton filename={`gelir_gider_${ay}_haftalik`} rows={exportRows(weeks, "hafta")} />
        </div>
        <ProfitChart bars={weekBars} height={160} />
        <div className="mt-3">
          <DataTable rows={weeks} rowKey={(p) => p.start} mobileTitle={(p) => weekLabel(p.start, p.end)} columns={tableCols("hafta")} />
        </div>
      </Card>

      <div className="grid gap-4 md:grid-cols-2">
        <Card>
          <h2 className="mb-2 font-semibold">{monthLabel(ay)} giderleri</h2>
          <ul className="divide-y divide-border text-sm">
            <li className="flex justify-between py-1.5"><span>Mal alımı (mal kabul)</span><span className="tabular-nums">{formatTRY(cur.purchases)}</span></li>
            {Object.entries(cur.expense_categories).sort((a, b) => b[1] - a[1]).map(([k, v]) => (
              <li key={k} className="flex justify-between py-1.5"><span>{k}</span><span className="tabular-nums">{formatTRY(v)}</span></li>
            ))}
            <li className="flex justify-between py-1.5 font-semibold"><span>Toplam</span><span className="tabular-nums text-danger">{formatTRY(cur.total_cost)}</span></li>
          </ul>
        </Card>
        <Card className="text-sm">
          <h2 className="mb-2 font-semibold">Nasıl hesaplanır?</h2>
          <ul className="list-disc space-y-1 pl-4 text-muted">
            <li><b className="text-text">Gelir</b>: tamamlanan satış ve teslimatların ürün tutarı; depozito dahil değil, iadeler düşülür.</li>
            <li><span className="font-medium text-ok">Yeşil</span>: faturası kesilmiş, <span className="font-medium text-warn">turuncu</span>: fatura bekleyen satış.</li>
            <li><b className="text-text">Mal alımı</b>: mal kabulde onaylanan alış fiyatı × miktar (belge tarihinde).</li>
            <li><b className="text-text">Brüt kâr</b> = gelir − mal alımı · <b className="text-text">Net kâr</b> = brüt kâr − giderler.</li>
            <li>Tutarlar KDV dahildir. Stok yapılan ayda mal alımı yüksek, kâr düşük görünür{cur.history_income === 0 ? <>; satılan malın maliyetine göre bu ayın brüt kârı: <b className="text-text">{formatTRY(cur.income - cur.cogs)}</b></> : null}.</li>
            {historyUntil ? (
              <li><b className="text-text">Geçmiş dönem</b>: {formatDate(historyUntil)} tarihine kadar Logo İşbaşı satış ve alış faturaları (iptaller hariç, iadeler düşülmüş) kullanılır; faturasız satışlar bu dönemde görünmez.</li>
            ) : null}
          </ul>
        </Card>
      </div>

      <Card>
        <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
          <div className="flex items-center gap-2">
            <Link href={href(addMonths(ay, -12), addMonths(son, -12))} className={navBtn} aria-label="Önceki 12 ay"><ChevronLeft className="h-4 w-4" /></Link>
            <h2 className="font-semibold">{monthLabel(first)} – {monthLabel(son)}</h2>
            {son < thisMonth ? (
              <Link href={href(minM(addMonths(ay, 12), thisMonth), minM(addMonths(son, 12), thisMonth))} className={navBtn} aria-label="Sonraki 12 ay"><ChevronRight className="h-4 w-4" /></Link>
            ) : null}
          </div>
          <ExportButton filename={`gelir_gider_aylik_${son}`} rows={exportRows(months, "ay")} />
        </div>
        <ProfitChart bars={monthBars} />
        <p className="mt-1 text-[11px] text-muted">Bir aya dokunarak haftalık ayrıntısını açın.</p>
        <div className="mt-3 grid grid-cols-2 gap-3 md:grid-cols-4">
          <Stat label="12 ay gelir" value={formatTRY(year.income)} />
          <Stat label="12 ay gider" value={formatTRY(year.total_cost)} />
          <Stat label="12 ay brüt kâr" value={formatTRY(year.gross_profit)} hint={`Marj ${pct(year.gross_profit, year.income)}`} />
          <Stat label="12 ay net kâr" value={formatTRY(year.net_profit)} tone={year.net_profit < 0 ? "danger" : "ok"} hint={`Marj ${pct(year.net_profit, year.income)}`} />
        </div>
      </Card>

      <DataTable rows={[...months].reverse().filter((p) => p.income || p.total_cost || p.start.slice(0, 7) === ay)} rowKey={(p) => p.start}
        onRowClick={(p) => href(p.start.slice(0, 7))} mobileTitle={(p) => monthLabel(p.start.slice(0, 7))} columns={tableCols("ay")} empty="Bu dönemde kayıt yok" />
    </div>
  );
}
