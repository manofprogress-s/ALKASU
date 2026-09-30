import { notFound } from "next/navigation";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Card, PageHeader, Stat } from "@/components/ui/card";
import { DataTable } from "@/components/ui/table";
import { formatDateTime, formatTRY } from "@/lib/format";
import { CustomerForm } from "@/components/customers/customer-form";
import { CustomerActions } from "@/components/customers/customer-actions";
import { ExportButton } from "@/components/reports/export-button";

export default async function CustomerPage({ params }: { params: Promise<{ id: string }> }) {
  const ctx = await requirePermission("customers");
  const { id } = await params;
  if (id === "yeni") {
    return (
      <div className="space-y-4">
        <PageHeader title="Yeni müşteri" />
        <CustomerForm initial={null} canSetLimit={ctx.role === "yonetici"} />
      </div>
    );
  }
  const supabase = await supabaseServer();
  const [{ data: c }, { data: sum }, { data: st }, { data: pays }] = await Promise.all([
    supabase.from("customers").select("*").eq("id", id).maybeSingle(),
    supabase.rpc("customer_summary", { p_customer: id }),
    supabase.rpc("customer_statement", { p_customer: id }),
    supabase.from("customer_payments").select("id, method, amount, status, created_at, note").eq("customer_id", id).order("created_at", { ascending: false }).limit(20),
  ]);
  if (!c) notFound();
  const summary = sum as { balance: number; containers: { product_id: string; product_name: string; qty: number; amount: number }[] };
  const statement = ((st ?? []) as { at: string; description: string; debit: number | null; credit: number | null; balance: number }[]).reverse();

  return (
    <div className="space-y-4">
      <PageHeader title={c.name} subtitle={`${c.code}${c.phone ? ` · ${c.phone}` : ""}`} />
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Stat label="Veresiye bakiyesi" value={formatTRY(summary.balance)} tone={summary.balance > 0 ? "warn" : undefined} />
        <Stat label="Limit" value={c.unlimited_credit ? "Limitsiz" : formatTRY(c.credit_limit)} />
        {summary.containers.map((k) => (
          <Stat key={k.product_id} label={`Elindeki kap · ${k.product_name}`} value={k.qty} hint={`Ödenen depozito ${formatTRY(k.amount)}`} />
        ))}
      </div>
      <CustomerActions
        customerId={c.id}
        isAdmin={ctx.role === "yonetici"}
        containers={summary.containers}
        payments={(pays ?? []) as { id: string; method: string; amount: number; status: string; created_at: string }[]}
      />
      <Card>
        <div className="mb-2 flex items-center justify-between">
          <h2 className="font-semibold">Hesap ekstresi</h2>
          <ExportButton filename={`ekstre_${c.code}`} rows={[...statement].reverse().map((s) => ({
            Tarih: formatDateTime(s.at), Açıklama: s.description, Borç: s.debit === null ? null : Number(s.debit), Alacak: s.credit === null ? null : Number(s.credit), Bakiye: Number(s.balance),
          }))} />
        </div>
        <DataTable rows={statement} rowKey={(r) => `${r.at}${r.description}${r.balance}`} mobileTitle={(r) => r.description}
          columns={[
            { key: "t", label: "Tarih", render: (r) => formatDateTime(r.at) },
            { key: "d", label: "Açıklama", hideOnMobile: true, render: (r) => r.description },
            { key: "b", label: "Borç", align: "right", render: (r) => (r.debit ? formatTRY(r.debit) : "") },
            { key: "a", label: "Alacak", align: "right", render: (r) => (r.credit ? formatTRY(r.credit) : "") },
            { key: "s", label: "Bakiye", align: "right", render: (r) => formatTRY(r.balance) },
          ]} empty="Hareket yok" />
      </Card>
      <details className="rounded-2xl border border-border bg-surface p-4">
        <summary className="cursor-pointer font-semibold">Müşteri bilgilerini düzenle</summary>
        <div className="mt-3">
          <CustomerForm canSetLimit={ctx.role === "yonetici"} initial={{
            id: c.id, code: c.code, name: c.name, phone: c.phone, address: c.address, tax_no: c.tax_no, note: c.note,
            credit_limit: Number(c.credit_limit), unlimited_credit: c.unlimited_credit, active: c.active,
          }} />
        </div>
      </details>
    </div>
  );
}
