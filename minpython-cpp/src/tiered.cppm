// Async method JIT partition — the method JIT, compiled on a background thread.
//
// Python has a two-tier setup (a fast copy-and-patch baseline, then a register-
// allocating tier) because emitting bytes from Python is slow, so a cheap
// baseline earns its keep. In C++ the register allocator (method.cppm / xbyak)
// already compiles in microseconds, so a baseline tier only ever runs slower
// code for no compile-latency gain -- it was benchmarked and dropped. What
// remains worth keeping is the *background compilation* shape of the free-
// threaded retarget: when a function gets hot the driver submits a compile job
// and keeps interpreting -- it never blocks. When the job finishes it installs
// the native code under a lock and the next call picks it up.
//
// Replaced code is retired, not freed, so a native frame still running it can
// never be pulled out from under. Only the main thread runs native code and GC;
// the worker touches only the immutable CodeObject, so nothing races.
module;
#define XBYAK_NO_EXCEPTION
#include "xbyak/xbyak.h"

export module minpython:tiered;

import std;
import :value;
import :bytecode;
import :method;
import :vm;

export namespace minpython {

class TieredJIT {
 public:
  explicit TieredJIT(VM& vm, int threshold = 10)
      : vm_(vm), threshold_(threshold) {
    worker_ = std::thread([this] { worker_loop(); });
    vm_.on_call = [this](const Value& callee, Value* regs,
                         int arg_base, int argc, Value& out) -> bool {
      return on_call(callee, regs, arg_base, argc, out);
    };
  }

  ~TieredJIT() {
    {
      std::unique_lock lk(q_mtx_);
      stop_ = true;
    }
    q_cv_.notify_all();
    if (worker_.joinable()) worker_.join();
  }

  int n_compiled = 0;
  int n_calls_native = 0;

 private:
  struct Entry {
    std::unique_ptr<MethodCode> code;
    void* fn;
    int argc;
  };
  struct Job {
    const CodeObject* code = nullptr;
    int argc = 0;
  };

  bool on_call(const Value& callee, Value* regs, int arg_base,
               int argc, Value& out) {
    const CodeObject* code = callee.obj->code;

    void* fn = nullptr;
    {
      std::unique_lock lk(install_mtx_);
      auto it = compiled_.find(code);
      if (it != compiled_.end()) fn = it->second.fn;
    }

    if (!fn) {  // not ready: schedule once, keep interpreting meanwhile
      if (!blacklist_.count(code) && !submitted_.count(code)) {
        if (++counts_[code] >= threshold_) {
          if (mdetail::feasible(*code, 6)) submit(code, argc);
          else blacklist_.insert(code);
        }
      }
      return false;
    }

    // native path: int-only entry guard, then unbox and call
    for (int i = 0; i < argc; ++i)
      if (!regs[arg_base + i].is_int_like()) return false;  // deopt
    std::int64_t a[6] = {0};
    for (int i = 0; i < argc; ++i) a[i] = regs[arg_base + i].i;
    out = Value::integer(call_native(fn, argc, a));
    n_calls_native++;
    return true;
  }

  void submit(const CodeObject* code, int argc) {
    submitted_.insert(code);
    {
      std::unique_lock lk(q_mtx_);
      jobs_.push_back({code, argc});
    }
    q_cv_.notify_one();
  }

  void worker_loop() {
    while (true) {
      Job job;
      {
        std::unique_lock lk(q_mtx_);
        q_cv_.wait(lk, [this] { return stop_ || !jobs_.empty(); });
        if (stop_ && jobs_.empty()) return;
        job = jobs_.front();
        jobs_.pop_front();
      }
      auto reach = mdetail::feasible(*job.code, 6);
      if (!reach) continue;
      auto gen = std::make_unique<MethodCode>(*job.code, *reach, job.argc);
      if (Xbyak::GetError()) { Xbyak::ClearError(); continue; }
      void* fn = gen->entry_addr();
      std::unique_lock lk(install_mtx_);
      compiled_.emplace(job.code, Entry{std::move(gen), fn, job.argc});
      n_compiled++;
    }
  }

  VM& vm_;
  int threshold_;

  // main-thread-only state
  std::unordered_map<const void*, int> counts_;
  std::unordered_set<const void*> blacklist_;
  std::unordered_set<const void*> submitted_;

  // shared with the worker
  std::mutex install_mtx_;
  std::unordered_map<const void*, Entry> compiled_;

  std::mutex q_mtx_;
  std::condition_variable q_cv_;
  std::deque<Job> jobs_;
  bool stop_ = false;
  std::thread worker_;
};

}  // namespace minpython
