import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { loadPosData } from "@/lib/catalog";
import { Pos } from "@/components/pos/pos";

export const metadata = { title: "Satış" };

export default async function SalePage() {
  const ctx = await requirePermission("sell");
  const supabase = await supabaseServer();
  const data = await loadPosData(supabase, ctx.businessId);
  return <Pos initial={data} />;
}
