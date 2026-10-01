import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Alert, Card, PageHeader, Stat } from "@/components/ui/card";
import { DataTable } from "@/components/ui/table";
import { formatDateTime, formatTRY } from "@/lib/format";
import { ExportButton } from "@/components/reports/export-button";

export const metadata = { title: "Hesabım" };

/** Bayi: kendi cari hesabı, kap bakiyesi ve ekstresi (R-07) */
export default async function MyAccountPage() {
  const ctx = await requirePermission("myAccount");
  if (!ctx.customerId) return <Alert>Hesabınız bir müşteri kartına bağlı değil. Lütfen yöneticinize başvurun.</Alert>;
  const supabase = await supabaseServer();
  const [{ data: sum, error }, { data: st }, { data: sales }] = await Promise.all([
    supabase.rpc("customer_summary", { p_customer: ctx.customerId }),
    supabase.rpc("customer_statement", { p_customer: ctx.customerId }),
    supabase.from("sales").select("id, no, sold_at, grand_total, status").eq("customer_id", ctx.customerId).order("sold_at", { ascending: false }).limit(30),
  ]);
  if (error) return <Alert>{error.message}</Alert>;
  const summary = sum as { name: string; code: string; balance: number; credit_limit: number; unlimited_credit: boolean; containers: { product_id: string; product_name: string; qty: number; amount: number }[] };
  const statement = ((st ?? []) as { at: string; description: string; debit: number | null; credit: number | null; balance: number }[]).reverse();

  return (
    <div className="space-y-4">
      <PageHeader title="Hesabım" subtitle={`${summary.name} · ${summary.code}`} actions={<Link href="/siparisler/yeni" className="inline-flex h-11 items-center rounded-xl bg-brand px-4 font-medium text-white">Yeni sipariş</Link>} />
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Stat label="Cari bakiye (borç)" value={formatTRY(summary.balance)} tone={summary.balance > 0 ? "warn" : undefined} />
        <Stat label="Limit" value={summary.unlimited_credit ? "Limitsiz" : formatTRY(summary.credit_limit)} />
        {summary.containers.map((k) => (
          <Stat key={k.product_id} label={`Bendeki kap · ${k.product_name}`} value={k.qty} hint={`Depozito ${formatTRY(k.amount)}`} />
        ))}
      </div>
      <Card>
        <div className="mb-2 flex items-center justify-between">
          <h2 className="font-semibold">Hesap ekstresi</h2>
          <ExportButton filename={`ekstre_${summary.code}`} rows={[...statement].reverse().map((s) => ({
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
      <Card>
        <h2 className="mb-2 font-semibold">Son alımlarım</h2>
        <DataTable rows={(sales ?? []) as { id: string; no: number; sold_at: string; grand_total: number; status: string }[]} rowKey={(r) => r.id} mobileTitle={(r) => `Fiş #${r.no}`}
          columns={[
            { key: "n", label: "Fiş", hideOnMobile: true, render: (r) => `#${r.no}` },
            { key: "t", label: "Tarih", render: (r) => formatDateTime(r.sold_at) },
            { key: "g", label: "Tutar", align: "right", render: (r) => formatTRY(r.grand_total) },
            { key: "s", label: "Durum", render: (r) => (r.status === "tamamlandi" ? "Tamamlandı" : "İptal") },
          ]} empty="Alım yok" />
      </Card>
    </div>
  );
}
