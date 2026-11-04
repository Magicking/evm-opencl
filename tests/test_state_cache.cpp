// Engine state cache: reuse across batches must never change results.
#include <gtest/gtest.h>

#include <string>
#include <vector>

#include "../tools/common/memhost.hpp"

using namespace memhost;

static std::vector<uint8_t> hexb(const std::string& h) {
  std::vector<uint8_t> v;
  for (size_t i = 0; i + 1 < h.size(); i += 2) v.push_back((uint8_t)std::stoi(h.substr(i, 2), nullptr, 16));
  return v;
}

// bench/corpus/erc20_transfer.json: transfer(to, amount) on a balance mapping, minting to the
// sender when short.
static const char* kErc20 =
    "60003560e01c63a9059cbb146100155760006000fd5b3360005260006020526040600020805460243581101561003f576c0c9f2c"
    "9cd04674edea40000000015b602435900390556004356000526040600020805460243501905560243560005260043533";
static const char* kErc20Input =
    "a9059cbb00000000000000000000000000000000000000000000000000000000000beef000000000000000000000000000000000000000"
    "000000000000000000000003e8";

// Everything a client would observe from a lane.
struct Obs {
  uint32_t status, error;
  uint64_t gas_left;
  int64_t refund;
  std::vector<uint8_t> output;
  std::vector<std::string> accounts, slots;
  uint32_t logs;
  bool operator==(const Obs& o) const {
    return status == o.status && error == o.error && gas_left == o.gas_left && refund == o.refund &&
           output == o.output && accounts == o.accounts && slots == o.slots && logs == o.logs;
  }
};

static Obs observe(const fevm_result& r) {
  Obs o{r.status, r.error, r.gas_left, r.refund, {}, {}, {}, r.n_logs};
  o.output.assign(r.output, r.output + r.output_len);
  for (uint32_t i = 0; i < r.n_accounts; i++) {
    const fevm_account_diff& d = r.accounts[i];
    o.accounts.push_back(std::string((const char*)d.address.bytes, 20) + std::to_string(d.flags) + "/" +
                         std::to_string(d.nonce) + std::string((const char*)d.balance.bytes, 32));
  }
  for (uint32_t i = 0; i < r.n_slots; i++) {
    const fevm_slot_diff& d = r.slots[i];
    o.slots.push_back(std::string((const char*)d.address.bytes, 20) + std::string((const char*)d.key.bytes, 32) +
                      std::string((const char*)d.value.bytes, 32));
  }
  return o;
}

struct Rig {
  fevm_engine* eng = nullptr;
  World w;
  fevm_block_ctx blk{};
  Addr token = addr_from_u64(0xc0de);
  explicit Rig(fevm_backend backend, uint64_t cache_bytes = 0) {
    fevm_config cfg{};
    cfg.backend = backend;
    cfg.cpu_threads = 4;
    cfg.state_cache_bytes = cache_bytes;
    const char* err = nullptr;
    eng = fevm_engine_create(&cfg, &err);
    blk.number = 100;
    blk.timestamp = 1000;
    blk.gas_limit = 30000000;
    blk.fork = FEVM_FORK_OSAKA;
    blk.chain_id.bytes[31] = 1;
    w.at(token).code = hexb(kErc20);
  }
  ~Rig() { fevm_engine_destroy(eng); }

