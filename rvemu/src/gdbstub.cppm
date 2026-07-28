// Gdbstub partition — the GDB remote serial protocol, over a loopback socket.
//
// With this, `riscv64-unknown-elf-gdb prog` + `target remote :1234` gives you
// breakpoints, single stepping, backtraces, `print`, `x/`, and source-level
// debugging of a guest running inside rvemu. gdb brings its own disassembler and
// its own DWARF reader; all the stub owes it is registers, memory, and a stop
// reason.
//
// Three details are worth knowing about:
//
//   * Breakpoints are *not* implemented by patching ebreak into the guest. The
//     stub advertises Z0 support and keeps the addresses in a set that the run
//     loop checks, so guest text is never modified -- which matters here because
//     a compressed instruction is two bytes and the usual four-byte ebreak patch
//     would scribble over its neighbour.
//   * The register layout gdb sees is the one this file hands it in target.xml,
//     so the numbering is ours to define rather than ours to guess.
//   * ^C during `continue` arrives as a bare 0x03 byte outside any packet. There
//     is no second thread here; the run loop calls back into `poll_interrupt`
//     every so often, which is enough to notice it.
//
// The listening socket is bound to loopback deliberately. A debug stub is a
// remote read/write-anything primitive, and it has no business on a real
// interface.
module;

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdio.h>
#include <sys/socket.h>
#include <unistd.h>

export module rvemu:gdbstub;

import std;
import :common;
import :memory;
import :cpu;
import :decode;
import :exec;
import :elf;
import :syscall;
import :machine;

export namespace rvemu {

// The register numbering the stub publishes in target.xml.
//   0..31  x0..x31
//   32     pc
//   33..64 f0..f31
//   65     fflags   66  frm   67  fcsr
inline constexpr unsigned kRegPc = 32;
inline constexpr unsigned kRegF0 = 33;
inline constexpr unsigned kRegFflags = 65;
inline constexpr unsigned kGdbRegCount = 68;

class GdbStub {
 public:
  explicit GdbStub(Machine& m) : m_(m) {}

  ~GdbStub() {
    if (conn_ >= 0) ::close(conn_);
    if (server_ >= 0) ::close(server_);
  }

