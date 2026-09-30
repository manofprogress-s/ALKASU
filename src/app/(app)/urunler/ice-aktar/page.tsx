import { requirePermission } from "@/lib/session";
import { PageHeader } from "@/components/ui/card";
import { ImportWizard } from "@/components/products/import-wizard";

export const metadata = { title: "Excel'den aktar" };

export default async function ImportPage() {
  await requirePermission("productEdit");
  return (
    <div className="space-y-4">
      <PageHeader title="Excel'den aktar" subtitle="Ürünler, müşteriler ve müşterideki damacanalar" />
      <ImportWizard />
    </div>
  );
}
