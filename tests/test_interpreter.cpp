#include <gtest/gtest.h>

#include <cstddef>
#include <cstdlib>
#include <random>
#include <string>
#include <tuple>
#include <vector>

#include "../tools/common/memhost.hpp"

using namespace memhost;

static std::vector<uint8_t> hexb(const std::string& h) {
  std::vector<uint8_t> v;
  for (size_t i = 0; i + 1 < h.size(); i += 2) v.push_back((uint8_t)std::stoi(h.substr(i, 2), nullptr, 16));
  return v;
}

struct Env {
  fevm_engine* eng = nullptr;
  World w;
  fevm_block_ctx blk{};
  explicit Env(fevm_backend backend = FEVM_BACKEND_CPU) {
    fevm_config cfg{};
    cfg.backend = backend;
    cfg.cpu_threads = 4;
    const char* err = nullptr;
    eng = fevm_engine_create(&cfg, &err);
    blk.number = 100;
    blk.timestamp = 1000;
    blk.gas_limit = 30000000;
    blk.fork = FEVM_FORK_PRAGUE;
    blk.chain_id.bytes[31] = 1;
    blk.coinbase.bytes[19] = 0xcb;
  }
  ~Env() { fevm_engine_destroy(eng); }

  struct Out {
    fevm_result r;
    std::vector<uint8_t> output;
  };

  Out call(const Addr& from, const Addr& to, const std::vector<uint8_t>& input, uint64_t gas, uint64_t value = 0,
           bool apply = true) {
    fevm_batch* b = fevm_batch_create(eng, &blk);
    fevm_message m{};
    m.kind = FEVM_MSG_CALL;
    memcpy(m.sender.bytes, from.b, 20);
    memcpy(m.recipient.bytes, to.b, 20);
    memcpy(m.origin.bytes, from.b, 20);
    m.gas = gas;
    m.input = input.data();
    m.input_len = input.size();
    Hash32 v = h32_from_u64(value);
    memcpy(m.value.bytes, v.b, 32);
    fevm_batch_add(b, &m);
    fevm_host h = w.host();
    EXPECT_EQ(fevm_batch_execute(b, &h), 0);
    Out o;
    o.r = *fevm_batch_result(b, 0);
    o.output.assign(o.r.output, o.r.output + o.r.output_len);
    if (apply) w.apply(o.r);
    o.r.output = nullptr;
    o.r.accounts = nullptr;
    o.r.slots = nullptr;
    o.r.logs = nullptr;
    fevm_batch_destroy(b);
    return o;
  }

  Out create(const Addr& from, const std::vector<uint8_t>& init, uint64_t gas) {
    fevm_batch* b = fevm_batch_create(eng, &blk);
    fevm_message m{};
    m.kind = FEVM_MSG_CREATE;
    memcpy(m.sender.bytes, from.b, 20);
    memcpy(m.origin.bytes, from.b, 20);
    m.gas = gas;
    m.input = init.data();
    m.input_len = init.size();
    fevm_batch_add(b, &m);
    fevm_host h = w.host();
    EXPECT_EQ(fevm_batch_execute(b, &h), 0);
    Out o;
    o.r = *fevm_batch_result(b, 0);
    o.output.assign(o.r.output, o.r.output + o.r.output_len);
    w.apply(o.r);
    fevm_batch_destroy(b);
    return o;
  }
};

static uint64_t out_u64(const std::vector<uint8_t>& o) {
  uint64_t v = 0;
  for (size_t i = o.size() >= 8 ? o.size() - 8 : 0; i < o.size(); i++) v = (v << 8) | o[i];
  return v;
}

TEST(Interp, AddReturn) {
  Env e;
  Addr c = addr_from_u64(0x1000), u = addr_from_u64(0xaaaa);
  // PUSH1 2 PUSH1 3 ADD PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
  e.w.at(c).code = hexb("6002600301600052602060" "00f3");
  e.w.at(u).balance = h32_from_u64(1000000);
  auto o = e.call(u, c, {}, 100000);
  EXPECT_EQ(o.r.status, (uint32_t)FEVM_STATUS_SUCCESS);
  ASSERT_EQ(o.output.size(), 32u);
  EXPECT_EQ(out_u64(o.output), 5u);
  EXPECT_EQ(o.r.gas_left, 100000u - 24u);
}