  // Runs n transfers from senders first_sender.. against the current world.
  // id: state id (nullptr = none). commit_id: commit results under it. Fills stats.
  std::vector<Obs> run(uint32_t n, uint64_t first_sender, const fevm_bytes32* id, const fevm_bytes32* commit_id,
                       fevm_batch_stats* st = nullptr, int* commit_rc = nullptr, bool host_warm = false,
                       const std::vector<uint8_t>* code_to_call = nullptr, const Addr* target = nullptr) {
    fevm_batch* b = fevm_batch_create(eng, &blk);
    if (id) EXPECT_EQ(fevm_batch_set_state_id(b, id), 0);
    std::vector<uint8_t> input = hexb(kErc20Input);
    Addr to = target ? *target : token;
    for (uint32_t i = 0; i < n; i++) {
      fevm_message m{};
      Addr s = addr_from_u64(first_sender + i);
      memcpy(m.sender.bytes, s.b, 20);
      memcpy(m.origin.bytes, s.b, 20);
      memcpy(m.recipient.bytes, to.b, 20);
      m.gas = 1000000;
      m.input = code_to_call ? nullptr : input.data();
      m.input_len = code_to_call ? 0 : input.size();
      m.use_host_warm_flags = host_warm;
      fevm_batch_add(b, &m);
    }
    fevm_host h = w.host();
    EXPECT_EQ(fevm_batch_execute(b, &h), 0);
    std::vector<Obs> out;
    for (uint32_t i = 0; i < n; i++) out.push_back(observe(*fevm_batch_result(b, i)));
    if (commit_id) {
      for (uint32_t i = 0; i < n; i++) w.apply(*fevm_batch_result(b, i));
      int rc = fevm_batch_commit(b, commit_id);
      if (commit_rc) *commit_rc = rc;
    }
    if (st) fevm_batch_stats_get(b, st);
    fevm_batch_destroy(b);
    return out;
  }
};

static fevm_bytes32 sid(uint8_t v) {
  fevm_bytes32 id{};
  id.bytes[0] = v;
  id.bytes[31] = 0x5a;
  return id;
}

static std::vector<fevm_backend> backends() {
  std::vector<fevm_backend> v{FEVM_BACKEND_CPU};
  if (fevm_gpu_available()) v.push_back(FEVM_BACKEND_GPU);
  return v;
}

TEST(StateCache, WarmMatchesCold) {
  for (fevm_backend be : backends()) {
    Rig cold(be), warm(be);
    fevm_bytes32 id = sid(1);
    auto ref = cold.run(700, 0x1000, nullptr, nullptr);
    fevm_batch_stats st{};
    auto first = warm.run(700, 0x1000, &id, nullptr, &st);
    EXPECT_GT(st.cache_account_fills, 0u);
    auto again = warm.run(700, 0x1000, &id, nullptr, &st);
    EXPECT_EQ(st.cache_account_fills, 0u) << "backend " << be;
    EXPECT_EQ(st.rounds, 1u) << "backend " << be;
    for (size_t i = 0; i < ref.size(); i++) {
      ASSERT_TRUE(ref[i] == first[i]) << "lane " << i << " backend " << be;
      ASSERT_TRUE(ref[i] == again[i]) << "lane " << i << " backend " << be;
    }
  }
}

TEST(StateCache, OtherIdRefetches) {
  for (fevm_backend be : backends()) {
    Rig r(be);
    fevm_bytes32 a = sid(1), b = sid(2);
    r.run(64, 0x1000, &a, nullptr);
    // The world changes behind the cache's back: a new id must not see the old balances.
    r.w.at(addr_from_u64(0x1000)).balance = h32_from_u64(7);
    fevm_batch_stats st{};
    auto o = r.run(64, 0x1000, &b, nullptr, &st);
    EXPECT_GT(st.cache_account_fills, 0u);
    Rig ref(be);
    ref.w.at(addr_from_u64(0x1000)).balance = h32_from_u64(7);
    auto want = ref.run(64, 0x1000, nullptr, nullptr);
    for (size_t i = 0; i < want.size(); i++) ASSERT_TRUE(want[i] == o[i]) << "lane " << i;
  }
}

TEST(StateCache, CommitMatchesSequential) {
  for (fevm_backend be : backends()) {
    Rig chained(be), ref(be);
    for (uint8_t k = 0; k < 4; k++) {
      fevm_bytes32 id = sid(k), next = sid(k + 1);
      int rc = -2;
      fevm_batch_stats st{};
      // Same senders every step: each transfer reads the balances the previous step wrote.
      auto got = chained.run(300, 0x1000, &id, &next, &st, &rc);
      auto want = ref.run(300, 0x1000, nullptr, &next);
      EXPECT_EQ(rc, 0) << "step " << (int)k;
      if (k > 0) EXPECT_EQ(st.cache_account_fills + st.cache_slot_fills, 0u) << "step " << (int)k;
      for (size_t i = 0; i < want.size(); i++) ASSERT_TRUE(want[i] == got[i]) << "step " << (int)k << " lane " << i;
    }
  }
}

