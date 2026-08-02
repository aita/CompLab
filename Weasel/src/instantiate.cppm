// Instantiate partition — from a validated module to something that can run.
//
// Instantiation is where a module stops being a description. It is also the only
// place where an error can be *neither* a validation failure *nor* a trap in the
// program: an active data segment that does not fit its memory is a fault of the
// module, discovered at a moment when nothing of the module is running yet. The
// spec's answer is that instantiation fails, and any memory already written
// stays written — which is why the segments are copied last, after everything
// that can be checked has been.
export module weasel:instantiate;

import std;
import :common;
import :opcode;
import :types;
import :validate;
import :store;
import :exec;

export namespace weasel {

// A module and its plans, kept together because the plans point into neither —
// they are indexed by the module's own function order, and the instance points
// at them.
struct LoadedModule {
  Module module;
  std::vector<Code> codes;
};

}  // namespace weasel

namespace weasel {

// The five instructions a constant expression can contain, evaluated against the
// instance being built. Everything it may read — an imported global, a function
// of this module — is already in place by the time this runs.
bool eval_const(const Expr& e, Store& store, const Instance& inst, Value& out,
                Diag& d) {
  Value v{};
  for (const Inst& in : e) {
    switch (in.op) {
      case Op::I32Const: case Op::I64Const:
      case Op::F32Const: case Op::F64Const:
        v = Value{in.imm};
        break;
      case Op::RefNull:
        v = Value::null_ref();
        break;
      case Op::RefFunc:
        v = Value::of_ref(inst.funcs[in.a]);
        break;
      case Op::GlobalGet:
        v = store.globals[inst.globals[in.a]].value;
        break;
      case Op::End:
        break;
      default:
        d.fail(std::format("`{}` in a constant expression", op_name(in.op)));
        return false;
    }
  }
  out = v;
  return true;
}

// An import is satisfied when what the host offers is at least what the module
// asked for. For limits that means "no smaller a minimum, no larger a maximum",
// which is the direction that keeps every bounds check the module was validated
// against still true.
bool limits_match(const Limits& have, const Limits& want) {
  if (have.min < want.min) return false;
  if (!want.has_max) return true;
  if (!have.has_max) return false;
  return have.max <= want.max;
}

}  // namespace weasel

