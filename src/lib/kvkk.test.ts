import { describe, expect, it } from "vitest";
import { CONTROLLER, KVKK_VERSION, missingControllerFields } from "./kvkk";

describe("KVKK metni", () => {
  it("veri sorumlusu bilgileri eksiksiz (yayın öncesi şart)", () => {
    expect(missingControllerFields()).toEqual([]);
  });
  it("sürüm kayıt sınırına uyar", () => {
    expect(KVKK_VERSION.length).toBeGreaterThan(0);
    expect(KVKK_VERSION.length).toBeLessThanOrEqual(40);
  });
  it("e-posta biçimi geçerli", () => {
    expect(CONTROLLER.email).toMatch(/^[^\s@]+@[^\s@]+\.[^\s@]+$/);
  });
});
