import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Alert, PageHeader, Stat } from "@/components/ui/card";
import { DataTable } from "@/components/ui/table";
import { DateFilter } from "@/components/ui/date-filter";
import { ExportButton } from "@/components/reports/export-button";
import { formatDate, formatNumber, formatTRY, todayISO } from "@/lib/format";

export const metadata = { title: "Raporlar" };

type Tab = "gunluk" | "urun" | "marka" | "veresiye" | "kap";

export default async function ReportsPage({ searchParams }: { searchParams: Promise<{ tab?: Tab; from?: string; to?: string }> }) {
  const ctx = await requirePermission("reports");
  const sp = await searchParams;
  const isAdmin = ctx.role === "yonetici";
  const tab: Tab = sp.tab ?? "gunluk";
  const to = sp.to ?? todayISO();
  const from = sp.from ?? `${to.slice(0, 8)}01`;
  const supabase = await supabaseServer();
  const tabs: { t: Tab; label: string; admin?: boolean }[] = [
    { t: "gunluk", label: "Günlük satış" },
    { t: "urun", label: "Ürün bazında" },
    { t: "marka", label: "Marka bazında" },
    { t: "veresiye", label: "Veresiye", admin: true },
    { t: "kap", label: "Müşterideki kaplar", admin: true },
  ];
  const q = (t: Tab) => `/raporlar?tab=${t}&from=${from}&to=${to}`;

  let body: React.ReactNode = null;
  if (tab === "gunluk") {
    const { data, error } = await supabase.rpc("report_daily_sales", { p_business: ctx.businessId, p_from: from, p_to: to });
    const rows = (data ?? []) as { day: string; sales_count: number; net_revenue: number; discount: number; returns_total: number; deposit: number; cash: number; pos: number; credit: number; cost: number | null; gross_profit: number | null }[];
    const tot = (k: keyof (typeof rows)[number]) => rows.reduce((s, r) => s + Number(r[k] ?? 0), 0);
    const maxRev = Math.max(1, ...rows.map((r) => Number(r.net_revenue)));
    body = (
      <>
        {error ? <Alert>{error.message}</Alert> : null}
        <div className="mb-4 grid grid-cols-2 gap-3 md:grid-cols-4">
          <Stat label="Net satış" value={formatTRY(tot("net_revenue"))} hint={`${tot("sales_count")} fiş`} />
          {isAdmin ? <Stat label="Brüt kâr" value={formatTRY(tot("gross_profit"))} tone="ok" hint={tot("net_revenue") ? `Marj %${formatNumber((tot("gross_profit") * 100) / tot("net_revenue"))}` : undefined} /> : null}
          <Stat label="Nakit / POS" value={formatTRY(tot("cash"))} hint={`POS ${formatTRY(tot("pos"))}`} />
          <Stat label="Veresiye" value={formatTRY(tot("credit"))} hint={`İade ${formatTRY(tot("returns_total"))}`} />
        </div>
        <div className="mb-2 flex justify-end">
          <ExportButton filename="gunluk_satis" rows={rows.map((r) => ({
            Tarih: formatDate(r.day), Fiş: Number(r.sales_count), "Net satış": Number(r.net_revenue), İndirim: Number(r.discount), İade: Number(r.returns_total),
            Depozito: Number(r.deposit), Nakit: Number(r.cash), POS: Number(r.pos), Veresiye: Number(r.credit),
            ...(isAdmin ? { Maliyet: Number(r.cost), "Brüt kâr": Number(r.gross_profit) } : {}),
          }))} />
        </div>
        <DataTable rows={[...rows].reverse()} rowKey={(r) => r.day} mobileTitle={(r) => formatDate(r.day)}
          columns={[
            { key: "d", label: "Tarih", hideOnMobile: true, render: (r) => formatDate(r.day) },
            { key: "bar", label: "", hideOnMobile: true, className: "w-40", render: (r) => <div className="h-2 rounded bg-brand" style={{ width: `${(Number(r.net_revenue) / maxRev) * 100}%` }} /> },
            { key: "n", label: "Fiş", align: "right", render: (r) => r.sales_count },
            { key: "r", label: "Net satış", align: "right", render: (r) => formatTRY(r.net_revenue) },
            { key: "c", label: "Nakit", align: "right", render: (r) => formatTRY(r.cash) },
            { key: "p", label: "POS", align: "right", render: (r) => formatTRY(r.pos) },
            { key: "v", label: "Veresiye", align: "right", render: (r) => formatTRY(r.credit) },
            ...(isAdmin ? [{ key: "g", label: "Brüt kâr", align: "right" as const, render: (r: (typeof rows)[number]) => formatTRY(r.gross_profit) }] : []),
          ]} />
      </>
    );
  } else if (tab === "urun" || tab === "marka") {
    const { data, error } = await supabase.rpc("report_product_sales", { p_business: ctx.businessId, p_from: from, p_to: to, p_group: tab });
    const rows = (data ?? []) as { key_id: string | null; key_name: string; brand_name: string | null; qty_base: number; revenue: number; cost: number | null; gross_profit: number | null; margin_pct: number | null; missing_cost: boolean | null }[];
    body = (
      <>
        {error ? <Alert>{error.message}</Alert> : null}
        {rows.some((r) => r.missing_cost) ? <Alert tone="warn">Bazı ürünlerin maliyeti tanımlı değil; kârları olduğundan yüksek görünür (M-07).</Alert> : null}
        <div className="my-2 flex justify-end">
          <ExportButton filename={`${tab}_satis`} rows={rows.map((r) => ({
            [tab === "urun" ? "Ürün" : "Marka"]: r.key_name, ...(tab === "urun" ? { Marka: r.brand_name ?? "" } : {}), Miktar: Number(r.qty_base), Ciro: Number(r.revenue),
            ...(isAdmin ? { Maliyet: Number(r.cost), "Brüt kâr": Number(r.gross_profit), "Marj %": Number(r.margin_pct ?? 0) } : {}),
          }))} />
        </div>
        <DataTable rows={rows} rowKey={(r) => r.key_id ?? r.key_name} mobileTitle={(r) => r.key_name}
          columns={[
            { key: "n", label: tab === "urun" ? "Ürün" : "Marka", hideOnMobile: true, render: (r) => r.key_name },
            { key: "q", label: "Miktar (temel birim)", align: "right", render: (r) => formatNumber(r.qty_base) },
            { key: "r", label: "Ciro", align: "right", render: (r) => formatTRY(r.revenue) },
            ...(isAdmin ? [
              { key: "g", label: "Brüt kâr", align: "right" as const, render: (r: (typeof rows)[number]) => formatTRY(r.gross_profit) },
              { key: "m", label: "Marj", align: "right" as const, render: (r: (typeof rows)[number]) => (r.margin_pct === null ? "—" : `%${formatNumber(r.margin_pct)}`) },
            ] : []),
          ]} empty="Bu dönemde satış yok" />
      </>
    );
  } else if (tab === "veresiye" && isAdmin) {
    const { data } = await supabase.rpc("report_receivables", { p_business: ctx.businessId });
    const rows = ((data ?? []) as { customer_id: string; code: string; name: string; phone: string | null; balance: number; d0_30: number; d31_60: number; d61_90: number; d90_plus: number; credit_limit: number; unlimited_credit: boolean }[])
      .sort((a, b) => Number(b.balance) - Number(a.balance));
    const sum = (k: "balance" | "d0_30" | "d31_60" | "d61_90" | "d90_plus") => rows.reduce((s, r) => s + Number(r[k]), 0);
    body = (
      <>
        <div className="mb-4 grid grid-cols-2 gap-3 md:grid-cols-5">
          <Stat label="Toplam alacak" value={formatTRY(sum("balance"))} />
          <Stat label="0–30 gün" value={formatTRY(sum("d0_30"))} />
          <Stat label="31–60 gün" value={formatTRY(sum("d31_60"))} />
          <Stat label="61–90 gün" value={formatTRY(sum("d61_90"))} tone="warn" />
          <Stat label="90+ gün" value={formatTRY(sum("d90_plus"))} tone="danger" />
        </div>
        <div className="mb-2 flex justify-end">
          <ExportButton filename="veresiye" rows={rows.map((r) => ({ Kod: r.code, Müşteri: r.name, Telefon: r.phone ?? "", Bakiye: Number(r.balance), "0-30": Number(r.d0_30), "31-60": Number(r.d31_60), "61-90": Number(r.d61_90), "90+": Number(r.d90_plus) }))} />
        </div>
        <DataTable rows={rows} rowKey={(r) => r.customer_id} onRowClick={(r) => `/musteriler/${r.customer_id}`} mobileTitle={(r) => r.name}
          columns={[
            { key: "n", label: "Müşteri", hideOnMobile: true, render: (r) => r.name },
            { key: "b", label: "Bakiye", align: "right", render: (r) => formatTRY(r.balance) },
            { key: "a", label: "0–30", align: "right", render: (r) => formatTRY(r.d0_30) },
            { key: "b2", label: "31–60", align: "right", render: (r) => formatTRY(r.d31_60) },
            { key: "c", label: "61–90", align: "right", render: (r) => formatTRY(r.d61_90) },
            { key: "d", label: "90+", align: "right", render: (r) => <span className={Number(r.d90_plus) > 0 ? "text-danger" : ""}>{formatTRY(r.d90_plus)}</span> },
          ]} empty="Açık veresiye yok" />
      </>
    );
  } else if (tab === "kap" && isAdmin) {
    const { data } = await supabase.rpc("report_containers", { p_business: ctx.businessId });
    const rows = (data ?? []) as { customer_id: string | null; customer_name: string; product_name: string; qty: number; amount: number }[];
    body = (
      <>
        <div className="mb-4 grid grid-cols-2 gap-3">
          <Stat label="Müşterilerdeki kap" value={formatNumber(rows.reduce((s, r) => s + r.qty, 0))} />
          <Stat label="Alınmış depozito" value={formatTRY(rows.reduce((s, r) => s + Number(r.amount), 0))} hint="Müşteriye borç; gelir değildir" />
        </div>
        <div className="mb-2 flex justify-end">
          <ExportButton filename="musterideki_kaplar" rows={rows.map((r) => ({ Müşteri: r.customer_name, Ürün: r.product_name, Kap: r.qty, Depozito: Number(r.amount) }))} />
        </div>
        <DataTable rows={rows} rowKey={(r) => `${r.customer_id}-${r.product_name}`} onRowClick={(r) => (r.customer_id ? `/musteriler/${r.customer_id}` : undefined)} mobileTitle={(r) => r.customer_name}
          columns={[
            { key: "c", label: "Müşteri", hideOnMobile: true, render: (r) => r.customer_name },
            { key: "p", label: "Ürün", render: (r) => r.product_name },
            { key: "q", label: "Kap", align: "right", render: (r) => r.qty },
            { key: "a", label: "Depozito", align: "right", render: (r) => formatTRY(r.amount) },
          ]} empty="Müşterilerde kap yok" />
      </>
    );
  }

  return (
    <div>
      <PageHeader title="Raporlar" />
      <div className="no-print mb-4 flex flex-wrap gap-2">
        {tabs.filter((t) => !t.admin || isAdmin).map((t) => (
          <Link key={t.t} href={q(t.t)} className={`rounded-full px-3 py-1.5 text-sm ${tab === t.t ? "bg-brand text-white" : "bg-surface-2"}`}>{t.label}</Link>
        ))}
      </div>
      {tab === "gunluk" || tab === "urun" || tab === "marka" ? <DateFilter from={from} to={to} /> : null}
      {body}
    </div>
  );
}
