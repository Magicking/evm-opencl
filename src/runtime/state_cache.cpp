// Engine-level state cache (see state_cache.hpp).
#include "state_cache.hpp"

#include <algorithm>
#include <cstring>

#include "../evm/interpreter.cuh"

namespace fevm {

static constexpr size_t kMinAcc = 1024, kMinSlot = 4096, kMinBh = 512;

static size_t pow2_ceil(size_t x) {
  size_t p = 1;
  while (p < x) p *= 2;
  return p;
}

StateCache::StateCache(uint64_t budget_bytes) : budget(budget_bytes ? budget_bytes : (512ull << 20)) { reset(); }

void StateCache::reset() {
  accounts.assign(kMinAcc, BaseAccount{});
  slots.assign(kMinSlot, BaseSlot{});
  bh.assign(kMinBh, BaseBlockHash{});
  acc_lru.assign(kMinAcc, 0);
  slot_lru.assign(kMinSlot, 0);
  code.clear();
  code.resize(8, 0);  // offset 0 is never handed out
  code_by_hash.clear();
  n_acc = n_slot = n_bh = 0;
  epoch = 1;
  has_id = false;
  dirty_acc.clear();
  dirty_slot.clear();
  dirty_bh.clear();
  full = true;
  code_synced = 0;
}

void StateCache::flush_state() {
  if (++epoch == 0) {  // epoch wrapped: old entries could look live again
    reset();
    return;
  }
  n_acc = n_slot = n_bh = 0;
  // Pending uploads only concern entries of the old epoch, which now read as empty.
  dirty_acc.clear();
  dirty_slot.clear();
  dirty_bh.clear();
}

void StateCache::begin_batch(const uint8_t* state_id) {
  seq++;
  bool same = state_id && has_id && memcmp(state_id, id, 32) == 0;
  if (!same) flush_state();
  has_id = state_id != nullptr;
  if (state_id) memcpy(id, state_id, 32);
}

uint64_t StateCache::bytes() const {
  return accounts.size() * (sizeof(BaseAccount) + 4) + slots.size() * (sizeof(BaseSlot) + 4) +
         bh.size() * sizeof(BaseBlockHash) + code.size();
}

template <typename T>
void StateCache::grow(std::vector<T>& v, std::vector<uint32_t>* lru, size_t n) {
  if (n * 4 < v.size() * 3) return;
  std::vector<T> old;
  old.swap(v);
  std::vector<uint32_t> old_lru;
  if (lru) old_lru.swap(*lru);
  v.assign(old.size() * 2, T{});
  if (lru) lru->assign(v.size(), 0);
  uint64_t mask = v.size() - 1;
  for (size_t j = 0; j < old.size(); j++) {
    const T& e = old[j];
    if (!live(e)) continue;
    uint64_t i;
    if constexpr (std::is_same<T, BaseAccount>::value)
      i = addr_hash(e.addr) & mask;
    else if constexpr (std::is_same<T, BaseSlot>::value)
      i = slot_hash(e.addr, e.key) & mask;
    else
      i = mix64(e.number) & mask;
    while (v[i].used) i = (i + 1) & mask;
    v[i] = e;
    if (lru) (*lru)[i] = old_lru[j];
  }
  full = true;
}

Loc StateCache::add_code(const uint8_t* hash, const uint8_t* c, uint64_t len, Loc* jd) {
  std::string key((const char*)hash, 32);
  auto it = code_by_hash.find(key);
  if (it != code_by_hash.end()) {
    it->second.last = seq;
    *jd = it->second.jd;
    return it->second.code;
  }
  size_t off = (code.size() + 7) & ~size_t(7);
  code.resize(off + len);
  memcpy(code.data() + off, c, len);
  size_t jd_len = (len + 7) / 8 + 1;
  size_t joff = (code.size() + 7) & ~size_t(7);
  code.resize(joff + jd_len);
  jumpdest_analysis(code.data() + off, (uint32_t)len, code.data() + joff);
  CodeEnt ce{off | LOC_CODE, joff | LOC_CODE, (uint32_t)len, seq};
  code_by_hash.emplace(key, ce);
  *jd = ce.jd;
  return ce.code;
}

BaseAccount* StateCache::find_account(const Address& a) {
  uint64_t mask = accounts.size() - 1;
  for (uint64_t i = addr_hash(a) & mask;; i = (i + 1) & mask) {
    if (!live(accounts[i])) return nullptr;
    if (addr_eq(accounts[i].addr, a)) return &accounts[i];
  }
}

BaseSlot* StateCache::find_slot(const Address& a, const u256& key) {
  uint64_t mask = slots.size() - 1;
  for (uint64_t i = slot_hash(a, key) & mask;; i = (i + 1) & mask) {
    if (!live(slots[i])) return nullptr;
    if (slots[i].key == key && addr_eq(slots[i].addr, a)) return &slots[i];
  }
}

void StateCache::put_account(const Address& a, const fevm_account_info& info, const uint8_t* c, uint64_t len,
                             uint32_t warm_lane) {
  grow(accounts, &acc_lru, n_acc + 1);
  uint64_t mask = accounts.size() - 1;
  uint64_t i = addr_hash(a) & mask;
  while (live(accounts[i]) && !addr_eq(accounts[i].addr, a)) i = (i + 1) & mask;
  BaseAccount& e = accounts[i];
  if (!live(e)) n_acc++;
  e = BaseAccount{};
  e.addr = a;
  e.used = 1;
  e.epoch = epoch;
  e.exists = info.exists;
  e.has_storage = info.has_storage;
  e.warm_lane = warm_lane;
  e.warm_seq = seq;
  e.nonce = info.nonce;
  e.balance = u256::from_be(info.balance.bytes);
  e.code_len = (uint32_t)len;
  if (len == 0) {
    memcpy(e.code_hash, empty_code_hash(), 32);
    e.code_loc = LOC_NONE;
    e.jd_loc = LOC_NONE;
  } else {
    memcpy(e.code_hash, info.code_hash.bytes, 32);
    e.code_loc = add_code(info.code_hash.bytes, c, len, &e.jd_loc);
  }
  acc_lru[i] = seq;
  acc_puts++;
  if (!full) dirty_acc.push_back((uint32_t)i);
}

void StateCache::put_slot(const Address& a, const u256& key, const u256& value, const u256& original,
                          uint32_t warm_lane) {
  grow(slots, &slot_lru, n_slot + 1);
  uint64_t mask = slots.size() - 1;
  uint64_t i = slot_hash(a, key) & mask;
  while (live(slots[i]) && !(slots[i].key == key && addr_eq(slots[i].addr, a))) i = (i + 1) & mask;
  BaseSlot& e = slots[i];
  if (!live(e)) n_slot++;
  e = BaseSlot{};
  e.addr = a;
  e.used = 1;
  e.epoch = epoch;
  e.key = key;
  e.value = value;
  e.original = original;
  e.warm_lane = warm_lane;
  e.warm_seq = seq;
  slot_lru[i] = seq;
  slot_puts++;
  if (!full) dirty_slot.push_back((uint32_t)i);
}

void StateCache::put_blockhash(uint64_t n, const uint8_t* hash) {
  grow(bh, nullptr, n_bh + 1);
  uint64_t mask = bh.size() - 1;
  uint64_t i = mix64(n) & mask;
  while (live(bh[i]) && bh[i].number != n) i = (i + 1) & mask;
  if (!live(bh[i])) n_bh++;
  bh[i].used = 1;
  bh[i].epoch = epoch;
  bh[i].number = n;
  memcpy(bh[i].hash, hash, 32);
  if (!full) dirty_bh.push_back((uint32_t)i);
}

bool StateCache::apply(const fevm_result& r) {
  if (r.status == FEVM_STATUS_FALLBACK) return false;
  for (uint32_t k = 0; k < r.n_accounts; k++) {
    const fevm_account_diff& d = r.accounts[k];
    if (d.flags & (FEVM_ACC_CREATED | FEVM_ACC_DESTRUCTED)) return false;
    Address a;
    memcpy(a.b, d.address.bytes, 20);
    BaseAccount* e = find_account(a);
    if (!e) return false;  // every account a lane changed was loaded through the cache
    if (d.flags & FEVM_ACC_BALANCE) e->balance = u256::from_be(d.balance.bytes);
    if (d.flags & FEVM_ACC_NONCE) e->nonce = d.nonce;
    if (d.flags & FEVM_ACC_CODE) {
      e->code_len = (uint32_t)d.code_len;
      memcpy(e->code_hash, d.code_hash.bytes, 32);
      if (d.code_len)
        e->code_loc = add_code(d.code_hash.bytes, d.code, d.code_len, &e->jd_loc);
      else
        e->code_loc = e->jd_loc = LOC_NONE;
    }
    e->exists = 1;
    if ((d.flags & FEVM_ACC_TOUCHED) && e->nonce == 0 && e->balance.is_zero() && e->code_len == 0) {
      if (e->has_storage) return false;
      e->exists = 0;  // EIP-158 deletion
    }
    if (!full) dirty_acc.push_back((uint32_t)(e - accounts.data()));
  }
  for (uint32_t k = 0; k < r.n_slots; k++) {
    const fevm_slot_diff& d = r.slots[k];
    Address a;
    memcpy(a.b, d.address.bytes, 20);
    u256 key = u256::from_be(d.key.bytes), v = u256::from_be(d.value.bytes);
    BaseAccount* acc = find_account(a);
    if (v.is_zero()) {
      // Clearing a slot may empty the storage root; has_storage would then be unknown.
      if (!acc || acc->has_storage) return false;
    } else if (acc && !acc->has_storage) {
      acc->has_storage = 1;
      if (!full) dirty_acc.push_back((uint32_t)(acc - accounts.data()));
    }
    BaseSlot* s = find_slot(a, key);
    uint32_t wl = s ? s->warm_lane : NO_LANE;
    put_slot(a, key, v, v, wl);
  }
  return true;
}

void StateCache::evict(uint64_t target) {
  // Live entries by recency, newest first.
  std::vector<uint32_t> ai, si;
  for (uint32_t i = 0; i < accounts.size(); i++)
    if (live(accounts[i])) ai.push_back(i);
  for (uint32_t i = 0; i < slots.size(); i++)
    if (live(slots[i])) si.push_back(i);
  std::sort(ai.begin(), ai.end(), [&](uint32_t x, uint32_t y) { return acc_lru[x] > acc_lru[y]; });
  std::sort(si.begin(), si.end(), [&](uint32_t x, uint32_t y) { return slot_lru[x] > slot_lru[y]; });
  // Code recency: its own last use or that of a live account running it.
  std::unordered_map<Loc, std::string> key_of;
  for (auto& kv : code_by_hash) key_of.emplace(kv.second.code, kv.first);
  for (uint32_t i : ai) {
    const BaseAccount& e = accounts[i];
    if (e.code_loc == LOC_NONE) continue;
    auto it = key_of.find(e.code_loc);
    if (it != key_of.end()) {
      CodeEnt& ce = code_by_hash[it->second];
      ce.last = std::max(ce.last, acc_lru[i]);
    }
  }
  std::vector<std::pair<std::string, CodeEnt>> codes(code_by_hash.begin(), code_by_hash.end());
  std::sort(codes.begin(), codes.end(), [](auto& x, auto& y) { return x.second.last > y.second.last; });

  // Keep the newest fraction f of every table, halving f until the result fits.
  size_t keep_a = 0, keep_s = 0, keep_c = 0;
  for (double f = 0.5;; f /= 2) {
    keep_a = (size_t)(ai.size() * f);
    keep_s = (size_t)(si.size() * f);
    keep_c = (size_t)(codes.size() * f);
    uint64_t cb = 8;
    for (size_t k = 0; k < keep_c; k++) cb += codes[k].second.len + (codes[k].second.len + 7) / 8 + 17;
    uint64_t tb = std::max(kMinAcc, pow2_ceil(keep_a * 2)) * (sizeof(BaseAccount) + 4) +
                  std::max(kMinSlot, pow2_ceil(keep_s * 2)) * (sizeof(BaseSlot) + 4) + bh.size() * sizeof(BaseBlockHash);
    if (tb + cb <= target || f < 1.0 / 1024) break;
  }

  // Rebuild the code region with the kept code, remapping locations.
  std::unordered_map<Loc, std::pair<Loc, Loc>> remap;  // old code loc -> new (code, jd)
  std::vector<uint8_t> old_code;
  old_code.swap(code);
  code.resize(8, 0);
  std::unordered_map<std::string, CodeEnt> old_map;
  old_map.swap(code_by_hash);
  for (size_t k = 0; k < keep_c; k++) {
    const CodeEnt& ce = codes[k].second;
    Loc jd;
    Loc cl = add_code((const uint8_t*)codes[k].first.data(), old_code.data() + (ce.code & ~LOC_CODE), ce.len, &jd);
    code_by_hash[codes[k].first].last = ce.last;
    remap.emplace(ce.code, std::make_pair(cl, jd));
  }

  std::vector<BaseAccount> old_acc;
  old_acc.swap(accounts);
  std::vector<uint32_t> old_alru;
  old_alru.swap(acc_lru);
  accounts.assign(std::max(kMinAcc, pow2_ceil(keep_a * 2)), BaseAccount{});
  acc_lru.assign(accounts.size(), 0);
  n_acc = 0;
  uint64_t mask = accounts.size() - 1;
  for (size_t k = 0; k < keep_a; k++) {
    BaseAccount e = old_acc[ai[k]];
    if (e.code_loc != LOC_NONE) {
      auto it = remap.find(e.code_loc);
      if (it == remap.end()) continue;  // its code was evicted
      e.code_loc = it->second.first;
      e.jd_loc = it->second.second;
    }
    uint64_t i = addr_hash(e.addr) & mask;
    while (accounts[i].used) i = (i + 1) & mask;
    accounts[i] = e;
    acc_lru[i] = old_alru[ai[k]];
    n_acc++;
  }

  std::vector<BaseSlot> old_slot;
  old_slot.swap(slots);
  std::vector<uint32_t> old_slru;
  old_slru.swap(slot_lru);
  slots.assign(std::max(kMinSlot, pow2_ceil(keep_s * 2)), BaseSlot{});
  slot_lru.assign(slots.size(), 0);
  n_slot = 0;
  mask = slots.size() - 1;
  for (size_t k = 0; k < keep_s; k++) {
    const BaseSlot& e = old_slot[si[k]];
    uint64_t i = slot_hash(e.addr, e.key) & mask;
    while (slots[i].used) i = (i + 1) & mask;
    slots[i] = e;
    slot_lru[i] = old_slru[si[k]];
    n_slot++;
  }

  dirty_acc.clear();
  dirty_slot.clear();
  dirty_bh.clear();
  full = true;
  code_synced = 0;
  evictions++;
}

BaseView StateCache::view(const uint8_t* blob_base, const uint8_t* code_base, uint32_t* acc_lru_base,
                          uint32_t* slot_lru_base) const {
  BaseView v;
  v.accounts = accounts.data();
  v.acc_mask = accounts.size() - 1;
  v.slots = slots.data();
  v.slot_mask = slots.size() - 1;
  v.bh = bh.data();
  v.bh_mask = bh.size() - 1;
  v.blob = blob_base;
  v.code = code_base;
  v.acc_lru = acc_lru_base;
  v.slot_lru = slot_lru_base;
  v.epoch = epoch;
  v.seq = seq;
  return v;
}

}  // namespace fevm