TEST(Interp, StorageAndRefund) {
  Env e;
  Addr c = addr_from_u64(0x1000), u = addr_from_u64(0xaaaa);
  // SSTORE(1, 0x42); SLOAD(1) -> return
  e.w.at(c).code = hexb("6042600155" "600154600052" "60206000f3");
  auto o = e.call(u, c, {}, 100000);
  EXPECT_EQ(o.r.status, (uint32_t)FEVM_STATUS_SUCCESS);
  EXPECT_EQ(out_u64(o.output), 0x42u);
  // PUSH,PUSH(6) + SSTORE cold set (22100) + PUSH(3) + SLOAD warm (100) + PUSH,MSTORE (3+3+3) + PUSH,PUSH(6)
  EXPECT_EQ(o.r.gas_left, 100000u - (6 + 22100 + 3 + 100 + 9 + 6));
  EXPECT_EQ(e.w.at(c).storage.size(), 1u);
  // Clear it: refund 4800.
  e.w.at(c).code = hexb("6000600155");
  auto o2 = e.call(u, c, {}, 100000);
  EXPECT_EQ(o2.r.status, (uint32_t)FEVM_STATUS_SUCCESS);
  EXPECT_EQ(o2.r.refund, 4800);
  EXPECT_EQ(e.w.at(c).storage.size(), 0u);
}

TEST(Interp, NestedCallAndRevert) {
  Env e;
  Addr a = addr_from_u64(0xa0a0), bb = addr_from_u64(0xb0b0), u = addr_from_u64(0xaaaa);
  // B: return 0x77
  e.w.at(bb).code = hexb("607760005260206000f3");
  // A: CALL(gas, B, 0, 0,0, 0,32) then return mem[0..32]
  // PUSH1 32 PUSH1 0 PUSH1 0 PUSH1 0 PUSH1 0 PUSH1 0x0b GAS CALL POP PUSH1 32 PUSH1 0 RETURN
  e.w.at(a).code = hexb("60206000600060006000" "61b0b0" "5af150" "60206000f3");
  auto o = e.call(u, a, {}, 200000);
  EXPECT_EQ(o.r.status, (uint32_t)FEVM_STATUS_SUCCESS);
  EXPECT_EQ(out_u64(o.output), 0x77u);
  // Revert carries data and reverts storage.
  e.w.at(a).code = hexb("6001600055" "60aa60005260206000fd");
  auto o2 = e.call(u, a, {}, 200000);
  EXPECT_EQ(o2.r.status, (uint32_t)FEVM_STATUS_REVERT);
  EXPECT_EQ(out_u64(o2.output), 0xaau);
  EXPECT_EQ(e.w.at(a).storage.size(), 0u);
}

TEST(Interp, CreateDeploys) {
  Env e;
  Addr u = addr_from_u64(0xaaaa);
  e.w.at(u).balance = h32_from_u64(1000000);
  // init: store runtime "602a60005260206000f3" (10 bytes) into memory and return it.
  // PUSH10 <runtime> PUSH1 0 MSTORE PUSH1 10 PUSH1 22 RETURN
  auto o = e.create(u, hexb("69602a60005260206000f3600052600a6016f3"), 200000);
  EXPECT_EQ(o.r.status, (uint32_t)FEVM_STATUS_SUCCESS);
  EXPECT_EQ(o.output.size(), 10u);
  Addr created;
  memcpy(created.b, o.r.created_address.bytes, 20);
  EXPECT_EQ(e.w.at(created).code.size(), 10u);
  EXPECT_EQ(e.w.at(created).nonce, 1u);
  EXPECT_EQ(e.w.at(u).nonce, 1u);
  auto o2 = e.call(u, created, {}, 100000);
  EXPECT_EQ(out_u64(o2.output), 42u);
}

