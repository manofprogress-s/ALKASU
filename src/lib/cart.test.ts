import { describe, expect, it } from "vitest";
import { buildSalePayload, computeCart, type CartLine } from "./cart";

const line = (over: Partial<CartLine>): CartLine => ({
  key: Math.random().toString(),
  productId: "su",
  productName: "Su",
  unitId: "koli",
  unitName: "Koli",
  factor: 24,
  qty: 1,
  unitPrice: 200,
  lineDiscount: 0,
  depositAmount: null,
  emptyProductId: null,
  ...over,
});

describe("computeCart", () => {
  it("fiş indirimini sunucuyla aynı şekilde dağıtır (F-05)", () => {
    const t = computeCart(
      [line({ unitPrice: 200 }), line({ unitName: "Paket", factor: 6, unitPrice: 55 }), line({ unitName: "Şişe", factor: 1, unitPrice: 10 })],
      10,
      {},
    );
    expect(t.lines[0]!.shareK).toBe(755); // 10 × 200/265 = 7,55 (veritabanı testiyle aynı)
    expect(t.lines.reduce((s, l) => s + l.shareK, 0)).toBe(1000);
    expect(t.goodsNetK).toBe(25500);
    expect(t.discountK).toBe(1000);
  });

  it("eksik boş için depozito alır (D-03)", () => {
    const t = computeCart(
      [line({ productId: "dm", productName: "Damacana", unitName: "Damacana", factor: 1, qty: 3, unitPrice: 120, depositAmount: 250, emptyProductId: "bk" })],
      0,
      { dm: 1 },
    );
    expect(t.depositK).toBe(50000);
    expect(t.grandK).toBe(36000 + 50000);
    expect(t.deposits[0]!.net).toBe(2);
  });

  it("boş bilgisi girilmezse satılan kadar boş getirildi sayılır", () => {
    const t = computeCart([line({ productId: "dm", factor: 1, qty: 2, unitPrice: 120, depositAmount: 250 })], 0, {});
    expect(t.depositK).toBe(0);
  });

  it("fazla boşta ödenmiş ortalama depozitoyu iade eder", () => {
    const t = computeCart(
      [line({ productId: "dm", factor: 1, qty: 3, unitPrice: 120, depositAmount: 250 })],
      0,
      { dm: 4 },
      { dm: { qty: 2, amount: 500 } },
    );
    expect(t.depositK).toBe(-25000);
    expect(t.grandK).toBe(11000);
    expect(t.errors).toHaveLength(0);
  });

  it("elinde kap yoksa fazla boş kabul edilmez", () => {
    const t = computeCart([line({ productId: "dm", factor: 1, qty: 1, unitPrice: 120, depositAmount: 250 })], 0, { dm: 2 });
    expect(t.errors.length).toBeGreaterThan(0);
  });

  it("müşteri 1 boşla gelip 2 dolu alır: 1 depozito satılır (80 × 2 + 220)", () => {
    const t = computeCart([line({ productId: "dm", factor: 1, qty: 2, unitPrice: 80, depositAmount: 220 })], 0, { dm: 1 });
    expect(t.depositK).toBe(22000);
    expect(t.grandK).toBe(38000);
  });

  it("bayi 20 boş bırakıp 30 dolu alır: 10 depozito", () => {
    const t = computeCart([line({ productId: "dm", factor: 1, qty: 30, unitPrice: 60, depositAmount: 220 })], 0, { dm: 20 });
    expect(t.deposits[0]!.net).toBe(10);
    expect(t.grandK).toBe(180000 + 220000);
  });

  it("bayi 30 boş getirip 20 dolu alır: fark carisine alacak (müşteri seçiliyse)", () => {
    const cart = [line({ productId: "dm", factor: 1, qty: 20, unitPrice: 60, depositAmount: 220 })];
    const bal = { dm: { qty: 10, amount: 2200 } };
    const withCustomer = computeCart(cart, 0, { dm: 30 }, bal, { creditCustomer: true });
    expect(withCustomer.grandK).toBe(120000 - 220000);
    expect(withCustomer.errors).toHaveLength(0);
    expect(computeCart(cart, 0, { dm: 30 }, bal).errors[0]).toMatch(/müşteri seçin/);
  });

  it("indirim satır tutarını aşamaz", () => {
    expect(computeCart([line({ lineDiscount: 201 })], 0, {}).errors.length).toBe(1);
    expect(computeCart([line({})], 300, {}).errors).toContain("Fiş indirimi tutarı aşıyor");
  });
});

describe("buildSalePayload", () => {
  it("sıfır tutarlı ödemeleri atar, depozito satırlarını üretir", () => {
    const p = buildSalePayload({
      id: "x",
      customerId: null,
      cart: [line({ productId: "dm", factor: 1, qty: 2, depositAmount: 250 })],
      billDiscount: 0,
      emptiesReturned: {},
      payments: [{ method: "nakit", amount: 400 }, { method: "pos", amount: 0 }],
      cashGiven: 500,
      offline: false,
      clientCreatedAt: "2026-09-30T10:00:00Z",
    });
    expect(p.payments).toEqual([{ method: "nakit", amount: 400 }]);
    expect(p.deposits).toEqual([{ product_id: "dm", empty_returned: 2 }]);
  });
});