export namespace weasel {

// Instantiate `lm` against `linker`, adding everything it allocates to `store`.
// On success the new instance is owned by the store and returned.
Instance* instantiate(Store& store, const Linker& linker, const LoadedModule& lm,
                      std::string name, Diag& d) {
  const Module& m = lm.module;

  auto owned = std::make_unique<Instance>();
  Instance* inst = owned.get();
  inst->module = &m;
  inst->codes = &lm.codes;
  inst->name = std::move(name);

  // ---- imports -------------------------------------------------------------
  for (const Import& im : m.imports) {
    const Extern* e = linker.find(im.module, im.name);
    if (!e) {
      d.fail(std::format("unresolved import {}.{}", im.module, im.name));
      return nullptr;
    }
    if (e->kind != im.kind) {
      d.fail(std::format("import {}.{} is a {}, not a {}", im.module, im.name,
                         kind_name(e->kind), kind_name(im.kind)));
      return nullptr;
    }
    switch (im.kind) {
      case ExternKind::Func: {
        const FuncType& want = m.types[im.type_index];
        if (store.funcs[e->addr].type != want) {
          d.fail(std::format("import {}.{} has the wrong signature", im.module, im.name));
          return nullptr;
        }
        inst->funcs.push_back(e->addr);
        break;
      }
      case ExternKind::Table: {
        const TableInst& t = store.tables[e->addr];
        Limits have{static_cast<u32>(t.elems.size()), t.max, t.has_max};
        if (t.type != im.table.elem || !limits_match(have, im.table.limits)) {
          d.fail(std::format("import {}.{} is not the table asked for", im.module, im.name));
          return nullptr;
        }
        inst->tables.push_back(e->addr);
        break;
      }
      case ExternKind::Memory: {
        const MemInst& mi = store.mems[e->addr];
        Limits have{mi.pages(), mi.max_pages, mi.has_max};
        if (!limits_match(have, im.mem.limits)) {
          d.fail(std::format("import {}.{} is not the memory asked for", im.module, im.name));
          return nullptr;
        }
        inst->mems.push_back(e->addr);
        break;
      }
      case ExternKind::Global: {
        const GlobalInst& g = store.globals[e->addr];
        if (g.type.type != im.global.type || g.type.is_mutable != im.global.is_mutable) {
          d.fail(std::format("import {}.{} is not the global asked for", im.module, im.name));
          return nullptr;
        }
        inst->globals.push_back(e->addr);
        break;
      }
    }
  }

  // ---- this module's own definitions ---------------------------------------
  // Functions first: a global initialiser or an element segment may hold
  // `ref.func`, and a reference has to point at something that exists.
  for (u32 i = 0; i < m.funcs.size(); ++i) {
    FuncInst fi;
    fi.type = m.types[m.funcs[i].type];
    fi.instance = inst;
    fi.code = &lm.codes[i];
    fi.module_index = m.imported_funcs + i;
    inst->funcs.push_back(store.add_func(std::move(fi)));
  }
  for (const TableType& tt : m.tables) {
    TableInst t;
    t.type = tt.elem;
    t.max = tt.limits.has_max ? tt.limits.max : 0xffffffffu;
    t.has_max = tt.limits.has_max;
    t.elems.assign(tt.limits.min, Value::null_ref());
    inst->tables.push_back(store.add_table(std::move(t)));
  }
  for (const MemType& mt : m.mems) {
    MemInst mi;
    mi.max_pages = mt.limits.has_max ? mt.limits.max : kMaxPages;
    mi.has_max = mt.limits.has_max;
    mi.bytes.assign(static_cast<std::size_t>(mt.limits.min) * kPageSize, 0);
    inst->mems.push_back(store.add_mem(std::move(mi)));
  }
  for (const Global& g : m.globals) {
    Value v{};
    if (!eval_const(g.init, store, *inst, v, d)) return nullptr;
    inst->globals.push_back(store.add_global(GlobalInst{v, g.type}));
  }

  // ---- segments ------------------------------------------------------------
  // Every segment's contents are computed first, and every active segment's
  // bounds are checked, before a single byte is written. That is not what the
  // spec requires, but it is what makes a failed instantiation leave a store
  // that nothing else has to know about.
  inst->elems.resize(m.elems.size());
  inst->elem_dropped.assign(m.elems.size(), false);
  std::vector<std::pair<u32, u32>> elem_writes(m.elems.size(), {0, 0});
  for (u32 i = 0; i < m.elems.size(); ++i) {
    const ElemSeg& seg = m.elems[i];
    auto& vals = inst->elems[i];
    vals.resize(seg.init.size());
    for (u32 j = 0; j < seg.init.size(); ++j)
      if (!eval_const(seg.init[j], store, *inst, vals[j], d)) return nullptr;
    if (seg.mode != SegMode::Active) continue;
    Value off{};
    if (!eval_const(seg.offset, store, *inst, off, d)) return nullptr;
    const TableInst& t = store.tables[inst->tables[seg.table]];
    if (u64{off.i32()} + vals.size() > t.elems.size()) {
      d.fail(std::format("element segment {} does not fit table {}", i, seg.table));
      return nullptr;
    }
    elem_writes[i] = {seg.table, off.i32()};
  }

  inst->datas.resize(m.datas.size());
  inst->data_dropped.assign(m.datas.size(), false);
  std::vector<std::pair<u32, u32>> data_writes(m.datas.size(), {0, 0});
  for (u32 i = 0; i < m.datas.size(); ++i) {
    const DataSeg& seg = m.datas[i];
    inst->datas[i] = seg.bytes;
    if (seg.mode != SegMode::Active) continue;
    Value off{};
    if (!eval_const(seg.offset, store, *inst, off, d)) return nullptr;
    const MemInst& mi = store.mems[inst->mems[seg.mem]];
    if (u64{off.i32()} + seg.bytes.size() > mi.bytes.size()) {
      d.fail(std::format("data segment {} does not fit memory {}", i, seg.mem));
      return nullptr;
    }
    data_writes[i] = {seg.mem, off.i32()};
  }

  for (u32 i = 0; i < m.elems.size(); ++i) {
    if (m.elems[i].mode == SegMode::Active) {
      auto [table, off] = elem_writes[i];
      TableInst& t = store.tables[inst->tables[table]];
      for (u32 j = 0; j < inst->elems[i].size(); ++j) t.elems[off + j] = inst->elems[i][j];
    }
    // An active segment is spent the moment it is copied, and a declarative one
    // was never anything but a promise to the validator.
    if (m.elems[i].mode != SegMode::Passive) {
      inst->elems[i].clear();
      inst->elem_dropped[i] = true;
    }
  }
  for (u32 i = 0; i < m.datas.size(); ++i) {
    if (m.datas[i].mode == SegMode::Active) {
      auto [memi, off] = data_writes[i];
      MemInst& mi = store.mems[inst->mems[memi]];
      if (!inst->datas[i].empty())
        std::memcpy(mi.bytes.data() + off, inst->datas[i].data(), inst->datas[i].size());
      inst->datas[i].clear();
      inst->data_dropped[i] = true;
    }
  }

  store.instances.push_back(std::move(owned));

  // ---- start ---------------------------------------------------------------
  if (m.start) {
    Machine machine(store);
    std::vector<Value> results;
    if (!machine.invoke(inst->funcs[*m.start], {}, results)) {
      d.fail(std::format("the start function trapped: {}", machine.trap_text()));
      return nullptr;
    }
  }
  return inst;
}

}  // namespace weasel
