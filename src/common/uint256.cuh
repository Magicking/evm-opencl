// 256-bit unsigned integer arithmetic for the EVM, usable on host and device.
// Limbs are little-endian: w[0] is the least significant 64 bits.
#pragma once

#include "defs.cuh"

namespace fevm {

struct u256 {
  uint64_t w[4];

  FEVM_HD static u256 zero() { return u256{{0, 0, 0, 0}}; }
  FEVM_HD static u256 from_u64(uint64_t v) { return u256{{v, 0, 0, 0}}; }
  FEVM_HD static u256 max() { return u256{{~0ull, ~0ull, ~0ull, ~0ull}}; }

  FEVM_HD bool is_zero() const { return (w[0] | w[1] | w[2] | w[3]) == 0; }
  FEVM_HD bool fits_u64() const { return (w[1] | w[2] | w[3]) == 0; }
  FEVM_HD bool is_neg() const { return (int64_t)w[3] < 0; }

  // Big-endian 32-byte encoding.
  FEVM_HD static u256 from_be(const uint8_t* p) {
    u256 r;
    r.w[3] = load_be64(p);
    r.w[2] = load_be64(p + 8);
    r.w[1] = load_be64(p + 16);
    r.w[0] = load_be64(p + 24);
    return r;
  }
  // Big-endian with fewer than 32 bytes (right-aligned value).
  FEVM_HD static u256 from_be_partial(const uint8_t* p, size_t n) {
    u256 r = zero();
    for (size_t i = 0; i < n; i++) {
      size_t bit = (n - 1 - i) * 8;
      r.w[bit / 64] |= (uint64_t)p[i] << (bit % 64);
    }
    return r;
  }
  FEVM_HD void to_be(uint8_t* p) const {
    store_be64(p, w[3]);
    store_be64(p + 8, w[2]);
    store_be64(p + 16, w[1]);
    store_be64(p + 24, w[0]);
  }
  FEVM_HD unsigned bit_len() const {
    for (int i = 3; i >= 0; i--)
      if (w[i]) return (unsigned)(i * 64 + 64 - clz64(w[i]));
    return 0;
  }
  FEVM_HD unsigned byte_len() const { return (bit_len() + 7) / 8; }
};

FEVM_HD bool operator==(const u256& a, const u256& b) {
  return ((a.w[0] ^ b.w[0]) | (a.w[1] ^ b.w[1]) | (a.w[2] ^ b.w[2]) | (a.w[3] ^ b.w[3])) == 0;
}
FEVM_HD bool operator!=(const u256& a, const u256& b) { return !(a == b); }

FEVM_HD bool lt(const u256& a, const u256& b) {
  for (int i = 3; i >= 0; i--)
    if (a.w[i] != b.w[i]) return a.w[i] < b.w[i];
  return false;
}
FEVM_HD bool slt(const u256& a, const u256& b) {
  bool an = a.is_neg(), bn = b.is_neg();
  if (an != bn) return an;
  return lt(a, b);
}

FEVM_HD u256 add(const u256& a, const u256& b, bool* carry_out = nullptr) {
  u256 r;
  uint64_t c = 0;
  for (int i = 0; i < 4; i++) {
    u128 s = (u128)a.w[i] + b.w[i] + c;
    r.w[i] = (uint64_t)s;
    c = (uint64_t)(s >> 64);
  }
  if (carry_out) *carry_out = c != 0;
  return r;
}

FEVM_HD u256 sub(const u256& a, const u256& b, bool* borrow_out = nullptr) {
  u256 r;
  uint64_t br = 0;
  for (int i = 0; i < 4; i++) {
    uint64_t t = a.w[i] - b.w[i];
    uint64_t b1 = a.w[i] < b.w[i];
    r.w[i] = t - br;
    uint64_t b2 = t < br;
    br = b1 | b2;
  }
  if (borrow_out) *borrow_out = br != 0;
  return r;
}

FEVM_HD u256 neg(const u256& a) { return sub(u256::zero(), a); }

FEVM_HD u256 mul(const u256& a, const u256& b) {
#if FEVM_ON_DEVICE
  // 32-bit limbs: mul.wide.u32 is a native instruction, 64-bit mul.hi is not.
  uint32_t x[8], y[8], r32[8];
  for (int i = 0; i < 4; i++) {
    x[2 * i] = (uint32_t)a.w[i];
    x[2 * i + 1] = (uint32_t)(a.w[i] >> 32);
    y[2 * i] = (uint32_t)b.w[i];
    y[2 * i + 1] = (uint32_t)(b.w[i] >> 32);
    r32[2 * i] = r32[2 * i + 1] = 0;
  }
#pragma unroll
  for (int i = 0; i < 8; i++) {
    uint64_t carry = 0;
#pragma unroll
    for (int j = 0; i + j < 8; j++) {
      uint64_t t = (uint64_t)x[i] * y[j] + r32[i + j] + carry;
      r32[i + j] = (uint32_t)t;
      carry = t >> 32;
    }
  }
  u256 out;
  for (int i = 0; i < 4; i++) out.w[i] = (uint64_t)r32[2 * i] | ((uint64_t)r32[2 * i + 1] << 32);
  return out;
#else
  u256 r = u256::zero();
  for (int i = 0; i < 4; i++) {
    uint64_t carry = 0;
    for (int j = 0; i + j < 4; j++) {
      u128 p = (u128)a.w[i] * b.w[j] + r.w[i + j] + carry;
      r.w[i + j] = (uint64_t)p;
      carry = (uint64_t)(p >> 64);
    }
  }
  return r;
#endif
}

// Full 256x256 -> 512 multiplication. out has 8 limbs.
FEVM_HD void mul_full(const u256& a, const u256& b, uint64_t* out) {
  for (int i = 0; i < 8; i++) out[i] = 0;
  for (int i = 0; i < 4; i++) {
    uint64_t carry = 0;
    for (int j = 0; j < 4; j++) {
      u128 p = (u128)a.w[i] * b.w[j] + out[i + j] + carry;
      out[i + j] = (uint64_t)p;
      carry = (uint64_t)(p >> 64);
    }
    out[i + 4] = carry;
  }
}

FEVM_HD u256 bit_and(const u256& a, const u256& b) {
  return u256{{a.w[0] & b.w[0], a.w[1] & b.w[1], a.w[2] & b.w[2], a.w[3] & b.w[3]}};
}
FEVM_HD u256 bit_or(const u256& a, const u256& b) {
  return u256{{a.w[0] | b.w[0], a.w[1] | b.w[1], a.w[2] | b.w[2], a.w[3] | b.w[3]}};
}
FEVM_HD u256 bit_xor(const u256& a, const u256& b) {
  return u256{{a.w[0] ^ b.w[0], a.w[1] ^ b.w[1], a.w[2] ^ b.w[2], a.w[3] ^ b.w[3]}};
}
FEVM_HD u256 bit_not(const u256& a) { return u256{{~a.w[0], ~a.w[1], ~a.w[2], ~a.w[3]}}; }

FEVM_HD u256 shl(const u256& a, unsigned s) {
  if (s >= 256) return u256::zero();
  u256 r = u256::zero();
  unsigned limb = s / 64, bits = s % 64;
  for (int i = 3; i >= (int)limb; i--) {
    uint64_t v = a.w[i - limb] << bits;
    if (bits && i - (int)limb - 1 >= 0) v |= a.w[i - limb - 1] >> (64 - bits);
    r.w[i] = v;
  }
  return r;
}

FEVM_HD u256 shr(const u256& a, unsigned s) {
  if (s >= 256) return u256::zero();
  u256 r = u256::zero();
  unsigned limb = s / 64, bits = s % 64;
  for (int i = 0; i + (int)limb < 4; i++) {
    uint64_t v = a.w[i + limb] >> bits;
    if (bits && i + limb + 1 < 4) v |= a.w[i + limb + 1] << (64 - bits);
    r.w[i] = v;
  }
  return r;
}

FEVM_HD u256 sar(const u256& a, unsigned s) {
  if (!a.is_neg()) return shr(a, s);
  if (s >= 256) return u256::max();
  return bit_not(shr(bit_not(a), s));
}

// Knuth algorithm D. u has m limbs, v has n limbs (v[n-1] != 0), m >= n.
// q receives m-n+1 limbs, r receives n limbs. m <= 8, n <= 4.
FEVM_HDN void divmod_limbs(const uint64_t* u, int m, const uint64_t* v, int n, uint64_t* q, uint64_t* r) {
  if (n == 1) {
    u128 rem = 0;
    for (int i = m - 1; i >= 0; i--) {
      u128 cur = (rem << 64) | u[i];
      q[i] = (uint64_t)(cur / v[0]);
      rem = cur % v[0];
    }
    r[0] = (uint64_t)rem;
    return;
  }
  int s = clz64(v[n - 1]);
  uint64_t vn[4];
  uint64_t un[9];
  for (int i = n - 1; i > 0; i--) vn[i] = (v[i] << s) | (s ? v[i - 1] >> (64 - s) : 0);
  vn[0] = v[0] << s;
  un[m] = s ? u[m - 1] >> (64 - s) : 0;
  for (int i = m - 1; i > 0; i--) un[i] = (u[i] << s) | (s ? u[i - 1] >> (64 - s) : 0);
  un[0] = u[0] << s;

  for (int j = m - n; j >= 0; j--) {
    u128 num = ((u128)un[j + n] << 64) | un[j + n - 1];
    u128 qhat = num / vn[n - 1];
    u128 rhat = num % vn[n - 1];
    while (qhat >> 64 || qhat * vn[n - 2] > ((rhat << 64) | un[j + n - 2])) {
      qhat--;
      rhat += vn[n - 1];
      if (rhat >> 64) break;
    }
    // Multiply and subtract.
    uint64_t borrow = 0, carry = 0;
    for (int i = 0; i < n; i++) {
      u128 p = qhat * vn[i] + carry;
      carry = (uint64_t)(p >> 64);
      uint64_t pl = (uint64_t)p;
      uint64_t t = un[i + j] - pl;
      uint64_t b1 = un[i + j] < pl;
      uint64_t t2 = t - borrow;
      uint64_t b2 = t < borrow;
      un[i + j] = t2;
      borrow = b1 + b2;
    }
    uint64_t t = un[j + n] - carry;
    uint64_t b1 = un[j + n] < carry;
    uint64_t t2 = t - borrow;
    uint64_t b2 = t < borrow;
    un[j + n] = t2;
    if (b1 | b2) {
      // Add back.
      qhat--;
      uint64_t c = 0;
      for (int i = 0; i < n; i++) {
        u128 s2 = (u128)un[i + j] + vn[i] + c;
        un[i + j] = (uint64_t)s2;
        c = (uint64_t)(s2 >> 64);
      }
      un[j + n] += c;
    }
    q[j] = (uint64_t)qhat;
  }
  for (int i = 0; i < n - 1; i++) r[i] = (un[i] >> s) | (s ? un[i + 1] << (64 - s) : 0);
  r[n - 1] = un[n - 1] >> s;
}

FEVM_HD int limb_count(const uint64_t* x, int max) {
  int n = max;
  while (n > 0 && x[n - 1] == 0) n--;
  return n;
}

// a / b and a % b; b != 0 required.
FEVM_HD void udivmod(const u256& a, const u256& b, u256* q, u256* r) {
  int n = limb_count(b.w, 4);
  int m = limb_count(a.w, 4);
  u256 qq = u256::zero(), rr = u256::zero();
  if (m < n || lt(a, b)) {
    rr = a;
  } else {
    divmod_limbs(a.w, m, b.w, n, qq.w, rr.w);
  }
  if (q) *q = qq;
  if (r) *r = rr;
}

FEVM_HD u256 udiv(const u256& a, const u256& b) {
  if (b.is_zero()) return u256::zero();
  if (a.fits_u64() && b.fits_u64()) return u256::from_u64(a.w[0] / b.w[0]);
  u256 q;
  udivmod(a, b, &q, nullptr);
  return q;
}

FEVM_HD u256 umod(const u256& a, const u256& b) {
  if (b.is_zero()) return u256::zero();
  if (a.fits_u64() && b.fits_u64()) return u256::from_u64(a.w[0] % b.w[0]);
  u256 r;
  udivmod(a, b, nullptr, &r);
  return r;
}

FEVM_HD u256 sdiv(const u256& a, const u256& b) {
  if (b.is_zero()) return u256::zero();
  bool an = a.is_neg(), bn = b.is_neg();
  u256 q = udiv(an ? neg(a) : a, bn ? neg(b) : b);
  return (an != bn) ? neg(q) : q;
}

FEVM_HD u256 smod(const u256& a, const u256& b) {
  if (b.is_zero()) return u256::zero();
  bool an = a.is_neg(), bn = b.is_neg();
  u256 r = umod(an ? neg(a) : a, bn ? neg(b) : b);
  return an ? neg(r) : r;
}

FEVM_HD u256 addmod(const u256& a, const u256& b, const u256& m) {
  if (m.is_zero()) return u256::zero();
  bool carry;
  u256 s = add(a, b, &carry);
  if (!carry) return umod(s, m);
  uint64_t u[5] = {s.w[0], s.w[1], s.w[2], s.w[3], 1};
  int n = limb_count(m.w, 4);
  uint64_t q[5];
  u256 r = u256::zero();
  divmod_limbs(u, 5, m.w, n, q, r.w);
  return r;
}

FEVM_HD u256 mulmod(const u256& a, const u256& b, const u256& m) {
  if (m.is_zero()) return u256::zero();
  uint64_t p[8];
  mul_full(a, b, p);
  int pm = limb_count(p, 8);
  int n = limb_count(m.w, 4);
  u256 r = u256::zero();
  if (pm < n) {
    for (int i = 0; i < pm; i++) r.w[i] = p[i];
    return r;
  }
  uint64_t q[8];
  divmod_limbs(p, pm, m.w, n, q, r.w);
  return r;
}

FEVM_HD u256 exp(u256 base, u256 e) {
  u256 r = u256::from_u64(1);
  unsigned bits = e.bit_len();
  for (unsigned i = 0; i < bits; i++) {
    if ((e.w[i / 64] >> (i % 64)) & 1) r = mul(r, base);
    if (i + 1 < bits) base = mul(base, base);
  }
  return r;
}

FEVM_HD u256 signextend(const u256& b, const u256& x) {
  if (!b.fits_u64() || b.w[0] >= 31) return x;
  unsigned bit = (unsigned)b.w[0] * 8 + 7;
  unsigned limb = bit / 64, off = bit % 64;
  bool sign = (x.w[limb] >> off) & 1;
  u256 r = x;
  uint64_t mask = off == 63 ? ~0ull : ((1ull << (off + 1)) - 1);
  if (sign) {
    r.w[limb] |= ~mask;
    for (unsigned i = limb + 1; i < 4; i++) r.w[i] = ~0ull;
  } else {
    r.w[limb] &= mask;
    for (unsigned i = limb + 1; i < 4; i++) r.w[i] = 0;
  }
  return r;
}

FEVM_HD u256 byte_op(const u256& i, const u256& x) {
  if (!i.fits_u64() || i.w[0] >= 32) return u256::zero();
  unsigned idx = 31 - (unsigned)i.w[0];  // byte index from least significant
  return u256::from_u64((x.w[idx / 8] >> ((idx % 8) * 8)) & 0xff);
}

FEVM_HD u256 clz256(const u256& x) {
  return u256::from_u64(256 - x.bit_len());
}

}  // namespace fevm