  // Open the port and block until a debugger connects.
  bool wait_for_debugger(int port, Diag& d) {
    server_ = ::socket(AF_INET, SOCK_STREAM, 0);
    if (server_ < 0) {
      d.fail(std::format("socket: {}", std::strerror(errno)));
      return false;
    }
    int one = 1;
    ::setsockopt(server_, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(static_cast<u16>(port));
    if (::bind(server_, reinterpret_cast<sockaddr*>(&addr), sizeof addr) < 0) {
      d.fail(std::format("bind to port {}: {}", port, std::strerror(errno)));
      return false;
    }
    if (::listen(server_, 1) < 0) {
      d.fail(std::format("listen: {}", std::strerror(errno)));
      return false;
    }
    std::print(stderr, "rvemu: waiting for gdb on 127.0.0.1:{}\n", port);
    std::print(stderr, "rvemu: (gdb) target remote :{}\n", port);

    do {
      conn_ = ::accept(server_, nullptr, nullptr);
    } while (conn_ < 0 && errno == EINTR);
    if (conn_ < 0) {
      d.fail(std::format("accept: {}", std::strerror(errno)));
      return false;
    }
    ::setsockopt(conn_, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);

    m_.poll_hook = [this] { poll_interrupt(); };
    return true;
  }

  // Serve packets until the guest exits or the debugger detaches. Returns the
  // process exit status.
  int serve() {
    std::string pkt;
    for (;;) {
      if (!read_packet(pkt)) {
        // The link dropped. Let the program finish on its own rather than
        // killing it halfway through.
        m_.poll_hook = nullptr;
        return detached_ ? m_.run() : 0;
      }
      if (!handle(pkt)) return exit_status_;
    }
  }

 private:
  Machine& m_;
  int server_ = -1;
  int conn_ = -1;
  bool no_ack_ = false;
  bool detached_ = false;
  int exit_status_ = 0;
  std::string inbuf_;

  // -- the wire --------------------------------------------------------------

  bool send_raw(std::string_view s) {
    while (!s.empty()) {
      const ssize_t n = ::send(conn_, s.data(), s.size(), MSG_NOSIGNAL);
      if (n < 0) {
        if (errno == EINTR) continue;
        return false;
      }
      s.remove_prefix(static_cast<std::size_t>(n));
    }
    return true;
  }

  static u8 checksum(std::string_view s) {
    u8 c = 0;
    for (char ch : s) c = static_cast<u8>(c + static_cast<u8>(ch));
    return c;
  }

  bool send_packet(std::string_view body) {
    const std::string out = std::format("${}#{:02x}", body, checksum(body));
    if (!send_raw(out)) return false;
    if (no_ack_) return true;
    // Wait for the '+'; a '-' means resend.
    for (;;) {
      char c = 0;
      if (!read_byte(c)) return false;
      if (c == '+') return true;
      if (c == '-') return send_raw(out);
      if (c == 0x03) m_.interrupt = true;
    }
  }

  bool read_byte(char& out) {
    if (!inbuf_.empty()) {
      out = inbuf_.front();
      inbuf_.erase(inbuf_.begin());
      return true;
    }
    char buf[512];
    for (;;) {
      const ssize_t n = ::recv(conn_, buf, sizeof buf, 0);
      if (n > 0) {
        inbuf_.assign(buf, buf + n);
        out = inbuf_.front();
        inbuf_.erase(inbuf_.begin());
        return true;
      }
      if (n < 0 && errno == EINTR) continue;
      return false;  // closed, or an error we cannot recover from
    }
  }

  // Read one `$...#xx` packet, acknowledging it. A bare 0x03 between packets is
  // gdb's interrupt request.
  bool read_packet(std::string& out) {
    for (;;) {
      char c = 0;
      if (!read_byte(c)) return false;
      if (c == 0x03) {
        m_.interrupt = true;
        continue;
      }
      if (c != '$') continue;

      out.clear();
      u8 sum = 0;
      for (;;) {
        if (!read_byte(c)) return false;
        if (c == '#') break;
        // `}` escapes the next byte, which is XORed with 0x20.
        if (c == '}') {
          sum = static_cast<u8>(sum + static_cast<u8>(c));
          if (!read_byte(c)) return false;
          sum = static_cast<u8>(sum + static_cast<u8>(c));
          out.push_back(static_cast<char>(c ^ 0x20));
          continue;
        }
        sum = static_cast<u8>(sum + static_cast<u8>(c));
        out.push_back(c);
      }
      char h1 = 0, h2 = 0;
      if (!read_byte(h1) || !read_byte(h2)) return false;
      const unsigned want = (unhex(h1) << 4) | unhex(h2);
      if (!no_ack_) {
        if (want != sum) {
          if (!send_raw("-")) return false;
          continue;
        }
        if (!send_raw("+")) return false;
      }
      return true;
    }
  }

  // Called from the run loop: notice a ^C without blocking.
  void poll_interrupt() {
    if (conn_ < 0) return;
    pollfd p{conn_, POLLIN, 0};
    if (::poll(&p, 1, 0) <= 0) return;
    char buf[64];
    const ssize_t n = ::recv(conn_, buf, sizeof buf, MSG_DONTWAIT);
    if (n <= 0) return;
    for (ssize_t i = 0; i < n; ++i) {
      if (buf[i] == 0x03) m_.interrupt = true;
      else inbuf_.push_back(buf[i]);
    }
  }

  // -- hex -------------------------------------------------------------------

  static unsigned unhex(char c) {
    if (c >= '0' && c <= '9') return unsigned(c - '0');
    if (c >= 'a' && c <= 'f') return unsigned(c - 'a' + 10);
    if (c >= 'A' && c <= 'F') return unsigned(c - 'A' + 10);
    return 0;
  }
  static std::string to_hex(const u8* p, std::size_t n) {
    std::string s;
    s.reserve(n * 2);
    for (std::size_t i = 0; i < n; ++i) s += std::format("{:02x}", p[i]);
    return s;
  }
  static std::vector<u8> from_hex(std::string_view s) {
    std::vector<u8> out;
    out.reserve(s.size() / 2);
    for (std::size_t i = 0; i + 1 < s.size(); i += 2) {
      out.push_back(static_cast<u8>((unhex(s[i]) << 4) | unhex(s[i + 1])));
    }
    return out;
  }
  // gdb writes addresses and lengths as plain hex, without a 0x.
  static u64 parse_hex(std::string_view s) {
    u64 v = 0;
    for (char c : s) {
      if (!std::isxdigit(static_cast<unsigned char>(c))) break;
      v = v * 16 + unhex(c);
    }
    return v;
  }

  // -- registers -------------------------------------------------------------

  // Every register is little-endian in the packet; the x/f registers are eight
  // bytes and the three float CSRs are four.
  std::string read_reg(unsigned n) {
    const Hart& h = m_.cpu.hart;
    if (n < 32) return to_hex(reinterpret_cast<const u8*>(&h.x[n]), 8);
    if (n == kRegPc) return to_hex(reinterpret_cast<const u8*>(&h.pc), 8);
    if (n >= kRegF0 && n < kRegF0 + 32) {
      return to_hex(reinterpret_cast<const u8*>(&h.f[n - kRegF0]), 8);
    }
    if (n == kRegFflags || n == kRegFflags + 1 || n == kRegFflags + 2) {
      const u32 v = (n == kRegFflags) ? h.fflags()
                    : (n == kRegFflags + 1) ? u32(h.frm())
                                            : (h.fcsr & 0xff);
      return to_hex(reinterpret_cast<const u8*>(&v), 4);
    }
    return "xxxxxxxxxxxxxxxx";  // "unavailable", which gdb understands
  }

  bool write_reg(unsigned n, std::span<const u8> b) {
    Hart& h = m_.cpu.hart;
    auto get64 = [&]() {
      u64 v = 0;
      std::memcpy(&v, b.data(), std::min<std::size_t>(b.size(), 8));
      return v;
    };
    if (n < 32) {
      if (n) h.x[n] = get64();
      return true;
    }
    if (n == kRegPc) {
      h.pc = get64();
      return true;
    }
    if (n >= kRegF0 && n < kRegF0 + 32) {
      h.f[n - kRegF0] = get64();
      return true;
    }
    if (n >= kRegFflags && n <= kRegFflags + 2) {
      u32 v = 0;
      std::memcpy(&v, b.data(), std::min<std::size_t>(b.size(), 4));
      if (n == kRegFflags) h.fcsr = (h.fcsr & ~0x1fu) | (v & 0x1f);
      else if (n == kRegFflags + 1) h.fcsr = (h.fcsr & 0x1fu) | ((v & 7) << 5);
      else h.fcsr = v & 0xff;
      return true;
    }
    return false;
  }

  std::string read_all_regs() {
    std::string s;
    for (unsigned i = 0; i < kGdbRegCount; ++i) s += read_reg(i);
    return s;
  }

  void write_all_regs(std::string_view hexdata) {
    const std::vector<u8> b = from_hex(hexdata);
    std::size_t off = 0;
    for (unsigned i = 0; i < kGdbRegCount && off < b.size(); ++i) {
      const std::size_t width = (i >= kRegFflags) ? 4u : 8u;
      if (off + width > b.size()) break;
      write_reg(i, std::span<const u8>(b.data() + off, width));
      off += width;
    }
  }

  // -- target description ----------------------------------------------------

  static const std::string& target_xml() {
    static const std::string xml = [] {
      std::string s =
          "<?xml version=\"1.0\"?>\n"
          "<!DOCTYPE target SYSTEM \"gdb-target.dtd\">\n"
          "<target version=\"1.0\">\n"
          "  <architecture>riscv:rv64</architecture>\n"
          "  <feature name=\"org.gnu.gdb.riscv.cpu\">\n";
      for (unsigned i = 0; i < 32; ++i) {
        // ra and pc are code pointers and sp/s0 data pointers, which is what
        // lets gdb unwind and print frames sensibly.
        const char* type = (i == 1) ? "code_ptr" : (i == 2 || i == 8) ? "data_ptr" : "int";
        s += std::format(
            "    <reg name=\"{}\" bitsize=\"64\" type=\"{}\" regnum=\"{}\"/>\n",
            kXRegNames[i], type, i);
      }
      s += std::format(
          "    <reg name=\"pc\" bitsize=\"64\" type=\"code_ptr\" regnum=\"{}\"/>\n",
          kRegPc);
      s += "  </feature>\n  <feature name=\"org.gnu.gdb.riscv.fpu\">\n";
      for (unsigned i = 0; i < 32; ++i) {
        s += std::format(
            "    <reg name=\"{}\" bitsize=\"64\" type=\"ieee_double\" regnum=\"{}\"/>\n",
            kFRegNames[i], kRegF0 + i);
      }
      for (unsigned i = 0; i < 3; ++i) {
        static constexpr const char* kNames[3] = {"fflags", "frm", "fcsr"};
        s += std::format(
            "    <reg name=\"{}\" bitsize=\"32\" type=\"int\" regnum=\"{}\"/>\n",
            kNames[i], kRegFflags + i);
      }
      s += "  </feature>\n</target>\n";
      return s;
    }();
    return xml;
  }

  // qXfer replies are chunked: `m` for "more follows", `l` for the last piece.
  bool send_xfer(const std::string& doc, u64 offset, u64 length) {
    if (offset >= doc.size()) return send_packet("l");
    const u64 n = std::min<u64>(length, doc.size() - offset);
    std::string body = "m";
    if (offset + n >= doc.size()) body = "l";
    body += doc.substr(offset, n);
    return send_packet(body);
  }

  // -- stop replies ----------------------------------------------------------

  bool report(Event e) {
    switch (e) {
      case Event::Exited:
        exit_status_ = m_.kernel.exit_code;
        send_packet(std::format("W{:02x}", exit_status_ & 0xff));
        return true;
      case Event::Breakpoint: {
        // Tell gdb it was our breakpoint when it was, so it does not go looking
        // for a patched instruction it never wrote.
        const bool ours = m_.breakpoints.contains(m_.cpu.hart.pc);
        send_packet(ours ? "T05thread:1;swbreak:;" : "T05thread:1;");
        return true;
      }
      case Event::Stepped:
        send_packet("T05thread:1;");
        return true;
      case Event::Fault:
        std::print(stderr, "rvemu: {}\n", m_.last_error);
        send_packet("T0bthread:1;");  // SIGSEGV
        return true;
      case Event::Illegal:
        std::print(stderr, "rvemu: {}\n", m_.last_error);
        send_packet("T04thread:1;");  // SIGILL
        return true;
      case Event::Interrupted:
        send_packet("T02thread:1;");  // SIGINT
        return true;
      case Event::Limit:
        send_packet("T05thread:1;");
        return true;
    }
    return true;
  }

  // -- packet dispatch -------------------------------------------------------

  // Returns false when the session is over.
  bool handle(const std::string& p) {
    if (p.empty()) return send_packet("");

    switch (p[0]) {
      case '?':
        // The initial stop: we are sitting at the entry point.
        return send_packet("T05thread:1;");

      case 'g':
        return send_packet(read_all_regs());
      case 'G':
        write_all_regs(std::string_view(p).substr(1));
        return send_packet("OK");

      case 'p': {
        const unsigned n = static_cast<unsigned>(parse_hex(std::string_view(p).substr(1)));
        return send_packet(read_reg(n));
      }
      case 'P': {
        const auto eq = p.find('=');
        if (eq == std::string::npos) return send_packet("E01");
        const unsigned n =
            static_cast<unsigned>(parse_hex(std::string_view(p).substr(1, eq - 1)));
        const std::vector<u8> b = from_hex(std::string_view(p).substr(eq + 1));
        return send_packet(write_reg(n, b) ? "OK" : "E01");
      }

      case 'm': {
        const auto comma = p.find(',');
        if (comma == std::string::npos) return send_packet("E01");
        const u64 addr = parse_hex(std::string_view(p).substr(1, comma - 1));
        const u64 len = parse_hex(std::string_view(p).substr(comma + 1));
        std::vector<u8> buf;
        buf.reserve(len);
        for (u64 i = 0; i < len; ++i) {
          u8 byte = 0;
          // Byte at a time: gdb reads speculatively past the end of mappings all
          // the time, and a short read is a better answer than an error.
          if (!m_.cpu.mem.peek(addr + i, &byte, 1)) break;
          buf.push_back(byte);
        }
        if (buf.empty() && len) return send_packet("E14");
        return send_packet(to_hex(buf.data(), buf.size()));
      }
      case 'M': {
        const auto comma = p.find(',');
        const auto colon = p.find(':');
        if (comma == std::string::npos || colon == std::string::npos) {
          return send_packet("E01");
        }
        const u64 addr = parse_hex(std::string_view(p).substr(1, comma - 1));
        const std::vector<u8> data = from_hex(std::string_view(p).substr(colon + 1));
        // poke, not write: gdb is allowed to patch read-only text.
        return send_packet(m_.cpu.mem.poke(addr, data.data(), data.size()) ? "OK" : "E14");
      }
      case 'X': {
        const auto comma = p.find(',');
        const auto colon = p.find(':');
        if (comma == std::string::npos || colon == std::string::npos) {
          return send_packet("E01");
        }
        const u64 addr = parse_hex(std::string_view(p).substr(1, comma - 1));
        const std::string_view raw = std::string_view(p).substr(colon + 1);
        // read_packet already undid the `}` escaping.
        return send_packet(m_.cpu.mem.poke(addr, raw.data(), raw.size()) ? "OK" : "E14");
      }

      case 'c':
      case 'C':
        return report(m_.resume(false));
      case 's':
      case 'S':
        return report(m_.resume(true));

      case 'v':
        return v_packet(p);

      case 'Z':
      case 'z': {
        // Z<type>,<addr>,<kind>
        if (p.size() < 4) return send_packet("E01");
        const char type = p[1];
        const auto first = p.find(',');
        if (first == std::string::npos) return send_packet("E01");
        const auto second = p.find(',', first + 1);
        const u64 addr = parse_hex(
            std::string_view(p).substr(first + 1, second - first - 1));
        if (type != '0' && type != '1') {
          // Watchpoints would need a hook on every load and store; gdb falls
          // back to single-stepping them, which works and is only slow.
          return send_packet("");
        }
        if (p[0] == 'Z') m_.breakpoints.insert(addr);
        else m_.breakpoints.erase(addr);
        return send_packet("OK");
      }

      case 'H':  // "operate on thread N" -- there is one
        return send_packet("OK");
      case 'q':
        return q_packet(p);
      case 'Q':
        if (p == "QStartNoAckMode") {
          if (!send_packet("OK")) return false;
          no_ack_ = true;
          return true;
        }
        return send_packet("");

      case 'D':  // detach: let the program run to completion
        send_packet("OK");
        detached_ = true;
        return false;
      case 'k':  // kill
        exit_status_ = 0;
        return false;

      default:
        return send_packet("");  // "unsupported", which is always a valid answer
    }
  }

  bool v_packet(const std::string& p) {
    if (p.starts_with("vCont?")) return send_packet("vCont;c;C;s;S");
    if (p.starts_with("vCont;")) {
      // Only one thread, so the first action is the only one that matters.
      const char action = p.size() > 6 ? p[6] : 'c';
      return report(m_.resume(action == 's' || action == 'S'));
    }
    if (p.starts_with("vKill")) {
      send_packet("OK");
      return false;
    }
    if (p.starts_with("vMustReplyEmpty")) return send_packet("");
    return send_packet("");
  }

  bool q_packet(const std::string& p) {
    if (p.starts_with("qSupported")) {
      return send_packet(
          "PacketSize=4000;qXfer:features:read+;swbreak+;vContSupported+;"
          "QStartNoAckMode+");
    }
    if (p.starts_with("qXfer:features:read:")) {
      // qXfer:features:read:<annex>:<offset>,<length>
      const auto colon = p.find(':', 20);
      if (colon == std::string::npos) return send_packet("E00");
      const std::string annex = p.substr(20, colon - 20);
      const auto comma = p.find(',', colon);
      const u64 offset = parse_hex(std::string_view(p).substr(colon + 1, comma - colon - 1));
      const u64 length = parse_hex(std::string_view(p).substr(comma + 1));
      if (annex != "target.xml") return send_packet("E00");
      return send_xfer(target_xml(), offset, length);
    }
    if (p == "qC") return send_packet("QC1");
    if (p == "qfThreadInfo") return send_packet("m1");
    if (p == "qsThreadInfo") return send_packet("l");
    if (p.starts_with("qAttached")) return send_packet("0");  // we started it
    if (p.starts_with("qSymbol")) return send_packet("OK");
    if (p.starts_with("qTStatus")) return send_packet("");
    if (p.starts_with("qOffsets")) return send_packet("Text=0;Data=0;Bss=0");
    return send_packet("");
  }
};

}  // namespace rvemu
