// The module. Everything the embedder needs is re-exported from here, plus the
// one function that joins the partitions: bytes in, something runnable out.
export module weasel;

export import :common;
export import :opcode;
export import :types;
export import :binary;
export import :text;
export import :validate;
export import :store;
export import :instantiate;
export import :exec;
export import :wasi;
export import :host;
export import :dump;

import std;

export namespace weasel {

// A `.wasm` starts with a NUL; a `.wat` cannot, so the two need no file
// extension to tell them apart.
inline bool looks_binary(std::span<const u8> bytes) {
  return bytes.size() >= 4 && bytes[0] == 0x00 && bytes[1] == 'a' && bytes[2] == 's' &&
         bytes[3] == 'm';
}

// Read a module in either format and validate it. The plans come back inside
// `out`, which the instance will point into, so `out` has to outlive the store.
inline bool load(std::span<const u8> bytes, LoadedModule& out, Diag& d) {
  if (looks_binary(bytes)) {
    if (!decode_module(bytes, out.module, d)) return false;
  } else {
    std::string_view text(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    if (!parse_text(text, out.module, d)) return false;
  }
  return validate(out.module, out.codes, d);
}

inline std::optional<std::vector<u8>> read_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) return std::nullopt;
  std::vector<u8> bytes((std::istreambuf_iterator<char>(in)),
                        std::istreambuf_iterator<char>());
  return bytes;
}

}  // namespace weasel
