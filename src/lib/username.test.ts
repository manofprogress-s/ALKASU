import { describe, expect, it } from "vitest";
import { isSyntheticEmail, loginEmail, normalizeUsername } from "./username";

describe("kullanıcı adı", () => {
  it("Türkçe karakterleri sadeleştirir", () => {
    expect(normalizeUsername("İSağlam")).toBe("isaglam");
    expect(normalizeUsername(" HTopal ")).toBe("htopal");
    expect(normalizeUsername("AAlay")).toBe("aalay");
    expect(normalizeUsername("Çağrı Öğüt")).toBe("cagriogut");
  });
  it("e-posta ve kullanıcı adını ayırır", () => {
    expect(loginEmail("Me@Example.com")).toBe("me@example.com");
    expect(loginEmail("İSağlam")).toBe("isaglam@kullanici.alkasu.app");
    expect(isSyntheticEmail("isaglam@kullanici.alkasu.app")).toBe(true);
    expect(isSyntheticEmail("me@example.com")).toBe(false);
  });
});
