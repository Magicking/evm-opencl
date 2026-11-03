#include <gtest/gtest.h>

#include <random>
#include <string>

#include "common/hashes.cuh"
#include "common/keccak.cuh"
#include "common/uint256.cuh"

using namespace fevm;

static std::string hex(const uint8_t* p, size_t n) {
  static const char* d = "0123456789abcdef";
  std::string s;
  for (size_t i = 0; i < n; i++) {
    s += d[p[i] >> 4];
    s += d[p[i] & 15];
  }
  return s;
}

static u256 from_hex(const std::string& h) {
  uint8_t b[32] = {0};
  std::string s = h;
  while (s.size() < 64) s = "0" + s;
  for (int i = 0; i < 32; i++) b[i] = (uint8_t)std::stoi(s.substr(i * 2, 2), nullptr, 16);
  return u256::from_be(b);
}

static std::string to_hex(const u256& v) {
  uint8_t b[32];
  v.to_be(b);
  return hex(b, 32);
}

TEST(Keccak, Vectors) {
  uint8_t h[32];
  keccak256(nullptr, 0, h);
  EXPECT_EQ(hex(h, 32), "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470");
  keccak256((const uint8_t*)"abc", 3, h);
  EXPECT_EQ(hex(h, 32), "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45");
  std::string big(200, 'a');
  keccak256((const uint8_t*)big.data(), big.size(), h);
  // keccak256("a" * 200)
  uint8_t h2[32];
  std::string s136(136, 'a');
  keccak256((const uint8_t*)s136.data(), s136.size(), h2);
  EXPECT_NE(hex(h, 32), hex(h2, 32));
}

