import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Badge, PageHeader } from "@/components/ui/card";
import { DataTable } from "@/components/ui/table";
import { SearchBox } from "@/components/ui/search-box";
import { searchKey } from "@/lib/catalog";

export const metadata = { title: "Tedarikçiler" };

interface Row {
  id: string;
  name: string;
  contact_name: string | null;
  phone: string | null;
  address: string | null;
  latitude: number | null;
  active: boolean;
}

export default async function SuppliersPage({ searchParams }: { searchParams: Promise<{ q?: string }> }) {
  const ctx = await requirePermission("receiveGoods");
  const sp = await searchParams;
  const supabase = await supabaseServer();
  const { data } = await supabase
    .from("suppliers")
    .select("id, name, contact_name, phone, address, latitude, active")
    .eq("business_id", ctx.businessId)
    .order("active", { ascending: false })
    .order("name");
  let rows = (data ?? []) as Row[];
  if (sp.q) {
    const k = searchKey(sp.q);
    rows = rows.filter((r) => searchKey(`${r.name} ${r.contact_name ?? ""} ${r.address ?? ""}`).includes(k));
  }
  return (
    <div>
      <PageHeader
        title="Tedarikçiler"
        subtitle={`${rows.length} tedarikçi`}
        actions={<Link href="/tedarikciler/yeni" className="inline-flex h-11 items-center rounded-xl bg-brand px-4 font-medium text-white">Yeni tedarikçi</Link>}
      />
      <SearchBox placeholder="Ad, yetkili veya adres" />
      <DataTable
        rows={rows}
        rowKey={(r) => r.id}
        onRowClick={(r) => `/tedarikciler/${r.id}`}
        mobileTitle={(r) => r.name}
        columns={[
          { key: "n", label: "Firma", hideOnMobile: true, render: (r) => <span>{r.name} {!r.active ? <Badge>Pasif</Badge> : null}</span> },
          { key: "c", label: "Yetkili", render: (r) => r.contact_name ?? "—" },
          { key: "p", label: "Telefon", render: (r) => r.phone ?? "—" },
          { key: "a", label: "Adres", hideOnMobile: true, render: (r) => <span className="line-clamp-1">{r.address ?? "—"}</span> },
          { key: "l", label: "Konum", render: (r) => (r.latitude !== null ? <Badge tone="ok">Var</Badge> : <span className="text-muted">—</span>) },
        ]}
        empty="Tedarikçi yok"
      />
    </div>
  );
}
