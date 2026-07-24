// Regalloc partition — linear-scan register allocation (Poletto & Sarkar),
// a port of minpython/jit/regalloc.py, shared by both function compilers.
//
// The caller builds the live intervals over whatever value space it has -- the
// integer method compiler uses a function's VM registers -- and hands the list
// here. This module is just the scan: it knows nothing about that value space
// or the concrete register set. Registers are abstract indices [0, n_regs), and
// the caller maps them to real machine registers.
module;

export module minpython:regalloc;

import std;

export namespace minpython {

// A value lives in register index `reg` (>=0) or spill slot `spill` (>=0);
// exactly one is set.
struct Loc {
  int reg = -1;
  int spill = -1;
  bool in_reg() const { return reg >= 0; }
};

// A value's live range [start, end] and the key (slot / SSA ref) it belongs to.
struct Interval {
  int start;
  int end;
  int key;
};

struct Alloc {
  std::unordered_map<int, Loc> loc;
  std::vector<int> used;  // register indices actually used (sorted)
  int n_spill = 0;
};

// Assign each interval's key a register index or a spill slot. Expiry uses `<=`,
// so a value whose last use is at an instruction may hand its register to that
// instruction's result -- which is what lets codegen emit the two-address form.
inline Alloc linear_scan(std::vector<Interval> intervals, int n_regs) {
  std::sort(intervals.begin(), intervals.end(), [](const Interval& a,
                                                   const Interval& b) {
    if (a.start != b.start) return a.start < b.start;
    if (a.end != b.end) return a.end < b.end;
    return a.key < b.key;
  });

  Alloc out;
  std::vector<int> free;
  for (int r = n_regs - 1; r >= 0; --r) free.push_back(r);  // pop from back
  std::vector<std::pair<int, int>> active;  // (end, key), kept sorted by end
  std::unordered_set<int> used;

  auto spill_slot = [&]() { return out.n_spill++; };
  auto sort_active = [&]() {
    std::sort(active.begin(), active.end());  // by (end, key)
  };

  for (const Interval& iv : intervals) {
    // Expire intervals that ended before this one starts; reclaim their regs.
    std::vector<std::pair<int, int>> keep;
    for (auto& a : active) {
      if (a.first <= iv.start) {
        const Loc& l = out.loc[a.second];
        if (l.in_reg()) free.push_back(l.reg);
      } else {
        keep.push_back(a);
      }
    }
    active = std::move(keep);

    if (!free.empty()) {
      int reg = free.back();
      free.pop_back();
      out.loc[iv.key] = Loc{reg, -1};
      used.insert(reg);
      active.push_back({iv.end, iv.key});
    } else if (active.empty()) {
      out.loc[iv.key] = Loc{-1, spill_slot()};  // no registers at all
    } else {
      sort_active();
      auto furthest = active.back();
      if (furthest.first > iv.end) {
        out.loc[iv.key] = out.loc[furthest.second];        // steal its register
        out.loc[furthest.second] = Loc{-1, spill_slot()};
        active.back() = {iv.end, iv.key};
      } else {
        out.loc[iv.key] = Loc{-1, spill_slot()};
      }
    }
    sort_active();
  }

  out.used.assign(used.begin(), used.end());
  std::sort(out.used.begin(), out.used.end());
  return out;
}

}  // namespace minpython
