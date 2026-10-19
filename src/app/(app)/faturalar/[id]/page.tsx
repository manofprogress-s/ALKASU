import Link from "next/link";
import { notFound } from "next/navigation";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Badge, Card, PageHeader } from "@/components/ui/card";
import { formatDateTime } from "@/lib/format";
import { INVOICE_EVENT, INVOICE_STATUS, type InvoiceCustomer, type InvoiceIssue, type InvoiceLine, type InvoiceStatus, type InvoiceTotals } from "@/lib/invoice";
import { InvoiceView } from "@/components/invoices/invoice-view";
import { InvoiceActions } from "@/components/invoices/invoice-actions";

export const metadata = { title: "Fatura" };

export default async function InvoicePage({ params }: { params: Promise<{ id: string }> }) {
  const ctx = await requirePermission("invoices");
  const { id } = await params;
  const supabase = await supabaseServer();
  const [{ data: inv }, { data: events }, { data: users }] = await Promise.all([
    supabase.from("invoices").select("*, sales(id, no, sold_at, status)").eq("id", id).eq("business_id", ctx.businessId).maybeSingle(),
    supabase.from("invoice_events").select("at, user_id, event, detail").eq("invoice_id", id).order("at", { ascending: false }),
    supabase.rpc("assignable_users", { p_business: ctx.businessId }),
  ]);
  if (!inv) notFound();
  const v = inv as {
    id: string; no: number; status: InvoiceStatus; customer: InvoiceCustomer; lines: InvoiceLine[]; totals: InvoiceTotals; issues: InvoiceIssue[];
    note: string | null; logo_invoice_no: string | null; ettn: string | null; last_error: string | null; cancel_reason: string | null;
    created_at: string; sales: { id: string; no: number; sold_at: string; status: string } | null;
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
            {v.sales ? <Link href={`/satislar/${v.sales.id}`} className="text-brand">Satış #{v.sales.no}</Link> : null}
            {v.sales ? <span>· {formatDateTime(v.sales.sold_at)}</span> : null}
            <Badge tone={st.tone}>{st.label}</Badge>
            {v.sales?.status === "iptal" ? <Badge tone="danger">Satış iptal edildi</Badge> : null}
          </span>
        }
      />
      <p className="text-sm text-muted">{st.hint}. F-{v.no} ALKASU'nun iç numarasıdır, resmî fatura numarası değildir.</p>
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
