import Link from "next/link";
import { PlugZap } from "lucide-react";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Alert, Badge, PageHeader } from "@/components/ui/card";
import { DataTable } from "@/components/ui/table";
import { formatDateTime, formatTRY, todayISO } from "@/lib/format";
import { monthLabel, parseMonth } from "@/lib/profit";
import { MonthlyBilling, type MonthlyData } from "@/components/invoices/monthly-billing";
import { errorMessage } from "@/lib/errors";
import { BILLING_MODE, INVOICE_STATUS, TAX_KIND_LABEL, type BillingMode, type InvoiceStatus } from "@/lib/invoice";

export const metadata = { title: "Faturalar" };

const TABS: { key: string; label: string }[] = [
  { key: "bekleyen", label: "Faturalanacak teslimatlar" },
  { key: "aylik", label: "Aylık toplu" },
  { key: "taslak", label: "Taslak" },
  { key: "hazir", label: "Gönderime hazır" },
  { key: "logo", label: "Logo’da / resmî" },
  { key: "hatali", label: "Hatalı" },
  { key: "iptal", label: "İptal" },
];
const PAGE = 50;

/** Faturalar (F-21…F-26). Logo İşbaşı bağlantısı yok: hiçbir veri dışarı gönderilmez. */
export default async function InvoicesPage({ searchParams }: { searchParams: Promise<{ d?: string; tum?: string; s?: string; ay?: string }> }) {
  const ctx = await requirePermission("invoices");
  const sp = await searchParams;
  const tab = TABS.some((t) => t.key === sp.d) ? sp.d! : "bekleyen";
  const page = Math.max(0, Number.parseInt(sp.s ?? "0", 10) || 0);
  const supabase = await supabaseServer();
  const thisMonth = todayISO().slice(0, 7);
  const ay = parseMonth(sp.ay, todayISO()) > thisMonth ? thisMonth : parseMonth(sp.ay, todayISO());

  const [{ data: counts }, uninv, inv, monthly] = await Promise.all([
    supabase.from("invoices").select("status").eq("business_id", ctx.businessId),
    tab === "bekleyen"
      ? supabase.rpc("uninvoiced_sales", { p_business: ctx.businessId, p_only_customer: !sp.tum, p_limit: PAGE, p_offset: page * PAGE })
      : Promise.resolve({ data: null, error: null }),
    tab !== "bekleyen" && tab !== "aylik"
      ? supabase.from("invoices")
          .select("id, no, status, customer, totals, issues, created_at, sale_id, kind, period_start, logo_invoice_no, sales!invoices_sale_id_fkey(no, sold_at), invoice_sales(count)", { count: "exact" })
          .eq("business_id", ctx.businessId)
          .in("status", tab === "logo" ? ["gonderiliyor", "gonderildi", "resmilesti"] : [tab])
          .order("created_at", { ascending: false })
          .range(page * PAGE, page * PAGE + PAGE - 1)
      : Promise.resolve({ data: null, error: null, count: 0 }),
    tab === "aylik" ? supabase.rpc("monthly_billing", { p_business: ctx.businessId, p_month: `${ay}-01` }) : Promise.resolve({ data: null, error: null }),
  ]);
  const err = uninv.error ?? inv.error ?? monthly.error;
  const n = (k: string) => (counts ?? []).filter((r: { status: string }) => (k === "logo" ? ["gonderiliyor", "gonderildi", "resmilesti"].includes(r.status) : r.status === k)).length;
  type U = { id: string; no: number; sold_at: string; customer_name: string | null; channel: string | null; tax_kind: "vkn" | "tckn" | null; grand_total: number;
    billing_mode: BillingMode | null; order_no: number | null; qty: number; total_count: number };
  type I = { id: string; no: number; status: InvoiceStatus; kind: "teslimat" | "aylik"; period_start: string | null; customer: { name: string; legal_title?: string }; totals: { gross: number };
    issues: { level: string }[]; created_at: string; logo_invoice_no: string | null; sales: { no: number; sold_at: string } | null; invoice_sales: { count: number }[] };
  const urows = (uninv.data ?? []) as U[];
  const irows = (inv.data ?? []) as unknown as I[];
  const total = tab === "aylik" ? 0 : tab === "bekleyen" ? Number(urows[0]?.total_count ?? 0) : ((inv as { count?: number | null }).count ?? 0);
  const href = (p: Record<string, string | undefined>) => {
    const q = new URLSearchParams();
    for (const [k, v] of Object.entries({ d: tab, tum: sp.tum, ay: tab === "aylik" ? ay : undefined, ...p })) if (v) q.set(k, v);
    return `/faturalar?${q.toString()}`;
  };

  return (
    <div className="space-y-4">
      <PageHeader title="Faturalar" subtitle="Satıştan fatura hazırlayın, eksikleri tamamlayın; Logo İşbaşı bağlantısı kurulunca buradan gönderilecek." />
      <Alert tone="neutral">
        <span className="flex items-start gap-2">
          <PlugZap className="mt-0.5 h-4 w-4 shrink-0" />
          <span>Logo İşbaşı bağlantısı <b>henüz kurulmadı</b>. Bu ekran faturayı hazırlar ve kontrol eder; hiçbir veri dışarı gönderilmez, resmî fatura kesilmez.</span>
        </span>
      </Alert>
      <nav className="-mx-3 flex gap-2 overflow-x-auto px-3 pb-1 [scrollbar-width:none]">
        {TABS.map((t) => (
          <Link key={t.key} href={href({ d: t.key, s: undefined })}
            className={`shrink-0 rounded-full px-3 py-1.5 text-sm ${tab === t.key ? "bg-brand text-white" : "bg-surface-2"}`}>
            {t.label}{t.key !== "bekleyen" && t.key !== "aylik" ? <span className="num opacity-75"> {n(t.key)}</span> : null}
          </Link>
        ))}
      </nav>
      {err ? <Alert>{errorMessage(err)}</Alert> : null}

      {tab === "aylik" ? (
        monthly.data ? <MonthlyBilling data={monthly.data as MonthlyData} month={ay} thisMonth={thisMonth} /> : null
      ) : tab === "bekleyen" ? (
        <>
          <div className="flex items-center justify-between gap-2 text-sm">
            <span className="text-muted">{total} teslimat / satış · fatura kaydı olmayan. “Aylık” müşterilerinkini <Link href={href({ d: "aylik", s: undefined })} className="text-brand">Aylık toplu</Link>’da birleştirin.</span>
            <Link href={href({ tum: sp.tum ? undefined : "1", s: undefined })} className="text-brand">
              {sp.tum ? "Yalnızca müşterili satışlar" : "Perakende (müşterisiz) satışları da göster"}
            </Link>
          </div>
          <DataTable rows={urows} rowKey={(r) => r.id} onRowClick={(r) => `/satislar/${r.id}`} mobileTitle={(r) => `#${r.no} · ${r.customer_name ?? "Perakende"}`}
            columns={[
              { key: "no", label: "Satış", render: (r) => `#${r.no}` },
              { key: "t", label: "Tarih", render: (r) => formatDateTime(r.sold_at) },
              { key: "c", label: "Müşteri", hideOnMobile: true, render: (r) => r.customer_name ?? "Perakende" },
              { key: "o", label: "Sipariş", hideOnMobile: true, render: (r) => (r.order_no ? `#${r.order_no}` : <span className="text-muted">Dükkân</span>) },
              { key: "m", label: "Yöntem", render: (r) => (r.billing_mode && r.customer_name ? <Badge tone={r.billing_mode === "aylik" ? "brand" : "neutral"}>{BILLING_MODE[r.billing_mode].label}</Badge> : null) },
              { key: "k", label: "Vergi no", render: (r) => (r.customer_name === null ? <span className="text-muted">Nihai tüketici</span> : r.tax_kind ? <Badge tone="ok">{TAX_KIND_LABEL[r.tax_kind]}</Badge> : <Badge tone={r.channel === "kurumsal" ? "danger" : "warn"}>Yok</Badge>) },
              { key: "g", label: "Tutar", align: "right", render: (r) => formatTRY(Number(r.grand_total)) },
            ]}
            empty="Faturalanacak satış yok" />
        </>
      ) : (
        <DataTable rows={irows} rowKey={(r) => r.id} onRowClick={(r) => `/faturalar/${r.id}`} mobileTitle={(r) => `F-${r.no} · ${r.customer.legal_title ?? r.customer.name}`}
          columns={[
            { key: "no", label: "Kayıt", render: (r) => `F-${r.no}` },
            { key: "s", label: "Teslimat", render: (r) => (r.kind === "aylik"
              ? <span>Aylık · {r.period_start ? monthLabel(r.period_start.slice(0, 7)) : ""} · {r.invoice_sales[0]?.count ?? 0} teslimat</span>
              : r.sales ? `#${r.sales.no} · ${formatDateTime(r.sales.sold_at)}` : "—") },
            { key: "c", label: "Alıcı", hideOnMobile: true, render: (r) => r.customer.legal_title ?? r.customer.name },
            { key: "st", label: "Durum", render: (r) => (
              <span className="flex flex-wrap gap-1">
                <Badge tone={INVOICE_STATUS[r.status].tone}>{INVOICE_STATUS[r.status].label}</Badge>
                {r.status === "taslak" && r.issues.some((i) => i.level === "error") ? <Badge tone="danger">Eksik var</Badge> : null}
                {r.logo_invoice_no ? <Badge tone="ok">{r.logo_invoice_no}</Badge> : null}
              </span>
            ) },
            { key: "g", label: "Tutar", align: "right", render: (r) => formatTRY(Number(r.totals.gross)) },
          ]}
          empty="Kayıt yok" />
      )}
      {total > PAGE ? (
        <div className="flex items-center justify-between text-sm">
          {page > 0 ? <Link href={href({ s: String(page - 1) })} className="text-brand">← Önceki</Link> : <span />}
          <span className="text-muted">Sayfa {page + 1}</span>
          {(page + 1) * PAGE < total ? <Link href={href({ s: String(page + 1) })} className="text-brand">Sonraki →</Link> : <span />}
        </div>
      ) : null}
    </div>
  );
}
