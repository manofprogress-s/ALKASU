import { requirePermission } from "@/lib/session";
import { CustomerStatusPage, type StatusParams } from "@/components/customers/status-page";

export const metadata = { title: "Müşteri durum raporu" };

export default async function CustomerStatusRoute({ searchParams }: { searchParams: Promise<StatusParams> }) {
  const ctx = await requirePermission("customers");
  return <CustomerStatusPage businessId={ctx.businessId} base="/musteriler/durum" sp={await searchParams} isAdmin={ctx.role === "yonetici"} dealer={false} />;
}