// Frame mode (evm2 runner): the client already moved value / created the account; the engine
// runs the supplied code only and returns the output without depositing it.
TEST(Interp, FrameMode) {
  Env e;
  Addr c = addr_from_u64(0x1000), u = addr_from_u64(0xaaaa);
  e.w.at(u).balance = h32_from_u64(500);
  e.w.at(c).balance = h32_from_u64(7);  // value already credited by the client
  e.w.at(c).code = hexb("00");          // ignored: frame mode runs `code`
  // CALLVALUE PUSH1 0 MSTORE  SELFBALANCE PUSH1 32 MSTORE  PUSH1 64 PUSH1 0 RETURN
  auto body = hexb("34600052" "47602052" "60406000f3");
  auto run = [&](uint32_t is_create, const std::vector<uint8_t>& code, const std::vector<uint8_t>& input) {
    fevm_batch* b = fevm_batch_create(e.eng, &e.blk);
    fevm_message m{};
    m.kind = FEVM_MSG_CALL;
    memcpy(m.sender.bytes, u.b, 20);
    memcpy(m.recipient.bytes, c.b, 20);
    memcpy(m.origin.bytes, u.b, 20);
    m.gas = 100000;
    Hash32 v = h32_from_u64(7);
    memcpy(m.value.bytes, v.b, 32);
    m.input = input.data();
    m.input_len = input.size();
    m.frame_mode = 1;
    m.frame_is_create = is_create;
    m.code = code.data();
    m.code_len = code.size();
    EXPECT_GE(fevm_batch_add(b, &m), 0);
    fevm_host h = e.w.host();
    EXPECT_EQ(fevm_batch_execute(b, &h), 0);
    fevm_result r = *fevm_batch_result(b, 0);
    std::vector<uint8_t> out(r.output, r.output + r.output_len);
    uint32_t n_acc = r.n_accounts;
    fevm_batch_destroy(b);
    return std::make_tuple(r.status, out, n_acc);
  };
  auto [st, out, n_acc] = run(0, body, {});
  EXPECT_EQ(st, (uint32_t)FEVM_STATUS_SUCCESS);
  ASSERT_EQ(out.size(), 64u);
  EXPECT_EQ(out_u64(std::vector<uint8_t>(out.begin(), out.begin() + 32)), 7u);  // CALLVALUE
  EXPECT_EQ(out_u64(out), 7u);  // balance unchanged: no second transfer
  EXPECT_EQ(n_acc, 0u);         // no balance diffs
  // CREATE body: calldata ignored, output returned raw (deposit is the client's job).
  // CALLDATASIZE PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
  auto [st2, out2, n2] = run(1, hexb("36600052" "60206000f3"), hexb("deadbeef"));
  EXPECT_EQ(st2, (uint32_t)FEVM_STATUS_SUCCESS);
  ASSERT_EQ(out2.size(), 32u);
  EXPECT_EQ(out_u64(out2), 0u);
  EXPECT_TRUE(e.w.at(c).code == hexb("00"));
  (void)n2;
}

TEST(Interp, BatchIndependent) {
  Env e;
  Addr c = addr_from_u64(0x1000);
  // Return CALLER as a word.
  e.w.at(c).code = hexb("3360005260206000f3");
  fevm_batch* b = fevm_batch_create(e.eng, &e.blk);
  const int N = 257;
  for (int i = 0; i < N; i++) {
    fevm_message m{};
    Addr u = addr_from_u64(0x10000 + i);
    memcpy(m.sender.bytes, u.b, 20);
    memcpy(m.recipient.bytes, c.b, 20);
    m.gas = 50000;
    fevm_batch_add(b, &m);
  }
  fevm_host h = e.w.host();
  ASSERT_EQ(fevm_batch_execute(b, &h), 0);
  for (int i = 0; i < N; i++) {
    const fevm_result* r = fevm_batch_result(b, i);
    ASSERT_EQ(r->status, (uint32_t)FEVM_STATUS_SUCCESS);
    std::vector<uint8_t> o(r->output, r->output + r->output_len);
    EXPECT_EQ(out_u64(o), 0x10000u + i);
  }
  fevm_batch_destroy(b);
}

TEST(Interp, Precompiles) {
  Env e;
  Addr a = addr_from_u64(0xa0a0), u = addr_from_u64(0xaaaa);
  // sha256("abc") via STATICCALL to 0x02: MSTORE8 'a','b','c' at 0..2
  // PUSH1 0x61 PUSH1 0 MSTORE8 PUSH1 0x62 PUSH1 1 MSTORE8 PUSH1 0x63 PUSH1 2 MSTORE8
  // PUSH1 32 PUSH1 32 PUSH1 3 PUSH1 0 PUSH1 2 GAS STATICCALL POP PUSH1 32 PUSH1 32 RETURN
  e.w.at(a).code = hexb("606160005360626001536063600253" "6020602060036000" "60025afa50" "60206020f3");
  auto o = e.call(u, a, {}, 200000);
  ASSERT_EQ(o.r.status, (uint32_t)FEVM_STATUS_SUCCESS);
  ASSERT_EQ(o.output.size(), 32u);
  EXPECT_EQ(o.output[0], 0xba);
  EXPECT_EQ(o.output[31], 0xad);
}

