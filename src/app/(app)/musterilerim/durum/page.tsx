import { requirePermission } from "@/lib/session";
import { Alert } from "@/components/ui/card";
import { CustomerStatusPage, type StatusParams } from "@/components/customers/status-page";

export const metadata = { title: "Müşteri durum raporu" };

/** Bayi: yalnızca kendi müşterilerinin durumu (M-26) */
export default async function DealerStatusRoute({ searchParams }: { searchParams: Promise<StatusParams> }) {
  const ctx = await requirePermission("dealerCustomers");
  if (!ctx.customerId) return <Alert>Hesabınız bir bayi kartına bağlı değil. Yöneticinize başvurun.</Alert>;
  return <CustomerStatusPage businessId={ctx.businessId} base="/musterilerim/durum" sp={await searchParams} isAdmin={false} dealer />;
}
