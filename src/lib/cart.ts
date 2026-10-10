// Sepet hesapları. Sunucudaki complete_sale ile birebir aynı kuralları uygular (F-05, D-03, S-03);
// son söz her zaman sunucudadır. Tüm hesaplar kuruş cinsinden tam sayıyla yapılır.
import { fromKurus, toKurus } from "./format";

export interface CartLine {
  key: string;
  productId: string;
  productName: string;
  unitId: string;
  unitName: string;
  factor: number;
  qty: number;
  unitPrice: number; // TL, KDV dahil
  lineDiscount: number; // TL
  depositAmount: number | null; // temel birim başına depozito
  emptyProductId: string | null;
}

/** Müşterinin (veya perakende havuzunun) elindeki kaplar: ürün → { qty, amount } */
export type ContainerBalances = Record<string, { qty: number; amount: number }>;

export interface ComputedLine extends CartLine {
  grossK: number;
  discountK: number;
  shareK: number;
  netK: number;
}

export interface DepositLine {
  productId: string;
  productName: string;
  sold: number;
  emptyReturned: number;
  net: number; // + müşteride kalan kap
  amountK: number; // + alınan / − iade edilen
  error?: string;
}

export interface CartTotals {
  lines: ComputedLine[];
  grossK: number;
  discountK: number;
  goodsNetK: number;
  deposits: DepositLine[];
  depositK: number;
  grandK: number;
  errors: string[];
}

export function computeCart(
  lines: CartLine[],
  billDiscount: number,
  emptiesReturned: Record<string, number>,
  balances: ContainerBalances = {},
  /** Müşteri seçili: fazla boş iadesi ürün tutarını aşarsa fark carisine alacak yazılır (D-07) */
  opts: { creditCustomer?: boolean } = {},
): CartTotals {
  const errors: string[] = [];
  const computed: ComputedLine[] = lines.map((l) => {
    const grossK = toKurus(l.qty * l.unitPrice);
    const discountK = toKurus(l.lineDiscount || 0);
    if (discountK < 0 || discountK > grossK) errors.push(`Satır indirimi geçersiz: ${l.productName}`);
    return { ...l, grossK, discountK, shareK: 0, netK: grossK - discountK };
  });

  const grossK = computed.reduce((s, l) => s + l.grossK, 0);
  const lineDiscK = computed.reduce((s, l) => s + l.discountK, 0);
  const beforeBillK = grossK - lineDiscK;
  const billK = toKurus(billDiscount || 0);
  if (billK < 0) errors.push("İndirim negatif olamaz");
  if (billK > 0 && billK > beforeBillK) errors.push("Fiş indirimi tutarı aşıyor");

  if (billK > 0 && beforeBillK > 0) {
    let left = billK;
    computed.forEach((l, i) => {
      if (i === computed.length - 1) {
        l.shareK = left;
      } else {
        // Sunucu: round(bill * net / total, 2) — numeric yarım yukarı
        l.shareK = Math.round((billK * l.netK) / beforeBillK + 1e-9);
        left -= l.shareK;
      }
      l.netK -= l.shareK;
    });
  }
  const goodsNetK = computed.reduce((s, l) => s + l.netK, 0);

  // Depozito (ürün bazında)
  const byProduct = new Map<string, { name: string; sold: number; dep: number }>();
  for (const l of computed) {
    if (l.depositAmount === null) continue;
    const cur = byProduct.get(l.productId) ?? { name: l.productName, sold: 0, dep: l.depositAmount };
    cur.sold += l.qty * l.factor;
    byProduct.set(l.productId, cur);
  }
  const deposits: DepositLine[] = [];
  for (const [productId, d] of byProduct) {
    const returned = emptiesReturned[productId] ?? d.sold;
    const net = d.sold - returned;
    let amountK = 0;
    let error: string | undefined;
    if (net > 0) {
      amountK = net * toKurus(d.dep);
    } else if (net < 0) {
      const bal = balances[productId] ?? { qty: 0, amount: 0 };
      const excess = -net;
      if (bal.qty < excess) {
        error = `Müşterinin elinde ${bal.qty} kap görünüyor; ${excess} fazla boş kabul edilemez`;
        errors.push(error);
      } else if (bal.qty === excess) {
        amountK = -toKurus(bal.amount);
      } else {
        amountK = -Math.round((toKurus(bal.amount) * excess) / bal.qty + 1e-9);
      }
    }
    deposits.push({ productId, productName: d.name, sold: d.sold, emptyReturned: returned, net, amountK, error });
  }
  const depositK = deposits.reduce((s, d) => s + d.amountK, 0);
  const grandK = goodsNetK + depositK;
  if (grandK < 0 && errors.length === 0 && !opts.creditCustomer) {
    errors.push("Boş kap iadesi tutarı aşıyor: müşteri seçin, fark carisine alacak yazılır");
  }

  return { lines: computed, grossK, discountK: lineDiscK + billK, goodsNetK, deposits, depositK, grandK, errors };
}

export type PaymentMethod = "nakit" | "pos" | "veresiye";
export interface Payment {
  method: PaymentMethod;
  amount: number;
}

export function paymentsTotalK(payments: Payment[]): number {
  return payments.reduce((s, p) => s + toKurus(p.amount), 0);
}

/** complete_sale RPC gövdesi */
export function buildSalePayload(args: {
  id: string;
  customerId: string | null;
  cart: CartLine[];
  billDiscount: number;
  emptiesReturned: Record<string, number>;
  payments: Payment[];
  cashGiven: number | null;
  offline: boolean;
  clientCreatedAt: string;
  limitOverride?: boolean;
  note?: string;
}) {
  const depositProducts = new Set(args.cart.filter((l) => l.depositAmount !== null).map((l) => l.productId));
  return {
    id: args.id,
    customer_id: args.customerId,
    client_created_at: args.clientCreatedAt,
    offline: args.offline,
    note: args.note || null,
    items: args.cart.map((l) => ({
      product_id: l.productId,
      unit_id: l.unitId,
      qty: l.qty,
      unit_price: l.unitPrice,
      line_discount: l.lineDiscount || 0,
    })),
    bill_discount: args.billDiscount || 0,
    deposits: [...depositProducts].map((pid) => ({
      product_id: pid,
      empty_returned: args.emptiesReturned[pid] ?? args.cart.filter((l) => l.productId === pid).reduce((s, l) => s + l.qty * l.factor, 0),
    })),
    payments: args.payments.filter((p) => toKurus(p.amount) > 0).map((p) => ({ method: p.method, amount: fromKurus(toKurus(p.amount)) })),
    cash_given: args.cashGiven,
    limit_override: args.limitOverride ?? false,
  };
}
