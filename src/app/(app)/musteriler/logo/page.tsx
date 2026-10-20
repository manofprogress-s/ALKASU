import { redirect } from "next/navigation";
import { requirePermission } from "@/lib/session";
import { PageHeader } from "@/components/ui/card";
import { LogoFirms } from "@/components/customers/logo-firms";

export const metadata = { title: "İşbaşı müşteri eşleştirme" };

export default async function LogoFirmsRoute() {
  const ctx = await requirePermission("customers");
  if (ctx.role !== "yonetici") redirect("/musteriler");
  return (
    <div className="space-y-4">
      <PageHeader
        title="İşbaşı müşteri eşleştirme"
        subtitle="Logo İşbaşı’ndaki carileri ALKASU kartlarına bağlar: fatura gönderilirken İşbaşı’nda aynı müşteri ikinci kez açılmaz, boş fatura bilgileri dolar. Logo’ya hiçbir şey gönderilmez."
      />
      <LogoFirms />
    </div>
  );
}