TEST(Interp, InfiniteLoopOutOfGas) {
  Env e;
  Addr c = addr_from_u64(0x1000), u = addr_from_u64(0xaaaa);
  e.w.at(c).code = hexb("5b600056");  // JUMPDEST PUSH1 0 JUMP
  auto o = e.call(u, c, {}, 100000);
  EXPECT_EQ(o.r.status, (uint32_t)FEVM_STATUS_HALT);
  EXPECT_EQ(o.r.error, (uint32_t)FEVM_ERR_OUT_OF_GAS);
  EXPECT_EQ(o.r.gas_left, 0u);
}

TEST(Interp, GpuMatchesCpu) {
  if (!fevm_gpu_available()) GTEST_SKIP() << "no GPU";
  for (int backend = 0; backend < 2; backend++) {
    Env e(backend ? FEVM_BACKEND_GPU : FEVM_BACKEND_CPU);
    ASSERT_NE(e.eng, nullptr);
    Addr c = addr_from_u64(0x1000), u = addr_from_u64(0xaaaa);
    // Sum 1..100 into storage slot 0 and return it.
    e.w.at(c).code = hexb("6000" "6064" "5b" "8015601557" "80" "91" "01" "90" "6001" "90" "03" "6004" "56" "5b" "50" "80600055" "60005260206000f3");
    auto o = e.call(u, c, {}, 1000000);
    ASSERT_EQ(o.r.status, (uint32_t)FEVM_STATUS_SUCCESS) << "backend " << backend << " err " << o.r.error;
    EXPECT_EQ(out_u64(o.output), 5050u) << "backend " << backend;
  }
}

// Differential fuzzing: random programs must give identical results on the CPU
// and GPU backends (status, error, gas, output, state diff, logs).
static std::vector<uint8_t> random_program(std::mt19937_64& rng) {
  // {opcode, inputs, outputs}; generation tracks the stack depth so most programs run to completion.
  struct Op {
    uint8_t op, in, out;
  };
  static const Op ops[] = {
      {0x01, 2, 1}, {0x02, 2, 1}, {0x03, 2, 1}, {0x04, 2, 1}, {0x05, 2, 1}, {0x06, 2, 1}, {0x07, 2, 1},
      {0x08, 3, 1}, {0x09, 3, 1}, {0x0a, 2, 1}, {0x0b, 2, 1}, {0x10, 2, 1}, {0x11, 2, 1}, {0x12, 2, 1},
      {0x13, 2, 1}, {0x14, 2, 1}, {0x15, 1, 1}, {0x16, 2, 1}, {0x17, 2, 1}, {0x18, 2, 1}, {0x19, 1, 1},
      {0x1a, 2, 1}, {0x1b, 2, 1}, {0x1c, 2, 1}, {0x1d, 2, 1}, {0x1e, 1, 1}, {0x20, 2, 1}, {0x30, 0, 1},
      {0x31, 1, 1}, {0x33, 0, 1}, {0x34, 0, 1}, {0x35, 1, 1}, {0x36, 0, 1}, {0x38, 0, 1}, {0x3a, 0, 1},
      {0x3b, 1, 1}, {0x3d, 0, 1}, {0x3f, 1, 1}, {0x41, 0, 1}, {0x42, 0, 1}, {0x43, 0, 1}, {0x45, 0, 1},
      {0x46, 0, 1}, {0x47, 0, 1}, {0x48, 0, 1}, {0x50, 1, 0}, {0x51, 1, 1}, {0x52, 2, 0}, {0x53, 2, 0},
      {0x54, 1, 1}, {0x55, 2, 0}, {0x58, 0, 1}, {0x59, 0, 1}, {0x5a, 0, 1}, {0x5b, 0, 0}, {0x5c, 1, 1},
      {0x5d, 2, 0}, {0x5e, 3, 0}, {0x5f, 0, 1}, {0x80, 1, 2}, {0x81, 2, 3}, {0x82, 3, 4}, {0x90, 2, 2},
      {0x91, 3, 3}, {0xa0, 2, 0}, {0xa1, 3, 0}, {0xa2, 4, 0}, {0x37, 3, 0}, {0x39, 3, 0}, {0x3e, 3, 0},
  };
  std::vector<uint8_t> p;
  int depth = 0;
  int n = 20 + rng() % 200;
  for (int i = 0; i < n; i++) {
    int k = rng() % 10;
    if (k < 4 || depth < 3) {
      p.push_back(0x60);  // small values keep memory offsets/sizes cheap
      p.push_back((uint8_t)(rng() % 64));
      depth++;
      continue;
    }
    if (k == 4) {
      int len = 1 + rng() % 32;
      p.push_back((uint8_t)(0x5f + len));
      for (int j = 0; j < len; j++) p.push_back((uint8_t)rng());
      depth++;
      continue;
    }
    if (k == 5 && depth >= 7) {
      // CALL/STATICCALL to an address 0..63 (precompiles, empty accounts) with small gas.
      bool st = rng() % 2;
      p.insert(p.end(), {0x60, 0x20, 0x60, 0x00, 0x60, 0x20, 0x60, 0x00});  // out_len out_off in_len in_off
      if (!st) p.insert(p.end(), {0x60, 0x00});                              // value
      p.insert(p.end(), {0x60, (uint8_t)(rng() % 12), 0x61, 0x27, 0x10, (uint8_t)(st ? 0xfa : 0xf1)});
      depth++;
      continue;
    }
    const Op& o = ops[rng() % (sizeof(ops) / sizeof(ops[0]))];
    if (o.in > depth || depth - o.in + o.out > 1000) continue;
    p.push_back(o.op);
    depth += o.out - o.in;
  }
  p.insert(p.end(), {0x60, 0x20, 0x60, 0x00});
  p.push_back(rng() % 4 ? 0xf3 : 0xfd);
  return p;
}