TEST(Hashes, Sha256Ripemd) {
  uint8_t h[32];
  sha256((const uint8_t*)"abc", 3, h);
  EXPECT_EQ(hex(h, 32), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  sha256(nullptr, 0, h);
  EXPECT_EQ(hex(h, 32), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  std::string m = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
  sha256((const uint8_t*)m.data(), m.size(), h);
  EXPECT_EQ(hex(h, 32), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
  uint8_t r[20];
  ripemd160((const uint8_t*)"abc", 3, r);
  EXPECT_EQ(hex(r, 20), "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc");
  ripemd160(nullptr, 0, r);
  EXPECT_EQ(hex(r, 20), "9c1185a5c5e9fc54612808977ee8f548b2258d31");
  ripemd160((const uint8_t*)m.data(), m.size(), r);
  EXPECT_EQ(hex(r, 20), "12a053384a9c0c88e405a06c27dcf49ada62eb2b");
}

TEST(Hashes, Blake2fEip152) {
  // EIP-152 test vector 5 (12 rounds, final).
  std::string msg = "616263";
  msg.resize(256, '0');
  std::string in = std::string("0000000c") +
                   "48c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5d182e6ad7f520e511f6c3e2b8c68059b6bbd41fb"
                   "abd9831f79217e1319cde05b" +
                   msg + "0300000000000000" + "0000000000000000" + "01";
  ASSERT_EQ(in.size(), 426u);
  uint8_t b[213];
  for (int i = 0; i < 213; i++) b[i] = (uint8_t)std::stoi(in.substr(i * 2, 2), nullptr, 16);
  uint64_t h[8], m[16], t[2];
  for (int i = 0; i < 8; i++) h[i] = load_le64(b + 4 + i * 8);
  for (int i = 0; i < 16; i++) m[i] = load_le64(b + 68 + i * 8);
  t[0] = load_le64(b + 196);
  t[1] = load_le64(b + 204);
  blake2b_f(12, h, m, t, true);
  uint8_t out[64];
  for (int i = 0; i < 8; i++) store_le64(out + i * 8, h[i]);
  EXPECT_EQ(hex(out, 64),
            "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1"
            "925ab92386edd4009923");
}

TEST(U256, Basic) {
  u256 a = from_hex("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
  u256 one = u256::from_u64(1);
  EXPECT_TRUE(add(a, one).is_zero());
  EXPECT_EQ(sub(u256::zero(), one), a);
  EXPECT_EQ(to_hex(mul(a, a)), to_hex(one));
  u256 x = from_hex("123456789abcdef0fedcba9876543210ffeeddccbbaa99887766554433221100");
  u256 y = from_hex("0000000000000000000000000000000100000000000000000000000000000003");
  u256 q, r;
  udivmod(x, y, &q, &r);
  EXPECT_EQ(add(mul(q, y), r), x);
  EXPECT_TRUE(lt(r, y));
  EXPECT_EQ(sdiv(neg(u256::from_u64(10)), u256::from_u64(3)), neg(u256::from_u64(3)));
  EXPECT_EQ(smod(neg(u256::from_u64(10)), u256::from_u64(3)), neg(u256::from_u64(1)));
  EXPECT_EQ(addmod(a, a, u256::from_u64(7)), u256::from_u64(2));  // 2^256 = 2 mod 7
  EXPECT_EQ(mulmod(a, a, u256::from_u64(12)), u256::from_u64(9));  // (2^256-1)^2 mod 12: 2^256-1 = 3 mod 12 -> 9
  EXPECT_EQ(exp(u256::from_u64(2), u256::from_u64(255)), shl(one, 255));
  EXPECT_EQ(signextend(u256::zero(), u256::from_u64(0xff)), a);
  EXPECT_EQ(byte_op(u256::from_u64(31), u256::from_u64(0xab)), u256::from_u64(0xab));
  EXPECT_EQ(sar(shl(one, 255), 255), a);
  EXPECT_EQ(clz256(u256::zero()), u256::from_u64(256));
  EXPECT_EQ(clz256(one), u256::from_u64(255));
}

// Randomised check of division against a bit-serial reference.
static void ref_divmod(const u256& a, const u256& b, u256* q, u256* r) {
  u256 Q = u256::zero(), R = u256::zero();
  for (int i = 255; i >= 0; i--) {
    R = shl(R, 1);
    if ((a.w[i / 64] >> (i % 64)) & 1) R.w[0] |= 1;
    if (!lt(R, b)) {
      R = sub(R, b);
      Q.w[i / 64] |= 1ull << (i % 64);
    }
  }
  *q = Q;
  *r = R;
}

TEST(U256, DivisionRandom) {
  std::mt19937_64 rng(42);
  for (int it = 0; it < 20000; it++) {
    u256 a, b;
    int la = 1 + rng() % 4, lb = 1 + rng() % 4;
    for (int i = 0; i < 4; i++) {
      a.w[i] = i < la ? rng() : 0;
      b.w[i] = i < lb ? rng() : 0;
    }
    if (rng() % 4 == 0) b.w[lb - 1] >>= rng() % 63;
    if (b.is_zero()) continue;
    u256 q1, r1, q2, r2;
    udivmod(a, b, &q1, &r1);
    ref_divmod(a, b, &q2, &r2);
    ASSERT_EQ(to_hex(q1), to_hex(q2)) << to_hex(a) << " / " << to_hex(b);
    ASSERT_EQ(to_hex(r1), to_hex(r2));
  }
}

TEST(U256, MulmodRandom) {
  std::mt19937_64 rng(7);
  for (int it = 0; it < 5000; it++) {
    u256 a{{rng(), rng(), rng(), rng()}}, b{{rng(), rng(), rng(), rng()}}, m{{rng(), rng() >> (rng() % 64), 0, 0}};
    if (rng() & 1) m.w[3] = rng();
    if (m.is_zero()) continue;
    // Reference: (a mod m) * (b mod m) via repeated doubling.
    u256 am = umod(a, m), bm = umod(b, m), acc = u256::zero();
    for (int i = 255; i >= 0; i--) {
      acc = addmod(acc, acc, m);
      if ((bm.w[i / 64] >> (i % 64)) & 1) acc = addmod(acc, am, m);
    }
    ASSERT_EQ(to_hex(mulmod(a, b, m)), to_hex(acc));
  }
}
