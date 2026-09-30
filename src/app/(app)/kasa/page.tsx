import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Alert, Card, PageHeader, Stat } from "@/components/ui/card";
import { DataTable } from "@/components/ui/table";
import { formatDateTime, formatTRY } from "@/lib/format";
import { CASH_LABELS } from "@/lib/labels";
import { CashActions } from "@/components/cash/cash-actions";

export const metadata = { title: "Kasa" };

interface Summary {
  id?: string; no?: number; status: string; opened_at?: string; opening_cash: number; expected_cash?: number; pos_expected?: number;
  sales_count?: number; sales_total?: number; goods_total?: number; credit_sales?: number; late_sync_count?: number; movements?: Record<string, number>;
}

export default async function CashPage() {
  const ctx = await requirePermission("cash");
  const supabase = await supabaseServer();
  const [{ data: s }, { data: cats }, { data: past }] = await Promise.all([
    supabase.rpc("cash_session_summary", { p_business: ctx.businessId, p_session: null }),
    supabase.from("expense_categories").select("id, name").eq("business_id", ctx.businessId).eq("active", true).order("sort"),
    supabase.from("cash_sessions").select("id, no, opened_at, closed_at, expected_cash, counted_cash, cash_diff, carry_over").eq("business_id", ctx.businessId).eq("status", "kapali").order("closed_at", { ascending: false }).limit(30),
  ]);
  const sum = (s ?? { status: "yok", opening_cash: 0 }) as Summary;
  let movements: { id: number; type: string; amount: number; note: string | null; created_at: string }[] = [];
  if (sum.id) {
    const { data } = await supabase.from("cash_movements").select("id, type, amount, note, created_at").eq("session_id", sum.id).order("id", { ascending: false });
    movements = (data ?? []) as typeof movements;
  }
  return (
    <div className="space-y-4">
      <PageHeader title="Kasa" subtitle={sum.status === "acik" ? `Gün #${sum.no} · açılış ${formatDateTime(sum.opened_at)}` : "Açık kasa günü yok; ilk satış veya kasa hareketi günü açar"} />
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Stat label="Açılış nakdi" value={formatTRY(sum.opening_cash)} />
        <Stat label="Kasada beklenen nakit" value={formatTRY(sum.expected_cash ?? sum.opening_cash)} tone="ok" />
        <Stat label="POS toplamı" value={formatTRY(sum.pos_expected ?? 0)} />
        <Stat label="Günün satışı" value={formatTRY(sum.sales_total ?? 0)} hint={`${sum.sales_count ?? 0} fiş · veresiye ${formatTRY(sum.credit_sales ?? 0)}`} />
      </div>
      {sum.late_sync_count ? <Alert tone="warn">Bu güne {sum.late_sync_count} geç gelen çevrimdışı satış yazıldı.</Alert> : null}
      <CashActions sessionId={sum.id ?? null} expected={Number(sum.expected_cash ?? sum.opening_cash)} posExpected={Number(sum.pos_expected ?? 0)} categories={(cats ?? []) as { id: string; name: string }[]} />
      {sum.id ? (
        <Card>
          <h2 className="mb-2 font-semibold">Günün kasa hareketleri</h2>
          <DataTable rows={movements} rowKey={(r) => String(r.id)} mobileTitle={(r) => CASH_LABELS[r.type] ?? r.type}
            columns={[
              { key: "t", label: "Saat", render: (r) => formatDateTime(r.created_at).slice(11) },
              { key: "ty", label: "Hareket", hideOnMobile: true, render: (r) => CASH_LABELS[r.type] ?? r.type },
              { key: "n", label: "Açıklama", render: (r) => r.note ?? "" },
              { key: "a", label: "Tutar", align: "right", render: (r) => <span className={r.amount < 0 ? "text-danger" : "text-ok"}>{formatTRY(r.amount)}</span> },
            ]} empty="Henüz nakit hareketi yok" />
        </Card>
      ) : null}
      <Card>
        <h2 className="mb-2 font-semibold">Kapanmış günler</h2>
        <DataTable rows={(past ?? []) as { id: string; no: number; closed_at: string; expected_cash: number; counted_cash: number; cash_diff: number; carry_over: number }[]}
          rowKey={(r) => r.id} onRowClick={(r) => `/kasa/${r.id}`} mobileTitle={(r) => `Gün #${r.no}`}
          columns={[
            { key: "c", label: "Kapanış", render: (r) => formatDateTime(r.closed_at) },
            { key: "e", label: "Beklenen", align: "right", render: (r) => formatTRY(r.expected_cash) },
            { key: "s", label: "Sayılan", align: "right", render: (r) => formatTRY(r.counted_cash) },
            { key: "d", label: "Fark", align: "right", render: (r) => <span className={Number(r.cash_diff) !== 0 ? "font-semibold text-danger" : ""}>{formatTRY(r.cash_diff)}</span> },
            { key: "k", label: "Devreden", align: "right", render: (r) => formatTRY(r.carry_over) },
          ]} empty="Henüz kapanmış gün yok" />
        <Link href="/raporlar" className="mt-2 inline-block text-sm text-brand">Raporlar →</Link>
      </Card>
    </div>
  );
}
