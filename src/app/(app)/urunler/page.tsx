import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Badge, PageHeader } from "@/components/ui/card";
import { DataTable } from "@/components/ui/table";
import { formatNumber, formatTRY } from "@/lib/format";
import { can } from "@/lib/roles";
import { SearchBox } from "@/components/ui/search-box";

export const metadata = { title: "Ürünler" };

interface Row {
  id: string; code: string; name: string; active: boolean; is_container: boolean; deposit_amount: number | null; base_unit_name: string;
  brands: { name: string } | null; categories: { name: string } | null;
  product_units: { name: string; factor: number; price: number | null; active: boolean; is_base: boolean }[];
}

export default async function ProductsPage({ searchParams }: { searchParams: Promise<{ q?: string; pasif?: string }> }) {
  const ctx = await requirePermission("catalog");
  const sp = await searchParams;
  const supabase = await supabaseServer();
  let q = supabase
    .from("products")
    .select("id, code, name, active, is_container, deposit_amount, base_unit_name, brands(name), categories(name), product_units(name, factor, price, active, is_base)")
    .eq("business_id", ctx.businessId)
    .order("name");
  if (!sp.pasif) q = q.eq("active", true);
  if (sp.q) q = q.or(`name.ilike.%${sp.q.replace(/[%,()]/g, "")}%,code.ilike.%${sp.q.replace(/[%,()]/g, "")}%`);
  const [{ data }, { data: levels }] = await Promise.all([q, supabase.from("stock_levels").select("product_id, qty").eq("business_id", ctx.businessId)]);
  const stock = new Map((levels ?? []).map((l: { product_id: string; qty: number }): [string, number] => [l.product_id, l.qty]));
  const rows = (data ?? []) as unknown as Row[];
  const admin = can(ctx.role, "productEdit");

  return (
    <div>
      <PageHeader
        title="Ürünler"
        subtitle={`${rows.length} ürün`}
        actions={admin ? (
          <>
            <Link href="/urunler/magaza" className="inline-flex h-11 items-center rounded-xl border border-border bg-surface px-4">Mağaza düzeni</Link>
            <Link href="/urunler/fiyatlar" className="inline-flex h-11 items-center rounded-xl border border-border bg-surface px-4">Fiyat listeleri</Link>
            <Link href="/urunler/ice-aktar" className="inline-flex h-11 items-center rounded-xl border border-border bg-surface px-4">Excel&apos;den aktar</Link>
            <Link href="/urunler/yeni" className="inline-flex h-11 items-center rounded-xl bg-brand px-4 font-medium text-white">Yeni ürün</Link>
          </>
        ) : null}
      />
      <SearchBox placeholder="Ürün adı veya kodu" />
      <DataTable
        rows={rows}
        rowKey={(r) => r.id}
        onRowClick={admin ? (r) => `/urunler/${r.id}` : undefined}
        mobileTitle={(r) => r.name}
        columns={[
          { key: "code", label: "Kod", render: (r) => r.code },
          { key: "name", label: "Ürün", hideOnMobile: true, render: (r) => (
            <span className="flex items-center gap-2">{r.name}{!r.active ? <Badge>Pasif</Badge> : null}{r.is_container ? <Badge tone="brand">Boş kap</Badge> : null}{r.deposit_amount ? <Badge tone="brand">Depozitolu</Badge> : null}</span>
          ) },
          { key: "brand", label: "Marka", render: (r) => r.brands?.name ?? "—" },
          { key: "units", label: "Birim / fiyat", render: (r) => r.product_units.filter((u) => u.active).sort((a, b) => a.factor - b.factor)
              .map((u) => `${u.name}${u.factor > 1 ? ` (${u.factor})` : ""}: ${u.price === null ? "—" : formatTRY(u.price)}`).join(" · ") },
          { key: "stock", label: "Stok", align: "right", render: (r) => {
            const s = stock.get(r.id) ?? 0;
            return <span className={s < 0 ? "text-danger" : ""}>{formatNumber(s)} {r.base_unit_name.toLocaleLowerCase("tr-TR")}</span>;
          } },
        ]}
        empty={admin ? "Henüz ürün yok. Excel şablonuyla toplu aktarabilir veya tek tek ekleyebilirsiniz." : "Ürün yok"}
      />
    </div>
  );
}
