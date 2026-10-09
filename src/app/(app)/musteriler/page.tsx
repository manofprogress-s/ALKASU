import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/card";
import { DataTable } from "@/components/ui/table";
import { formatTRY } from "@/lib/format";
import { SearchBox } from "@/components/ui/search-box";
import { searchKey } from "@/lib/catalog";
import { Badge } from "@/components/ui/card";
import { CHANNELS, PRICE_LISTS, type Channel, type PriceList } from "@/lib/roles";

export const metadata = { title: "Müşteriler" };

export default async function CustomersPage({ searchParams }: { searchParams: Promise<{ q?: string; borclu?: string; kanal?: string }> }) {
  const ctx = await requirePermission("customers");
  const sp = await searchParams;
  const supabase = await supabaseServer();
  const [{ data: cs }, { data: bal }, { data: cont }] = await Promise.all([
    supabase.from("customers").select("id, code, name, phone, credit_limit, unlimited_credit, active, channel, price_list, regions, dispenser_count, owner_dealer_id").eq("business_id", ctx.businessId).order("name"),
    supabase.from("customer_balances").select("customer_id, balance").eq("business_id", ctx.businessId),
    supabase.from("container_balances").select("customer_id, qty").eq("business_id", ctx.businessId),
  ]);
  const b = new Map((bal ?? []).map((x: { customer_id: string; balance: number }): [string, number] => [x.customer_id, Number(x.balance)]));
  const k = new Map<string, number>();
  for (const c of (cont ?? []) as { customer_id: string | null; qty: number }[]) if (c.customer_id) k.set(c.customer_id, (k.get(c.customer_id) ?? 0) + c.qty);
  let rows = ((cs ?? []) as { id: string; code: string; name: string; phone: string | null; credit_limit: number; unlimited_credit: boolean; active: boolean; channel: Channel; price_list: PriceList; regions: string | null; dispenser_count: number; owner_dealer_id: string | null }[])
    .map((c) => ({ ...c, balance: b.get(c.id) ?? 0, containers: k.get(c.id) ?? 0 }));
  if (sp.q) { const s = searchKey(sp.q); const d = sp.q.replace(/\D/g, ""); rows = rows.filter((r) => searchKey(`${r.name} ${r.code}`).includes(s) || (d.length >= 3 && (r.phone ?? "").replace(/\D/g, "").includes(d))); }
  const dealerNames = new Map(rows.filter((r) => r.channel === "bayi").map((r) => [r.id, r.name]));
  if (sp.borclu) rows = rows.filter((r) => r.balance > 0);
  if (sp.kanal) rows = rows.filter((r) => r.channel === sp.kanal);
  const totalDebt = rows.reduce((s, r) => s + Math.max(r.balance, 0), 0);

  return (
    <div>
      <PageHeader title="Müşteriler" subtitle={`${rows.length} müşteri · alacak ${formatTRY(totalDebt)}`}
        actions={<Link href={`/musteriler/yeni${sp.kanal ? `?kanal=${sp.kanal}` : ""}`} className="inline-flex h-11 items-center rounded-xl bg-brand px-4 font-medium text-white">Yeni müşteri</Link>} />
      <div className="no-print mb-3 flex gap-2">
        <Link href="/musteriler" className={`rounded-full px-3 py-1.5 text-sm ${!sp.borclu && !sp.kanal ? "bg-brand text-white" : "bg-surface-2"}`}>Tümü</Link>
        <Link href="/musteriler?borclu=1" className={`rounded-full px-3 py-1.5 text-sm ${sp.borclu ? "bg-brand text-white" : "bg-surface-2"}`}>Borçlular</Link>
        <Link href="/musteriler?kanal=perakende" className={`rounded-full px-3 py-1.5 text-sm ${sp.kanal === "perakende" ? "bg-brand text-white" : "bg-surface-2"}`}>Ev müşterileri</Link>
        <Link href="/musteriler?kanal=bayi" className={`rounded-full px-3 py-1.5 text-sm ${sp.kanal === "bayi" ? "bg-brand text-white" : "bg-surface-2"}`}>Bayiler</Link>
        <Link href="/musteriler?kanal=kurumsal" className={`rounded-full px-3 py-1.5 text-sm ${sp.kanal === "kurumsal" ? "bg-brand text-white" : "bg-surface-2"}`}>Kurumsal</Link>
      </div>
      <SearchBox placeholder="Ad, kod veya telefon" />
      <DataTable rows={rows} rowKey={(r) => r.id} onRowClick={(r) => `/musteriler/${r.id}`} mobileTitle={(r) => r.name}
        columns={[
          { key: "code", label: "Kod", render: (r) => r.code },
          { key: "name", label: "Müşteri", hideOnMobile: true, render: (r) => r.name },
          { key: "ch", label: "Kanal", render: (r) => (
            <span className="flex flex-wrap gap-1">
              {r.channel !== "perakende" ? <Badge tone={r.channel === "bayi" ? "brand" : "neutral"}>{CHANNELS[r.channel]}</Badge> : <span className="text-muted">Perakende</span>}
              {r.price_list !== "perakende" ? <Badge tone="ok">{PRICE_LISTS[r.price_list]}</Badge> : null}
              {r.owner_dealer_id ? <Badge tone="brand">{dealerNames.get(r.owner_dealer_id) ?? "Bayi"} müşterisi</Badge> : null}
            </span>
          ) },
          { key: "phone", label: "Telefon", render: (r) => r.phone ?? "—" },
          { key: "bal", label: "Bakiye", align: "right", render: (r) => <span className={r.balance > 0 ? "text-warn" : ""}>{formatTRY(r.balance)}</span> },
          { key: "lim", label: "Limit", align: "right", render: (r) => (r.unlimited_credit ? "Limitsiz" : formatTRY(r.credit_limit)) },
          { key: "k", label: "Kap", align: "right", render: (r) => r.containers || "—" },
          { key: "sb", label: "Sebil", align: "right", hideOnMobile: true, render: (r) => r.dispenser_count || "—" },
        ]}
        empty="Müşteri yok" />
    </div>
  );
}
