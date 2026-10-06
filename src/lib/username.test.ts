import { describe, expect, it } from "vitest";
import { formatPhone, isSyntheticEmail, loginEmail, normalizePhone, normalizeUsername } from "./username";

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
  it("telefon", () => {
    expect(normalizePhone("0532 111 22 33")).toBe("5321112233");
    expect(normalizePhone("+90 (532) 111-22-33")).toBe("5321112233");
    expect(normalizePhone("5321112233")).toBe("5321112233");
    expect(normalizePhone("0262 111 22 33")).toBeNull();
    expect(normalizePhone("12345")).toBeNull();
    expect(loginEmail("0532 111 22 33")).toBe("5321112233@musteri.alkasu.app");
    expect(loginEmail("HTopal")).toBe("htopal@kullanici.alkasu.app");
    expect(formatPhone("5321112233")).toBe("0532 111 22 33");
  });
});
