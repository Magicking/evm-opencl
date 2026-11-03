// fastevm-run: executes EVM bytecode on the fastevm engine.
//
//   fastevm-run --code 6002600301 [--input HEX] [--gas N] [--batch N] [--repeat R]
//               [--backend cpu|gpu] [--fork cancun|prague|osaka] [--json]
//
// With --batch N, N independent messages (distinct senders, same contract) run
// in one batch; --repeat repeats the whole batch and reports the best/median time.
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "../common/memhost.hpp"

using namespace memhost;

static std::vector<uint8_t> parse_hex(std::string h) {
  std::vector<uint8_t> v;
  if (h.rfind("0x", 0) == 0) h = h.substr(2);
  std::string clean;
  for (char c : h)
    if (isxdigit((unsigned char)c)) clean += c;
  for (size_t i = 0; i + 1 < clean.size(); i += 2) v.push_back((uint8_t)std::stoi(clean.substr(i, 2), nullptr, 16));
  return v;
}

static void usage() {
  fprintf(stderr,
          "usage: fastevm-run (--code HEX | --codefile FILE) [--input HEX] [--gas N] [--batch N] [--repeat R]\n"
          "                   [--backend cpu|gpu] [--fork cancun|prague|osaka] [--threads N] [--arena BYTES] [--json]\n");
  exit(2);
}

int main(int argc, char** argv) {
  std::vector<uint8_t> code, input;
  uint64_t gas = 30000000;
  uint32_t batch = 1, repeat = 1, threads = 0;
  uint64_t arena = 0;
  bool json = false;
  fevm_backend backend = FEVM_BACKEND_CPU;
  fevm_fork fork = FEVM_FORK_OSAKA;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto next = [&]() -> std::string {
      if (i + 1 >= argc) usage();
      return argv[++i];
    };
    if (a == "--code")
      code = parse_hex(next());
    else if (a == "--codefile") {
      std::ifstream f(next());
      std::stringstream ss;
      ss << f.rdbuf();
      code = parse_hex(ss.str());
    } else if (a == "--input")
      input = parse_hex(next());
    else if (a == "--gas")
      gas = strtoull(next().c_str(), nullptr, 0);
    else if (a == "--batch")
      batch = (uint32_t)strtoul(next().c_str(), nullptr, 0);
    else if (a == "--repeat")
      repeat = (uint32_t)strtoul(next().c_str(), nullptr, 0);
    else if (a == "--arena")
      arena = strtoull(next().c_str(), nullptr, 0);
    else if (a == "--threads")
      threads = (uint32_t)strtoul(next().c_str(), nullptr, 0);
    else if (a == "--backend") {
      std::string b = next();
      backend = b == "gpu" ? FEVM_BACKEND_GPU : FEVM_BACKEND_CPU;
    } else if (a == "--fork") {
      std::string f = next();
      fork = f == "cancun" ? FEVM_FORK_CANCUN : f == "prague" ? FEVM_FORK_PRAGUE : FEVM_FORK_OSAKA;
    } else if (a == "--json")
      json = true;
    else
      usage();
  }
  if (code.empty()) usage();

  fevm_config cfg{};
  cfg.backend = backend;
  cfg.cpu_threads = threads;
  cfg.lane_arena_bytes = arena;
  const char* err = nullptr;
  fevm_engine* eng = fevm_engine_create(&cfg, &err);
  if (!eng) {
    fprintf(stderr, "engine: %s\n", err ? err : "error");
    return 1;
  }
  World w;
  Addr contract = addr_from_u64(0xc0de);
  w.at(contract).code = code;
  fevm_block_ctx blk{};
  blk.number = 1;
  blk.timestamp = 1;
  blk.gas_limit = gas;
  blk.fork = fork;
  blk.chain_id.bytes[31] = 1;

  std::vector<double> times;
  fevm_result last{};
  std::vector<uint8_t> out;
  uint64_t gas_used_total = 0, steps_total = 0;
  fevm_batch_stats stats{};
  for (uint32_t r = 0; r < repeat; r++) {
    fevm_batch* b = fevm_batch_create(eng, &blk);
    for (uint32_t i = 0; i < batch; i++) {
      fevm_message m{};
      Addr s = addr_from_u64(0x100000 + i);
      memcpy(m.sender.bytes, s.b, 20);
      memcpy(m.origin.bytes, s.b, 20);
      memcpy(m.recipient.bytes, contract.b, 20);
      m.gas = gas;
      m.input = input.data();
      m.input_len = input.size();
      fevm_batch_add(b, &m);
    }
    fevm_host h = w.host();
    auto t0 = std::chrono::steady_clock::now();
    int rc = fevm_batch_execute(b, &h);
    auto t1 = std::chrono::steady_clock::now();
    if (rc) fprintf(stderr, "execute rc=%d\n", rc);
    times.push_back(std::chrono::duration<double>(t1 - t0).count());
    gas_used_total = 0;
    steps_total = 0;
    for (uint32_t i = 0; i < batch; i++) {
      const fevm_result* res = fevm_batch_result(b, i);
      gas_used_total += gas - res->gas_left;
      steps_total += res->steps;
    }
    const fevm_result* res = fevm_batch_result(b, 0);
    last = *res;
    out.assign(res->output, res->output + res->output_len);
    fevm_batch_stats_get(b, &stats);
    fevm_batch_destroy(b);
  }
  std::vector<double> sorted = times;
  std::sort(sorted.begin(), sorted.end());
  double best = sorted.front(), median = sorted[sorted.size() / 2];
  std::string outhex;
  for (uint8_t c : out) {
    char buf[3];
    snprintf(buf, sizeof buf, "%02x", c);
    outhex += buf;
  }
  if (json) {
    printf(
        "{\"backend\":\"%s\",\"batch\":%u,\"repeat\":%u,\"status\":%u,\"error\":%u,\"gas_used\":%llu,"
        "\"steps\":%llu,\"best_s\":%.9f,\"median_s\":%.9f,\"msgs_per_s\":%.1f,\"mgas_per_s\":%.3f,"
        "\"rounds\":%u,\"cpu_retried\":%llu,\"exec_s\":%.6f,\"transfer_s\":%.6f,\"output\":\"%s\"}\n",
        backend == FEVM_BACKEND_GPU ? "gpu" : "cpu", batch, repeat, last.status, last.error,
        (unsigned long long)gas_used_total, (unsigned long long)steps_total, best, median, batch / median,
        gas_used_total / median / 1e6, stats.rounds, (unsigned long long)stats.cpu_retried_lanes, stats.exec_seconds,
        stats.transfer_seconds, outhex.c_str());
  } else {
    printf("status=%u error=%u gas_used(total)=%llu steps(total)=%llu\n", last.status, last.error,
           (unsigned long long)gas_used_total, (unsigned long long)steps_total);
    printf("output=0x%s\n", outhex.c_str());
    printf("time best=%.6fs median=%.6fs  %.1f msgs/s  %.2f Mgas/s  rounds=%u cpu_retried=%llu\n", best, median,
           batch / median, gas_used_total / median / 1e6, stats.rounds, (unsigned long long)stats.cpu_retried_lanes);
  }
  fevm_engine_destroy(eng);
  return 0;
}
