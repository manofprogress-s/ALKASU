import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/card";
import { OrderForm, type OrderFormValue } from "@/components/orders/order-form";
import { dealerOrderSetup, loadAssignees, loadDealerNames, loadOrderCustomers, loadOrderProducts, type Assignee, type Dealer } from "@/lib/orders";
import { todayISO } from "@/lib/format";
import { SHORT_NOTICE } from "@/lib/kvkk";
import { toShopItems, type CatalogRow, type ShopItem } from "@/lib/shop";
import { CustomerShop } from "@/components/shop/customer-shop";

export const metadata = { title: "Yeni sipariş" };

export default async function NewOrderPage({ searchParams }: { searchParams: Promise<{ musteri?: string }> }) {
  const ctx = await requirePermission("orders");
  const sp = await searchParams;
  const supabase = await supabaseServer();
  const isDealer = ctx.role === "bayi";
  const isCustomer = ctx.role === "musteri";
  const [products, customers, assignees, dealers, catalog] = await Promise.all([
    loadOrderProducts(supabase, ctx.businessId),
    loadOrderCustomers(supabase, ctx.businessId), // RLS: bayi kendisi + kendi müşterileri, müşteri yalnızca kendisi
    isDealer || isCustomer ? Promise.resolve([] as Assignee[]) : loadAssignees(supabase, ctx.businessId),
    isDealer ? loadDealerNames(supabase, ctx.businessId) : Promise.resolve([] as Dealer[]),
    isCustomer ? supabase.rpc("public_catalog").then((r) => toShopItems((r.data ?? []) as CatalogRow[])) : Promise.resolve([] as ShopItem[]),
  ]);
  const dealer = isDealer ? dealerOrderSetup(customers, dealers, ctx.customerId) : null;
  const fixed = isCustomer ? customers.find((c) => c.id === ctx.customerId) ?? null : null;
  const formCustomers = dealer ? dealer.customers : isCustomer ? [] : customers;
  const preset = !isCustomer && sp.musteri ? formCustomers.find((c) => c.id === sp.musteri) ?? null : null;
  const initial: OrderFormValue | null = preset
    ? { id: crypto.randomUUID(), customerId: preset.id, deliveryDate: todayISO(), assignee: preset.defaultAssignee, address: preset.address ?? "", note: "", items: [] }
    : null;
  // Müşteri: mağaza ekranı (W-08). Firmaya özel fiyatı varsa gösterimde o kullanılır; asıl fiyat sunucuda belirlenir.
  if (isCustomer && fixed && catalog.length) {
    const items = catalog.map((i) => ({ ...i, price: fixed.specialPrices[i.unitId] ?? i.price }));
    return <CustomerShop items={items} customerId={fixed.id} address={fixed.address} />;
  }
  return (
    <div>
      <PageHeader title="Yeni sipariş" />
      <OrderForm
        products={products}
        customers={formCustomers}
        assignees={assignees}
        initial={initial}
        fixedCustomer={fixed}
        dealerMode={dealer?.dealerMode}
        isNew
      />
      {isCustomer ? (
        <p className="mt-3 text-xs text-muted">
          {SHORT_NOTICE} <Link href="/kvkk" target="_blank" className="text-brand underline">Müşteri Aydınlatma Metni</Link>
        </p>
      ) : null}
    </div>
  );
}
