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
import { PhoneCall } from "lucide-react";

export const metadata = { title: "Müşteriler" };

const PAGE = 100;
type Row = { id: string; code: string; name: string; phone: string | null; credit_limit: number; unlimited_credit: boolean; active: boolean; channel: Channel; price_list: PriceList; regions: string | null; dispenser_count: number; owner_dealer_id: string | null; area: string | null };

export default async function CustomersPage({ searchParams }: { searchParams: Promise<{ q?: string; borclu?: string; kanal?: string; s?: string }> }) {
  const ctx = await requirePermission("customers");
  const sp = await searchParams;
  const supabase = await supabaseServer();
  const page = Math.max(0, Number.parseInt(sp.s ?? "0", 10) || 0);
  // Binlerce müşteri için sunucuda arama + sayfalama (M-22)
  const [{ data: debtors }, { data: dealers }] = await Promise.all([
    supabase.from("customer_balances").select("customer_id, balance").eq("business_id", ctx.businessId).gt("balance", 0),
    supabase.from("customers").select("id, name").eq("business_id", ctx.businessId).eq("channel", "bayi"),
  ]);
  const debt = (debtors ?? []) as { customer_id: string; balance: number }[];
  let query = supabase.from("customers")
    .select("id, code, name, phone, credit_limit, unlimited_credit, active, channel, price_list, regions, dispenser_count, owner_dealer_id, area", { count: "exact" })
    .eq("business_id", ctx.businessId);
  if (sp.q?.trim()) {
    const key = searchKey(sp.q.trim()).replace(/["',()\\*%]/g, "");
    const d = sp.q.replace(/\D/g, "").replace(/^(90|0)/, "");
    query = d.length >= 4 ? query.or(`search_key.like."*${key}*",phone.like.*${d}*`) : query.like("search_key", `%${key}%`);
  }
  if (sp.kanal) query = query.eq("channel", sp.kanal);
  if (sp.borclu) query = query.in("id", debt.length ? debt.map((x) => x.customer_id) : ["00000000-0000-0000-0000-000000000000"]);
  const { data: cs, count } = await query.order("name").range(page * PAGE, page * PAGE + PAGE - 1);
  const list = (cs ?? []) as Row[];
  const ids = list.map((c) => c.id);
  const [{ data: bal }, { data: cont }] = ids.length
    ? await Promise.all([
        supabase.from("customer_balances").select("customer_id, balance").in("customer_id", ids),
        supabase.from("container_balances").select("customer_id, qty").in("customer_id", ids),
      ])
    : [{ data: [] }, { data: [] }];
  const b = new Map((bal ?? []).map((x: { customer_id: string; balance: number }): [string, number] => [x.customer_id, Number(x.balance)]));
  const k = new Map<string, number>();
  for (const c of (cont ?? []) as { customer_id: string | null; qty: number }[]) if (c.customer_id) k.set(c.customer_id, (k.get(c.customer_id) ?? 0) + c.qty);
  const rows = list.map((c) => ({ ...c, balance: b.get(c.id) ?? 0, containers: k.get(c.id) ?? 0 }));
  const dealerNames = new Map(((dealers ?? []) as { id: string; name: string }[]).map((r) => [r.id, r.name]));
  const totalDebt = debt.reduce((s, r) => s + Number(r.balance), 0);
  const total = count ?? rows.length;
  const pageHref = (n: number) => {
    const p = new URLSearchParams();
    for (const [key, v] of Object.entries({ q: sp.q, borclu: sp.borclu, kanal: sp.kanal })) if (v) p.set(key, v);
    if (n) p.set("s", String(n));
    return `/musteriler?${p.toString()}`;
  };

  return (
    <div>
      <PageHeader title="Müşteriler" subtitle={`${total} müşteri${ctx.role === "yonetici" ? ` · alacak ${formatTRY(totalDebt)}` : ""}`}
        actions={
          <span className="flex flex-wrap gap-2">
            <Link href="/musteriler/durum" className="inline-flex h-11 items-center gap-1.5 rounded-xl border border-brand bg-brand-soft px-4 font-medium text-brand"><PhoneCall className="h-4 w-4" /> Durum raporu</Link>
            {ctx.role === "yonetici" ? <Link href="/musteriler/aktar" className="inline-flex h-11 items-center rounded-xl border border-border bg-surface px-4">Abone listesi yükle</Link> : null}
            <Link href={`/musteriler/yeni${sp.kanal ? `?kanal=${sp.kanal}` : ""}`} className="inline-flex h-11 items-center rounded-xl bg-brand px-4 font-medium text-white">Yeni müşteri</Link>
          </span>
        } />
      <div className="no-print -mx-3 mb-3 flex gap-2 overflow-x-auto px-3 [scrollbar-width:none]">
        <Link href="/musteriler" className={`shrink-0 rounded-full px-3 py-1.5 text-sm ${!sp.borclu && !sp.kanal ? "bg-brand text-white" : "bg-surface-2"}`}>Tümü</Link>
        <Link href="/musteriler?borclu=1" className={`shrink-0 rounded-full px-3 py-1.5 text-sm ${sp.borclu ? "bg-brand text-white" : "bg-surface-2"}`}>Borçlular</Link>
        <Link href="/musteriler?kanal=perakende" className={`shrink-0 rounded-full px-3 py-1.5 text-sm ${sp.kanal === "perakende" ? "bg-brand text-white" : "bg-surface-2"}`}>Ev müşterileri</Link>
        <Link href="/musteriler?kanal=bayi" className={`shrink-0 rounded-full px-3 py-1.5 text-sm ${sp.kanal === "bayi" ? "bg-brand text-white" : "bg-surface-2"}`}>Bayiler</Link>
        <Link href="/musteriler?kanal=kurumsal" className={`shrink-0 rounded-full px-3 py-1.5 text-sm ${sp.kanal === "kurumsal" ? "bg-brand text-white" : "bg-surface-2"}`}>Kurumsal</Link>
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
          { key: "area", label: "Bölge", hideOnMobile: true, render: (r) => r.area ?? "—" },
          { key: "bal", label: "Bakiye", align: "right", render: (r) => <span className={r.balance > 0 ? "text-warn" : ""}>{formatTRY(r.balance)}</span> },
          { key: "lim", label: "Limit", align: "right", render: (r) => (r.unlimited_credit ? "Limitsiz" : formatTRY(r.credit_limit)) },
          { key: "k", label: "Kap", align: "right", render: (r) => r.containers || "—" },
          { key: "sb", label: "Sebil", align: "right", hideOnMobile: true, render: (r) => r.dispenser_count || "—" },
        ]}
        empty="Müşteri yok" />
      {total > PAGE ? (
        <div className="mt-3 flex items-center justify-between text-sm">
          {page > 0 ? <Link href={pageHref(page - 1)} className="text-brand">← Önceki</Link> : <span />}
          <span className="text-muted">{page * PAGE + 1}–{Math.min(total, (page + 1) * PAGE)} / {total}</span>
          {(page + 1) * PAGE < total ? <Link href={pageHref(page + 1)} className="text-brand">Sonraki →</Link> : <span />}
        </div>
      ) : null}
    </div>
  );
}
