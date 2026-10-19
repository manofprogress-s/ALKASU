import { describe, expect, it } from "vitest";
import { taxIdKind } from "./invoice";

describe("VKN / TCKN doğrulama (F-20)", () => {
  it("VKN", () => {
    expect(taxIdKind("1234567890")).toBe("vkn");
    expect(taxIdKind("123 456 78 90")).toBe("vkn");
    expect(taxIdKind("1234567891")).toBeNull();
    expect(taxIdKind("9876543217")).toBe("vkn");
  });
  it("TCKN", () => {
    expect(taxIdKind("10000000146")).toBe("tckn");
    expect(taxIdKind("10000000147")).toBeNull();
    expect(taxIdKind("01234567890")).toBeNull();
  });
  it("boş / kısa", () => {
    expect(taxIdKind(null)).toBeNull();
    expect(taxIdKind("123")).toBeNull();
  });
});
