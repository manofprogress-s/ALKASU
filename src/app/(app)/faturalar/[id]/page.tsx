import Link from "next/link";
import { notFound } from "next/navigation";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Badge, Card, PageHeader } from "@/components/ui/card";
import { formatDateTime } from "@/lib/format";
import { INVOICE_EVENT, INVOICE_STATUS, type InvoiceCustomer, type InvoiceIssue, type InvoiceLine, type InvoiceSaleRef, type InvoiceStatus, type InvoiceTotals } from "@/lib/invoice";
import { InvoiceView } from "@/components/invoices/invoice-view";
import { InvoiceActions } from "@/components/invoices/invoice-actions";
import { InvoiceSales } from "@/components/invoices/invoice-sales";
import { monthLabel } from "@/lib/profit";

export const metadata = { title: "Fatura" };

export default async function InvoicePage({ params }: { params: Promise<{ id: string }> }) {
  const ctx = await requirePermission("invoices");
  const { id } = await params;
  const supabase = await supabaseServer();
  const [{ data: inv }, { data: events }, { data: users }, { data: links }] = await Promise.all([
    supabase.from("invoices").select("*, sales!invoices_sale_id_fkey(id, no, sold_at, status)").eq("id", id).eq("business_id", ctx.businessId).maybeSingle(),
    supabase.from("invoice_events").select("at, user_id, event, detail").eq("invoice_id", id).order("at", { ascending: false }),
    supabase.rpc("assignable_users", { p_business: ctx.businessId }),
    supabase.from("invoice_sales").select("sale_id, active, sales(id, no, sold_at, status, goods_net)").eq("invoice_id", id),
  ]);
  // F-33: faturadaki teslimatlar ve siparişleri
  type L = { sale_id: string; active: boolean; sales: { id: string; no: number; sold_at: string; status: string; goods_net: number } | null };
  const lk = (links ?? []) as unknown as L[];
  const saleIds = lk.map((l) => l.sale_id);
  const [{ data: ords }, { data: its }] = saleIds.length
    ? await Promise.all([
        supabase.from("orders").select("id, no, sale_id").in("sale_id", saleIds),
        supabase.from("sale_items").select("sale_id, qty").in("sale_id", saleIds),
      ])
    : [{ data: [] }, { data: [] }];
  const ordBy = new Map(((ords ?? []) as { id: string; no: number; sale_id: string }[]).map((o) => [o.sale_id, o]));
  const qtyBy = new Map<string, number>();
  for (const i of (its ?? []) as { sale_id: string; qty: number }[]) qtyBy.set(i.sale_id, (qtyBy.get(i.sale_id) ?? 0) + Number(i.qty));
  const deliveries: InvoiceSaleRef[] = lk.filter((l) => l.sales).map((l) => ({
    id: l.sales!.id, no: l.sales!.no, sold_at: l.sales!.sold_at, status: l.sales!.status,
    order_id: ordBy.get(l.sale_id)?.id ?? null, order_no: ordBy.get(l.sale_id)?.no ?? null,
    qty: qtyBy.get(l.sale_id) ?? 0, gross: Number(l.sales!.goods_net), invoiced_by: null,
  })).sort((a, b) => a.sold_at.localeCompare(b.sold_at));
  if (!inv) notFound();
  const v = inv as {
    id: string; no: number; status: InvoiceStatus; customer: InvoiceCustomer; lines: InvoiceLine[]; totals: InvoiceTotals; issues: InvoiceIssue[];
    note: string | null; logo_invoice_no: string | null; ettn: string | null; last_error: string | null; cancel_reason: string | null;
    created_at: string; sales: { id: string; no: number; sold_at: string; status: string } | null;
    kind: "teslimat" | "aylik"; period_start: string | null;
  };
  const st = INVOICE_STATUS[v.status];
  const names = new Map(((users ?? []) as { user_id: string; display_name: string }[]).map((u) => [u.user_id, u.display_name]));
  const errors = v.issues.filter((i) => i.level === "error").length;
  return (
    <div className="space-y-4">
      <PageHeader
        title={`Fatura kaydı F-${v.no}`}
        subtitle={
          <span className="flex flex-wrap items-center gap-2">
            {v.kind === "aylik" ? <Badge tone="brand">Aylık toplu{v.period_start ? ` · ${monthLabel(v.period_start.slice(0, 7))}` : ""} · {deliveries.length} teslimat</Badge> : null}
            {v.sales ? <Link href={`/satislar/${v.sales.id}`} className="text-brand">Satış #{v.sales.no}</Link> : null}
            {v.sales ? <span>· {formatDateTime(v.sales.sold_at)}</span> : null}
            <Badge tone={st.tone}>{st.label}</Badge>
            {v.sales?.status === "iptal" ? <Badge tone="danger">Satış iptal edildi</Badge> : null}
          </span>
        }
      />
      <p className="text-sm text-muted">{st.hint}. F-{v.no} ALKASU’nun iç numarasıdır, resmî fatura numarası değildir.</p>
      {v.status === "iptal" && v.cancel_reason ? <Card className="bg-surface-2 text-sm">İptal nedeni: {v.cancel_reason}</Card> : null}
      {v.last_error ? <Card className="bg-danger-soft text-sm text-danger">Son hata: {v.last_error}</Card> : null}
      {v.logo_invoice_no || v.ettn ? (
        <Card className="text-sm">
          {v.logo_invoice_no ? <div>Fatura no: <b>{v.logo_invoice_no}</b></div> : null}
          {v.ettn ? <div className="text-muted">ETTN: {v.ettn}</div> : null}
        </Card>
      ) : null}

      <InvoiceActions invoiceId={v.id} status={v.status} errors={errors} />

      <Card>
        <InvoiceView customer={v.customer} lines={v.lines} totals={v.totals} issues={v.status === "iptal" ? [] : v.issues} />
        {v.note ? <p className="mt-3 text-sm text-muted">Not: {v.note}</p> : null}
      </Card>

      {deliveries.length ? (
        <Card>
          <InvoiceSales sales={deliveries} title={v.status === "iptal" ? "Bu kayıttaki teslimatlar (iptal edildi, yeniden faturalanabilir)" : "Faturadaki teslimatlar"} />
          <p className="mt-2 text-xs text-muted">Tutarlar teslimat tutarıdır (depozito hariç); fatura satırlarında iadeler düşülmüştür.</p>
        </Card>
      ) : null}

      <Card>
        <h2 className="mb-2 font-semibold">Geçmiş</h2>
        <ul className="divide-y divide-border text-sm">
          {((events ?? []) as { at: string; user_id: string | null; event: string; detail: { note?: string } | null }[]).map((e, k) => (
            <li key={k} className="py-1.5">
              <span className="font-medium">{INVOICE_EVENT[e.event] ?? e.event}</span>
              <span className="text-muted"> · {(e.user_id && names.get(e.user_id)) || "Sistem"} · {formatDateTime(e.at)}</span>
              {e.detail?.note ? <div className="text-muted">“{e.detail.note}”</div> : null}
            </li>
          ))}
        </ul>
      </Card>
    </div>
  );
}
