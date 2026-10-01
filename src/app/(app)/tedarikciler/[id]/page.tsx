import Link from "next/link";
import { notFound } from "next/navigation";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/card";
import { SupplierForm } from "@/components/suppliers/supplier-form";
import { toLatLng } from "@/lib/geo";

export default async function SupplierPage({ params }: { params: Promise<{ id: string }> }) {
  const ctx = await requirePermission("receiveGoods");
  const { id } = await params;
  if (id === "yeni") {
    return (
      <div className="space-y-4">
        <PageHeader title="Yeni tedarikçi" />
        <SupplierForm initial={null} />
      </div>
    );
  }
  const supabase = await supabaseServer();
  const { data: s } = await supabase.from("suppliers").select("*").eq("id", id).eq("business_id", ctx.businessId).maybeSingle();
  if (!s) notFound();
  return (
    <div className="space-y-4">
      <PageHeader
        title={s.name}
        subtitle={s.contact_name ?? undefined}
        actions={<Link href="/mal-kabul/yeni" className="inline-flex h-11 items-center rounded-xl border border-border bg-surface px-4">Mal kabul</Link>}
      />
      <SupplierForm
        initial={{
          id: s.id, name: s.name, contact_name: s.contact_name, phone: s.phone, tax_no: s.tax_no, address: s.address,
          note: s.note, active: s.active, location: toLatLng(s.latitude, s.longitude),
        }}
      />
    </div>
  );
}