TEST(StateCache, HostWarmFlagsDoNotLeak) {
  // BALANCE(0xdead): 100 gas when the host says the address is warm, 2600 when cold.
  std::vector<uint8_t> code = hexb("73000000000000000000000000000000000000dead31600052602060" "00f3");
  for (fevm_backend be : backends()) {
    Rig r(be);
    Addr c = addr_from_u64(0xbb);
    r.w.at(c).code = code;
    fevm_bytes32 id = sid(9);
    r.w.warm_all = true;
    auto hot = r.run(1, 0x1000, &id, nullptr, nullptr, nullptr, true, &code, &c);
    r.w.warm_all = false;
    auto cold = r.run(1, 0x1000, &id, nullptr, nullptr, nullptr, true, &code, &c);
    Rig fresh(be);
    fresh.w.at(c).code = code;
    auto want = fresh.run(1, 0x1000, nullptr, nullptr, nullptr, nullptr, true, &code, &c);
    EXPECT_EQ(hot[0].gas_left, want[0].gas_left + 2500) << "warm BALANCE is 2500 cheaper";
    EXPECT_TRUE(cold[0] == want[0]) << "backend " << be;
  }
}

TEST(StateCache, EvictionKeepsResults) {
  for (fevm_backend be : backends()) {
    // 2 MiB: 9,000 distinct sender accounts overflow it.
    Rig r(be, 2 << 20), ref(be);
    fevm_bytes32 id = sid(3);
    fevm_batch_stats st{};
    for (int k = 0; k < 6; k++) {
      uint64_t base = 0x10000 + (uint64_t)k * 1500;
      auto got = r.run(1500, base, &id, nullptr, &st);
      auto want = ref.run(1500, base, nullptr, nullptr);
      for (size_t i = 0; i < want.size(); i++) ASSERT_TRUE(want[i] == got[i]) << "round " << k << " lane " << i;
    }
    EXPECT_GT(st.cache_evictions, 0u) << "backend " << be;
    // Recently used entries survive: the last senders run again without fills of their accounts.
    auto again = r.run(1500, 0x10000 + 5 * 1500, &id, nullptr, &st);
    EXPECT_LT(st.cache_account_fills, 1500u) << "backend " << be;
  }
}

TEST(StateCache, OverlappedGroupsMatchCpu) {
  if (!fevm_gpu_available()) GTEST_SKIP() << "no GPU";
  // 6,000 lanes: two overlapping lane groups and several loads per group on the GPU.
  Rig cpu(FEVM_BACKEND_CPU), gpu(FEVM_BACKEND_GPU);
  fevm_bytes32 id = sid(4), next = sid(5);
  auto want = cpu.run(6000, 0x40000, nullptr, nullptr);
  fevm_batch_stats st{};
  auto cold = gpu.run(6000, 0x40000, &id, nullptr, &st);
  auto warm = gpu.run(6000, 0x40000, &id, &next, &st);
  EXPECT_EQ(st.cache_account_fills, 0u);
  for (size_t i = 0; i < want.size(); i++) {
    ASSERT_TRUE(want[i] == cold[i]) << "lane " << i;
    ASSERT_TRUE(want[i] == warm[i]) << "lane " << i;
  }
  // After the commit, a second step on the new state matches the CPU applying the same results.
  cpu.run(6000, 0x40000, nullptr, &next);
  auto want2 = cpu.run(6000, 0x40000, nullptr, nullptr);
  auto got2 = gpu.run(6000, 0x40000, &next, nullptr, &st);
  EXPECT_EQ(st.cache_account_fills + st.cache_slot_fills, 0u);
  for (size_t i = 0; i < want2.size(); i++) ASSERT_TRUE(want2[i] == got2[i]) << "step 2 lane " << i;
}