TEST(Interp, FuzzCpuVsGpu) {
  if (!fevm_gpu_available()) GTEST_SKIP() << "no GPU";
  std::mt19937_64 rng(1234);
  const int N = 2000;
  std::vector<std::vector<uint8_t>> progs;
  for (int i = 0; i < N; i++) progs.push_back(random_program(rng));
  std::vector<std::string> sig[2];
  for (int be = 0; be < 2; be++) {
    Env e(be ? FEVM_BACKEND_GPU : FEVM_BACKEND_CPU);
    fevm_batch* b = fevm_batch_create(e.eng, &e.blk);
    for (int i = 0; i < N; i++) {
      Addr c = addr_from_u64(0x100000 + i);
      e.w.at(c).code = progs[i];
      e.w.at(c).balance = h32_from_u64(1000 + i);
      e.w.at(c).storage[h32_from_u64(1)] = h32_from_u64(7);
      fevm_message m{};
      Addr u = addr_from_u64(0xaaaa);
      memcpy(m.sender.bytes, u.b, 20);
      memcpy(m.recipient.bytes, c.b, 20);
      m.gas = 200000;
      m.input = progs[i].data();
      m.input_len = std::min<size_t>(progs[i].size(), 40);
      fevm_batch_add(b, &m);
    }
    e.w.at(addr_from_u64(0xaaaa)).balance = h32_from_u64(1000000);
    fevm_host h = e.w.host();
    ASSERT_EQ(fevm_batch_execute(b, &h), 0);
    for (int i = 0; i < N; i++) {
      const fevm_result* r = fevm_batch_result(b, i);
      std::string s = std::to_string(r->status) + "/" + std::to_string(r->error) + "/" + std::to_string(r->gas_left) +
                      "/" + std::to_string(r->refund) + "/" + std::string((const char*)r->output, r->output_len);
      for (uint32_t k = 0; k < r->n_accounts; k++)
        s += "|A" + std::string((const char*)&r->accounts[k], offsetof(fevm_account_diff, code));
      for (uint32_t k = 0; k < r->n_slots; k++) s += "|S" + std::string((const char*)&r->slots[k], sizeof(fevm_slot_diff));
      for (uint32_t k = 0; k < r->n_logs; k++)
        s += "|L" + std::to_string(r->logs[k].n_topics) + std::string((const char*)r->logs[k].data, r->logs[k].data_len);
      sig[be].push_back(s);
    }
    fevm_batch_destroy(b);
  }
  int diffs = 0, ok = 0, with_diff = 0;
  for (int i = 0; i < N; i++) {
    if (sig[0][i] != sig[1][i] && diffs++ < 5) ADD_FAILURE() << "program " << i << " differs";
    if (sig[0][i][0] == '0') ok++;
    if (sig[0][i].find("|S") != std::string::npos || sig[0][i].find("|L") != std::string::npos) with_diff++;
  }
  printf("fuzz: %d/%d succeeded, %d wrote storage or logs\n", ok, N, with_diff);
  EXPECT_GT(ok, N / 10);
  EXPECT_EQ(diffs, 0);
}
