import { redirect } from "next/navigation";
import { requirePermission } from "@/lib/session";
import { PageHeader } from "@/components/ui/card";
import { SubscriberImport } from "@/components/customers/subscriber-import";

export const metadata = { title: "Abone listesi yükle" };

export default async function SubscriberImportRoute() {
  const ctx = await requirePermission("customers");
  if (ctx.role !== "yonetici") redirect("/musteriler");
  return (
    <div className="space-y-4">
      <PageHeader title="Abone listesi yükle" subtitle="Eski sistemden alınan abone listesi (Excel). Aynı liste tekrar yüklenirse kayıtlar abone numarasıyla güncellenir, çift kayıt açılmaz." />
      <SubscriberImport />
    </div>
  );
}
