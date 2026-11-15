// Headless Verilator harness for the Laser 310 / VZ200 / VZ300 core.
//
//   make headless && ./obj_hl/Vemu --help
//
// No SDL / ImGui. Everything is driven from the command line so it can run
// in scripts and CI: screenshots, VRAM text dumps, RAM dumps, key injection,
// joystick, VZ snapshot download, cassette input from .cas/.wav, cassette and
// speaker output to WAV, CPU / IO / RAM-write logs, timing statistics and
// pass/fail expectations (exit status 1 when an --expect-* check fails).
//
// The emu stand-in is sim.v (not Laser310.sv); it maps `status` to SWITCH
// exactly like Laser310.sv does, so the OSD flags here mean the same thing
// as on MiSTer.

#include <verilated.h>
#include "Vemu.h"
#include "Vemu___024root.h"
#ifdef HL_TRACE
#include <verilated_fst_c.h>
#endif

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <map>
#include <deque>
#include <algorithm>
#include <chrono>
#include <ctime>
#include <unistd.h>
#include <libgen.h>
#include <limits.h>
#include <sys/stat.h>

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

using std::string;
using std::vector;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
static const double CLK_HZ = 42954545.0;   // clk_sys = clk_42 on MiSTer (12 x 3.579545)

// ---------------------------------------------------------------------------
// Verilated model + direct signal access (see sim_public.vlt)
// ---------------------------------------------------------------------------
static Vemu* top = nullptr;
#define R (top->rootp)
#define SIG(name) (R->emu__DOT__LASER310_TOP__DOT__##name)

vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------
struct FrameFile { long frame; string file; };
struct FrameText { long frame; string text; };
struct IoctlLoad { long frame; int index; string file; };
struct JoyEv     { long frame; int port; uint32_t mask; };
struct MemExpect { long frame; uint16_t addr; vector<uint8_t> bytes; };
struct HashExpect{ long frame; uint64_t hash; };
struct LatchExpect{ long frame; uint8_t val, mask; };

static struct Opts {
    long stop_frame = 300;
    bool quiet = false;
    uint32_t status = 0;
    vector<long> reset_frames;
    long reset_clocks = 2000;

    vector<long> shots; long shot_every = 0; bool shot_end = false;
    string shot_dir = "."; string shot_prefix = "frame";

    vector<FrameText> keys; int key_hold = 3; int key_gap = 3;
    vector<FrameText> holds;   // FRAME:KEYNAME:FRAMES
    vector<JoyEv> joys;

    vector<IoctlLoad> loads;
    string sysrom, dosrom;

    string tape_sd; long tape_mount_frame = 5; long sd_latency = 20000; vector<long> rewind_frames;
    string disk[2], disk_save[2]; long disk_frame[2] = {3, 4}; bool disk_ro[2] = {false, false};
    vector<std::pair<long,int>> expect_tape_hint; vector<std::pair<long,bool>> expect_bar;
    string tape; long tape_frame = -1; double tape_speed = 0; bool tape_invert = false;
    int tape_threshold = 1310; // +0.04 of full scale, like MAME vtech1.cpp
    string tape_out; string audio_out; int wav_rate = 44100;

    bool hash = false; vector<long> hash_at;
    vector<long> text_at; long text_every = 0; bool text_end = false;
    vector<FrameFile> dump_ram, dump_vram;
    vector<FrameText> expect_text, expect_notext;
    vector<MemExpect> expect_mem;
    vector<HashExpect> expect_hash;
    vector<LatchExpect> expect_latch;
    vector<std::pair<long,bool>> expect_hint;

    bool watch = false; uint16_t watch_lo = 0, watch_hi = 0;
    bool io_log = false;
    long cpu_log_from = -1, cpu_log_to = -1;
    vector<uint16_t> stop_pc; vector<uint16_t> break_pc;
    bool stats = false; bool stats_summary = false;
    long trace_from = -1, trace_to = -1; string trace_file = "trace.fst";
} O;

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------
static string g_cwd;
static string absPath(const string& p) {
    if (p.empty() || p[0] == '/') return p;
    return g_cwd + "/" + p;
}
static vector<uint8_t> readFile(const string& fn) {
    vector<uint8_t> v;
    FILE* f = fopen(fn.c_str(), "rb");
    if (!f) { fprintf(stderr, "error: cannot open %s\n", fn.c_str()); exit(2); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    v.resize(n); if (n && fread(v.data(), 1, n, f) != (size_t)n) { fprintf(stderr, "error: read %s\n", fn.c_str()); exit(2); }
    fclose(f); return v;
}
static string lower(string s) { for (auto& c : s) c = tolower(c); return s; }
static string ext(const string& fn) { auto p = fn.rfind('.'); return p == string::npos ? "" : lower(fn.substr(p + 1)); }
static bool splitFrame(const string& a, long& f, string& rest) {
    auto p = a.find(':'); if (p == string::npos) return false;
    f = strtol(a.substr(0, p).c_str(), nullptr, 0); rest = a.substr(p + 1); return true;
}
static vector<long> parseList(const string& s) {
    vector<long> v; size_t i = 0;
    while (i < s.size()) { size_t j = s.find(',', i); if (j == string::npos) j = s.size();
        v.push_back(strtol(s.substr(i, j - i).c_str(), nullptr, 0)); i = j + 1; }
    return v;
}
static void mkdirs(const string& d) { string cmd = "mkdir -p '" + d + "'"; if (system(cmd.c_str())) {} }

// ---------------------------------------------------------------------------
// Memory access (CPU view)
// ---------------------------------------------------------------------------
static uint8_t peek(uint16_t a) {
    if (a < 0x4000) return SIG(sys_rom__DOT__d)[a];
    if (a < 0x6000) return SIG(LATCHED_DOSROM_EN) ? SIG(DOS_ROM__DOT__d)[a & 0x1fff] : 0xff;
    if (a < 0x6800) return 0xff;
    if (a < 0x7000) return 0xff;                          // I/O latch / keyboard
    if (a < 0x7800) return SIG(vram_8k__DOT__mem)[((SIG(LATCHED_IO_SHRG) & 3) << 11) | (a & 0x7ff)];
    if (a < 0x8000) return SIG(BASE_RAM78__DOT__mem)[a & 0x7ff];
    if (a < 0xC000) return SIG(BASE_RAM16k__DOT__mem)[a & 0x3fff];
    return SIG(BASE_RAM16kex__DOT__mem)[a & 0x3fff];
}
static void writeBin(const string& fn, const vector<uint8_t>& v) {
    FILE* f = fopen(fn.c_str(), "wb"); if (!f) { fprintf(stderr, "error: write %s\n", fn.c_str()); return; }
    fwrite(v.data(), 1, v.size(), f); fclose(f);
}
static void dumpRam(const string& fn) {
    vector<uint8_t> v(65536); for (int a = 0; a < 65536; a++) v[a] = peek(a); writeBin(fn, v);
}
static void dumpVram(const string& fn) {
    vector<uint8_t> v(8192); for (int a = 0; a < 8192; a++) v[a] = SIG(vram_8k__DOT__mem)[a]; writeBin(fn, v);
}
static void loadRom(const string& fn, bool dos) {
    auto v = readFile(fn); size_t n = dos ? 0x2000 : 0x4000;
    if (v.size() < n) fprintf(stderr, "warning: %s is %zu bytes, expected %zu\n", fn.c_str(), v.size(), n);
    for (size_t i = 0; i < n && i < v.size(); i++) { if (dos) SIG(DOS_ROM__DOT__d)[i] = v[i]; else SIG(sys_rom__DOT__d)[i] = v[i]; }
}

// VZ text screen (32x16 at 7000h, VDG bank 0). MC6847 internal character set:
// 40-7F normal (the VZ ROM writes ASCII-ish codes with D6=1, D6 drives INV),
// 00-3F inverse (letters shown lower case), 80-FF SG4 blocks ('#', 80h = ' ').
static string screenText() {
    static const char* cs = "@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_ !\"#$%&'()*+,-./0123456789:;<=>?";
    string s;
    for (int r = 0; r < 16; r++) {
        string line;
        for (int c = 0; c < 32; c++) {
            uint8_t b = SIG(vram_8k__DOT__mem)[r * 32 + c];
            char ch;
            if (b & 0x80) ch = (b & 0x0f) ? '#' : ' ';
            else { ch = cs[b & 0x3f]; if (!(b & 0x40)) ch = tolower(ch); }   // VZ: D6 drives INV; normal text has D6=1
            line += ch;
        }
        while (!line.empty() && line.back() == ' ') line.pop_back();
        s += line + "\n";
    }
    return s;
}

// ---------------------------------------------------------------------------
// Video capture
// ---------------------------------------------------------------------------
struct Video {
    vector<uint32_t> cur, last;          // RGBA
    int x = 0, y = 0, maxx = 0, w = 0, h = 0, lw = 0, lh = 0;
    bool old_hb = true, line_has = false;
    void pixel(uint32_t rgba) {
        if (y >= 400 || x >= 1024) { x++; return; }
        if ((int)cur.size() < 1024 * 400) cur.resize(1024 * 400);
        cur[y * 1024 + x] = rgba; x++; line_has = true; if (x > maxx) maxx = x;
    }
    void endLine() { if (line_has) y++; x = 0; line_has = false; }
    void endFrame() {
        if (line_has) endLine();
        lw = maxx; lh = y; last.assign(lw * lh, 0);
        for (int j = 0; j < lh; j++) for (int i = 0; i < lw; i++) last[j * lw + i] = cur[j * 1024 + i];
        x = y = maxx = 0;
    }
    uint64_t hash() const {
        uint64_t hsh = 1469598103934665603ULL;
        for (auto p : last) { for (int k = 0; k < 3; k++) { hsh ^= (p >> (8 * k)) & 0xff; hsh *= 1099511628211ULL; } }
        return hsh;
    }
    void png(const string& fn) const {
        if (!lw || !lh) { fprintf(stderr, "warning: no picture for %s\n", fn.c_str()); return; }
        stbi_write_png(fn.c_str(), lw, lh, 4, last.data(), lw * 4);
    }
} V;

// ---------------------------------------------------------------------------
// WAV writer (mono, 8 or 16 bit)
// ---------------------------------------------------------------------------
struct WavOut {
    FILE* f = nullptr; int rate = 44100, bits = 16; uint32_t n = 0;
    bool open(const string& fn, int r, int b) {
        f = fopen(fn.c_str(), "wb"); if (!f) return false; rate = r; bits = b;
        uint8_t hdr[44] = {0}; fwrite(hdr, 1, 44, f); return true;
    }
    void put(int16_t s) {
        if (!f) return;
        if (bits == 8) { uint8_t u = (uint8_t)((s >> 8) + 128); fputc(u, f); }
        else { fputc(s & 0xff, f); fputc((s >> 8) & 0xff, f); }
        n++;
    }
    static void w32(uint8_t* p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
    void close() {
        if (!f) return;
        uint32_t bps = bits / 8, data = n * bps; uint8_t h[44];
        memcpy(h, "RIFF", 4); w32(h + 4, 36 + data); memcpy(h + 8, "WAVEfmt ", 8); w32(h + 16, 16);
        h[20] = 1; h[21] = 0; h[22] = 1; h[23] = 0; w32(h + 24, rate); w32(h + 28, rate * bps);
        h[32] = bps; h[33] = 0; h[34] = bits; h[35] = 0; memcpy(h + 36, "data", 4); w32(h + 40, data);
        fseek(f, 0, SEEK_SET); fwrite(h, 1, 44, f); fclose(f); f = nullptr;
    }
};

// ---------------------------------------------------------------------------
// Tape input: a sampled signal (signed 16-bit) at some rate
// ---------------------------------------------------------------------------
struct Tape {
    vector<int16_t> s; double rate = 3600; bool loaded = false, playing = false, ended = false;
    double pos_clocks = 0;   // clocks since play started (scaled by speed)

    // MAME vt_cas.cpp (vtech1): 3600 Hz, each bit = 6 samples, MSB first.
    void fromCas(const vector<uint8_t>& d) {
        rate = 600 * 6; s.clear();
        const int16_t HI = 32767, LO = -32768;
        for (int i = 0; i < 8000; i++) s.push_back(0);        // leading silence
        bool nullbyte = false;
        for (uint8_t b : d) {
            for (int i = 7; i >= 0; i--) {
                s.push_back(HI); s.push_back(LO);
                if ((b >> i) & 1) { s.push_back(HI); s.push_back(LO); s.push_back(HI); s.push_back(LO); }
                else              { s.push_back(HI); s.push_back(HI); s.push_back(LO); s.push_back(LO); }
            }
            if (!nullbyte && b == 0) { for (int i = 0; i < 12; i++) s.push_back(LO); nullbyte = true; }
        }
        for (int i = 0; i < 3600; i++) s.push_back(0);        // trailing silence
        loaded = true;
    }
    bool fromWav(const vector<uint8_t>& d) {
        if (d.size() < 44 || memcmp(d.data(), "RIFF", 4) || memcmp(d.data() + 8, "WAVE", 4)) return false;
        size_t p = 12; int ch = 1, bits = 8; uint32_t sr = 44100; const uint8_t* data = nullptr; uint32_t dlen = 0; int fmt = 1;
        while (p + 8 <= d.size()) {
            uint32_t len = d[p + 4] | d[p + 5] << 8 | d[p + 6] << 16 | (uint32_t)d[p + 7] << 24;
            if (!memcmp(&d[p], "fmt ", 4)) {
                fmt = d[p + 8] | d[p + 9] << 8; ch = d[p + 10] | d[p + 11] << 8;
                sr = d[p + 12] | d[p + 13] << 8 | d[p + 14] << 16 | (uint32_t)d[p + 15] << 24; bits = d[p + 22] | d[p + 23] << 8;
            } else if (!memcmp(&d[p], "data", 4)) { data = &d[p + 8]; dlen = std::min<size_t>(len, d.size() - p - 8); }
            p += 8 + len + (len & 1);
        }
        if (!data || (fmt != 1 && fmt != 0xFFFE) || (bits != 8 && bits != 16)) return false;
        int bps = bits / 8 * ch; size_t n = dlen / bps; s.resize(n); rate = sr;
        for (size_t i = 0; i < n; i++) {
            const uint8_t* q = data + i * bps;
            int v = bits == 8 ? ((int)q[0] - 128) << 8 : (int16_t)(q[0] | q[1] << 8);   // left / mono channel
            s[i] = (int16_t)v;
        }
        loaded = true; return true;
    }
    int level(int thr, bool inv) {   // comparator output, 1 = signal above threshold
        if (!playing || ended) return inv ? 1 : 0;
        size_t i = (size_t)(pos_clocks * rate / CLK_HZ);
        if (i >= s.size()) { ended = true; return inv ? 1 : 0; }
        int v = s[i] > thr; return inv ? !v : v;
    }
    double seconds() const { return s.size() / rate; }
} T;

// ---------------------------------------------------------------------------
// Keyboard (PS/2 set-2 scan codes, as hps_io delivers them on MiSTer)
// ---------------------------------------------------------------------------
struct KeyStroke { vector<uint16_t> codes; };   // codes pressed together (bit 8 = extended)
static const uint16_t K_SHIFT = 0x12, K_CTRL = 0x14, K_RET = 0x5A, K_SPACE = 0x29,
    K_BS = 0x66, K_ESC = 0x76, K_UP = 0x175, K_DOWN = 0x172, K_LEFT = 0x16B, K_RIGHT = 0x174;
static std::map<char, uint16_t> keyPlain() {
    std::map<char, uint16_t> m;
    const char* L = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const uint16_t LC[] = {0x1C,0x32,0x21,0x23,0x24,0x2B,0x34,0x33,0x43,0x3B,0x42,0x4B,0x3A,0x31,0x44,0x4D,0x15,0x2D,0x1B,0x2C,0x3C,0x2A,0x1D,0x22,0x35,0x1A};
    for (int i = 0; i < 26; i++) m[L[i]] = LC[i];
    const uint16_t DC[] = {0x45,0x16,0x1E,0x26,0x25,0x2E,0x36,0x3D,0x3E,0x46};
    for (int i = 0; i < 10; i++) m['0' + i] = DC[i];
    m['-'] = 0x4E; m[';'] = 0x4C; m[':'] = 0x52; m[','] = 0x41; m['.'] = 0x49; m[' '] = K_SPACE;
    return m;
}
// VZ keyboard: shifted symbols live on the VZ key, not the PC key (MAME vtech1.cpp X0-X7).
static std::map<char, char> keyShifted() {
    return { {'!','1'},{'"','2'},{'#','3'},{'$','4'},{'%','5'},{'&','6'},{'\'','7'},{'(','8'},{')','9'},{'@','0'},
             {'=','-'},{'+',';'},{'*',':'},{'/','K'},{'?','L'},{'<',','},{'>','.'},{'^','N'},{'\\','M'},{']','P'},{'[','O'} };
}
static std::map<string, uint16_t> keyNames() {
    auto m = std::map<string, uint16_t>{ {"SHIFT",K_SHIFT},{"CTRL",K_CTRL},{"RETURN",K_RET},{"ENTER",K_RET},{"SPACE",K_SPACE},
        {"BS",K_BS},{"BACKSPACE",K_BS},{"ESC",K_ESC},{"BREAK",K_ESC},{"UP",K_UP},{"DOWN",K_DOWN},{"LEFT",K_LEFT},{"RIGHT",K_RIGHT},
        {"F12",0x07} };
    for (auto& kv : keyPlain()) if (kv.first != ' ') m[string(1, kv.first)] = kv.second;
    return m;
}

// Parse --send-keys text into strokes. Escapes:
//   \n RETURN  \b backspace  \e Esc (= Ctrl+-, BREAK)  \U \D \L \R arrows
//   \^X Ctrl+X  \\ backslash  \p pause one key slot  \P pause 60 frames
static vector<KeyStroke> parseKeys(const string& t, vector<int>& pauses) {
    auto plain = keyPlain(); auto sh = keyShifted();
    vector<KeyStroke> out; pauses.clear();
    for (size_t i = 0; i < t.size(); i++) {
        char c = t[i]; KeyStroke k; int pause = 0;
        if (c == '\\' && i + 1 < t.size()) {
            char e = t[++i];
            switch (e) {
                case 'n': case 'r': k.codes = {K_RET}; break;
                case 'b': k.codes = {K_BS}; break;
                case 'e': k.codes = {K_ESC}; break;
                case 'U': k.codes = {K_UP}; break;
                case 'D': k.codes = {K_DOWN}; break;
                case 'L': k.codes = {K_LEFT}; break;
                case 'R': k.codes = {K_RIGHT}; break;
                case 'p': pause = 1; break;
                case 'P': pause = 2; break;
                case '^': if (i + 1 < t.size()) { char x = toupper(t[++i]); if (plain.count(x)) k.codes = {K_CTRL, plain[x]}; } break;
                case '\\': k.codes = {K_SHIFT, plain['M']}; break;
                default: fprintf(stderr, "warning: unknown key escape \\%c\n", e);
            }
        } else if (c == '\n') k.codes = {K_RET};
        else {
            char u = toupper(c);
            if (plain.count(u)) k.codes = {plain[u]};
            else if (sh.count(c)) k.codes = {K_SHIFT, plain[sh[c]]};
            else fprintf(stderr, "warning: no VZ key for '%c'\n", c);
        }
        if (pause) { out.push_back(KeyStroke{}); pauses.push_back(pause); }
        else if (!k.codes.empty()) { out.push_back(k); pauses.push_back(0); }
    }
    return out;
}

struct PsEvent { long frame; uint16_t code; bool down; };
static vector<PsEvent> g_ps;          // sorted by frame (stable)
static long g_last_key_frame = 0;
static void scheduleKeys() {
    for (auto& kt : O.keys) {
        vector<int> pauses; auto ks = parseKeys(kt.text, pauses); long f = kt.frame;
        for (size_t i = 0; i < ks.size(); i++) {
            if (pauses[i]) { f += pauses[i] == 1 ? O.key_hold + O.key_gap : 60; continue; }
            for (auto c : ks[i].codes) g_ps.push_back({f, c, true});
            for (auto it = ks[i].codes.rbegin(); it != ks[i].codes.rend(); ++it) g_ps.push_back({f + O.key_hold, *it, false});
            f += O.key_hold + O.key_gap;
        }
        g_last_key_frame = std::max(g_last_key_frame, f);
    }
    auto names = keyNames();
    for (auto& h : O.holds) {   // text = KEY:FRAMES
        auto p = h.text.find(':'); string nm = h.text.substr(0, p); long dur = p == string::npos ? O.key_hold : strtol(h.text.substr(p + 1).c_str(), nullptr, 0);
        string u = nm; for (auto& c : u) c = toupper(c);
        if (!names.count(u)) { fprintf(stderr, "error: unknown key name %s\n", nm.c_str()); exit(2); }
        g_ps.push_back({h.frame, names[u], true}); g_ps.push_back({h.frame + dur, names[u], false});
        g_last_key_frame = std::max(g_last_key_frame, h.frame + dur);
    }
    std::stable_sort(g_ps.begin(), g_ps.end(), [](const PsEvent& a, const PsEvent& b) { return a.frame < b.frame; });
}

// ---------------------------------------------------------------------------
// ioctl download (hps_io stand-in)
// ---------------------------------------------------------------------------
struct Download { vector<uint8_t> data; int index; size_t pos = 0; int phase = 0; int wait = 0; string name; };
static std::deque<Download> g_dl;
static bool g_dl_active = false;

// ---------------------------------------------------------------------------
// Help
// ---------------------------------------------------------------------------
static void usage() {
    printf(
"Laser 310 / VZ200 headless simulator\n"
"usage: obj_hl/Vemu [options]          (run from verilator/; ROM .hex paths are relative)\n\n"
"Run control\n"
"  --stop-at-frame N            exit after frame N (default 300; ~50-60 frames = 1 s)\n"
"  --reset-at-frame N           pulse reset at frame N (repeatable)\n"
"  --stop-at-pc ADDR[,ADDR]     exit when the CPU fetches an opcode at ADDR (hex)\n"
"  --break-pc ADDR[,ADDR]       log (don't stop) each fetch at ADDR\n"
"  --quiet                      fewer progress messages\n"
"OSD / machine (same status bits as Laser310.sv CONF_STR)\n"
"  --status HEX                 raw status word\n"
"  --status-bit N=V             set one status bit\n"
"  --turbo                      O5 Turbo On (CPU 3x)\n"
"  --dos-rom                    O6 Disk drives (DOS) On: VZ DOS at 4000h + controller\n"
"  --shrg on|off                O7 SHRG (default On)\n"
"  --sysrom FILE / --dosrom FILE  replace BASIC / DOS ROM contents (sim only)\n"
"Media\n"
"  --vz FILE[@FRAME]            download a .VZ snapshot (index 1) at FRAME (default 150)\n"
"  --ioctl FRAME:INDEX:FILE     generic ioctl download\n"
"  --tape FILE.wav|FILE.cas     mount FILE in the core's Tape slot (S0): the core's player\n"
"                               (rtl/vz_tape.sv) streams it sector by sector; the deck plays\n"
"                               while the ROM's tape code runs (type CLOAD / CRUN)\n"
"  --tape-mount-frame N         mount at frame N (default 5)\n"
"  --disk1 FILE[@FRAME] / --disk2 FILE[@FRAME]   mount a .dsk in drive 1/2 (S1/S2; default\n"
"                               frames 3/4); implies --dos-rom. The core reads and writes it\n"
"                               through the SD block interface (in memory)\n"
"  --disk1-ro / --disk2-ro      mount read-only (write protect)\n"
"  --disk1-save FILE / --disk2-save FILE   write the image (with the core's writes) at exit\n"
"  --sd-latency CLOCKS          clocks from sd_rd to the first byte (default 20000 = 0.47 ms)\n"
"  --tape-rewind FRAME          press OSD Rewind tape at FRAME (repeatable)\n"
"  OSD tape rows: --status-bit 12=1 Tape speed Normal, 13=1 Tape overlay Off, 14=1 Tape audio On\n"
"  --tape-direct FILE           bypass the player: drive the comparator from FILE in the\n"
"                               harness (old path; .cas or 8/16-bit .wav)\n"
"  --tape-frame N               --tape-direct: start playing at frame N (default: 30 frames\n"
"                               after the last --send-keys/--hold-key event)\n"
"  --tape-speed X               --tape-direct: time scale (default 1, 3 with --turbo)\n"
"  --tape-threshold N           --tape-direct: threshold, signed 16-bit (default 1310)\n"
"  --tape-invert                --tape-direct: invert the comparator output\n"
"  --tape-out FILE.wav          record cassette out (latch bit 2), 8-bit\n"
"  --audio-out FILE.wav         record the core's audio output (AUDIO_L, signed 16-bit)\n"
"  --wav-rate HZ                sample rate for --tape-out/--audio-out (default 44100)\n"
"Input\n"
"  --send-keys FRAME:TEXT       type TEXT from FRAME. Escapes: \\n RETURN, \\b BS, \\e BREAK,\n"
"                               \\U \\D \\L \\R arrows, \\^X Ctrl+X, \\\\ backslash,\n"
"                               \\p pause one key slot, \\P pause 60 frames.\n"
"                               Shifted symbols use the VZ layout (\" = Shift+2 ...)\n"
"  --key-hold N / --key-gap N   frames per key press / between keys (default 3 / 3)\n"
"  --hold-key FRAME:NAME:N      hold a key N frames (A-Z 0-9 SPACE RETURN SHIFT CTRL\n"
"                               UP DOWN LEFT RIGHT BREAK BS F12 ...)\n"
"  --joy FRAME:HEX              joystick 1 bits: 0 R, 1 L, 2 D, 3 U, 4 fire, 5 arm\n"
"  --joy2 FRAME:HEX             joystick 2\n"
"Output\n"
"  --screenshot N[,N..]         PNG at frame N\n"
"  --screenshot-every N         PNG every N frames\n"
"  --screenshot-end             PNG of the last frame\n"
"  --screenshot-dir DIR / --screenshot-prefix P   (files: DIR/P_NNNNN.png)\n"
"  --screen-text N[,N..]        print the 32x16 text screen (VRAM) at frame N\n"
"  --screen-text-every N / --screen-text-end\n"
"  --hash                       print FBHASH every frame;  --hash-at N[,N..]\n"
"  --dump-ram FRAME:FILE        64 KB CPU view (ROM, VRAM bank, RAM) at FRAME\n"
"  --dump-vram FRAME:FILE       all 8 KB of VRAM\n"
"  --stats                      per-frame clocks / Hz / lines / CPU cycles / picture size\n"
"  --stats-summary              one summary line at exit\n"
"Debug logs (stdout)\n"
"  --watch LO-HI                log memory writes in [LO,HI] (hex) with frame + PC\n"
"  --io-log                     log IN/OUT and writes to the 6800h latch\n"
"  --cpu-log-from N --cpu-log-to N   opcode fetch trace (PC, opcode, SP)\n"
#ifdef HL_TRACE
"  --trace-from N --trace-to N  FST waveform (--trace-file F, default trace.fst)\n"
#endif
"Checks (exit 1 if any fails)\n"
"  --expect-text FRAME:TEXT     text screen contains TEXT at FRAME\n"
"  --expect-no-text FRAME:TEXT  text screen does not contain TEXT\n"
"  --expect-mem FRAME:ADDR=HEX  bytes at ADDR (e.g. 7AE9=0F7B02)\n"
"  --expect-hash FRAME:HASH     frame hash equals HASH (hex)\n"
"  --expect-latch FRAME:VAL[/MASK]  6800h output latch (hex; bit 3 = graphics mode,\n"
"                               4 = CSS, 2 = cassette out, 0/5 = speaker)\n"
"  --expect-hint FRAME:on|off   .VZ load hint (vz_overlay.sv) shown or not\n"
"  --expect-tape-hint FRAME:none|crun|run   tape next-step hint shown\n"
"  --expect-bar FRAME:on|off    tape status bar shown (deck playing)\n");
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------
static void parseArgs(int argc, char** argv) {
    for (int i = 1; i < argc; i++) {
        string a = argv[i];
        auto need = [&](void) -> string { if (i + 1 >= argc) { fprintf(stderr, "error: %s needs a value\n", a.c_str()); exit(2); } return argv[++i]; };
        auto ff = [&](vector<FrameFile>& v) { long f; string r; if (!splitFrame(need(), f, r)) { fprintf(stderr, "error: %s FRAME:FILE\n", a.c_str()); exit(2); } v.push_back({f, absPath(r)}); };
        auto ft = [&](vector<FrameText>& v) { long f; string r; if (!splitFrame(need(), f, r)) { fprintf(stderr, "error: %s FRAME:TEXT\n", a.c_str()); exit(2); } v.push_back({f, r}); };
        if (a == "--help" || a == "-h") { usage(); exit(0); }
        else if (a == "--headless") {}
        else if (a == "--stop-at-frame") O.stop_frame = strtol(need().c_str(), nullptr, 0);
        else if (a == "--reset-at-frame") O.reset_frames.push_back(strtol(need().c_str(), nullptr, 0));
        else if (a == "--stop-at-pc") { string s = need(); for (size_t p = 0; p < s.size();) { size_t q = s.find(',', p); if (q == string::npos) q = s.size(); O.stop_pc.push_back(strtol(s.substr(p, q - p).c_str(), nullptr, 16)); p = q + 1; } }
        else if (a == "--break-pc")  { string s = need(); for (size_t p = 0; p < s.size();) { size_t q = s.find(',', p); if (q == string::npos) q = s.size(); O.break_pc.push_back(strtol(s.substr(p, q - p).c_str(), nullptr, 16)); p = q + 1; } }
        else if (a == "--quiet") O.quiet = true;
        else if (a == "--status") O.status = strtoul(need().c_str(), nullptr, 16);
        else if (a == "--status-bit") { string s = need(); auto p = s.find('='); int b = atoi(s.substr(0, p).c_str()); int v = p == string::npos ? 1 : atoi(s.substr(p + 1).c_str()); if (v) O.status |= 1u << b; else O.status &= ~(1u << b); }
        else if (a == "--turbo") O.status |= 1u << 5;
        else if (a == "--dos-rom") O.status |= 1u << 6;
        else if (a == "--shrg") { string v = lower(need()); if (v == "on" || v == "1") O.status &= ~(1u << 7); else O.status |= 1u << 7; }
        else if (a == "--sysrom") O.sysrom = absPath(need());
        else if (a == "--dosrom") O.dosrom = absPath(need());
        else if (a == "--vz") { string s = need(); long f = 150; auto p = s.rfind('@'); if (p != string::npos) { f = strtol(s.substr(p + 1).c_str(), nullptr, 0); s = s.substr(0, p); } O.loads.push_back({f, 1, absPath(s)}); }
        else if (a == "--ioctl") { string s = need(); long f; string r; splitFrame(s, f, r); auto p = r.find(':'); O.loads.push_back({f, atoi(r.substr(0, p).c_str()), absPath(r.substr(p + 1))}); }
        else if (a == "--tape") O.tape_sd = absPath(need());
        else if (a == "--tape-direct") O.tape = absPath(need());
        else if (a == "--tape-mount-frame") O.tape_mount_frame = strtol(need().c_str(), nullptr, 0);
        else if (a == "--disk1" || a == "--disk2") {
            int n = a[6] - '1'; string v = need(); auto at = v.rfind('@');
            if (at != string::npos && at > 0 && isdigit((unsigned char)v[at + 1])) { O.disk_frame[n] = atol(v.c_str() + at + 1); v = v.substr(0, at); }
            O.disk[n] = absPath(v); O.status |= 1u << 6;
        }
        else if (a == "--disk1-ro" || a == "--disk2-ro") O.disk_ro[a[6] - '1'] = true;
        else if (a == "--disk1-save" || a == "--disk2-save") O.disk_save[a[6] - '1'] = absPath(need());
        else if (a == "--sd-latency") O.sd_latency = strtol(need().c_str(), nullptr, 0);
        else if (a == "--tape-rewind") O.rewind_frames.push_back(strtol(need().c_str(), nullptr, 0));
        else if (a == "--expect-tape-hint") { long f; string r; splitFrame(need(), f, r); r = lower(r); O.expect_tape_hint.push_back({f, r == "crun" ? 1 : r == "run" ? 2 : 0}); }
        else if (a == "--expect-bar") { long f; string r; splitFrame(need(), f, r); O.expect_bar.push_back({f, r == "on" || r == "1"}); }
        else if (a == "--tape-frame") O.tape_frame = strtol(need().c_str(), nullptr, 0);
        else if (a == "--tape-speed") O.tape_speed = atof(need().c_str());
        else if (a == "--tape-threshold") O.tape_threshold = atoi(need().c_str());
        else if (a == "--tape-invert") O.tape_invert = true;
        else if (a == "--tape-out") O.tape_out = absPath(need());
        else if (a == "--audio-out") O.audio_out = absPath(need());
        else if (a == "--wav-rate") O.wav_rate = atoi(need().c_str());
        else if (a == "--send-keys") ft(O.keys);
        else if (a == "--key-hold") O.key_hold = atoi(need().c_str());
        else if (a == "--key-gap") O.key_gap = atoi(need().c_str());
        else if (a == "--hold-key") ft(O.holds);
        else if (a == "--joy" || a == "--joy2") { long f; string r; splitFrame(need(), f, r); O.joys.push_back({f, a == "--joy" ? 0 : 1, (uint32_t)strtoul(r.c_str(), nullptr, 16)}); }
        else if (a == "--screenshot") { auto v = parseList(need()); O.shots.insert(O.shots.end(), v.begin(), v.end()); }
        else if (a == "--screenshot-every") O.shot_every = strtol(need().c_str(), nullptr, 0);
        else if (a == "--screenshot-end") O.shot_end = true;
        else if (a == "--screenshot-dir") O.shot_dir = absPath(need());
        else if (a == "--screenshot-prefix") O.shot_prefix = need();
        else if (a == "--screen-text") { auto v = parseList(need()); O.text_at.insert(O.text_at.end(), v.begin(), v.end()); }
        else if (a == "--screen-text-every") O.text_every = strtol(need().c_str(), nullptr, 0);
        else if (a == "--screen-text-end") O.text_end = true;
        else if (a == "--hash") O.hash = true;
        else if (a == "--hash-at") { auto v = parseList(need()); O.hash_at.insert(O.hash_at.end(), v.begin(), v.end()); }
        else if (a == "--dump-ram") ff(O.dump_ram);
        else if (a == "--dump-vram") ff(O.dump_vram);
        else if (a == "--stats") O.stats = true;
        else if (a == "--stats-summary") O.stats_summary = true;
        else if (a == "--watch") { string s = need(); auto p = s.find('-'); O.watch = true; O.watch_lo = strtol(s.substr(0, p).c_str(), nullptr, 16); O.watch_hi = p == string::npos ? O.watch_lo : strtol(s.substr(p + 1).c_str(), nullptr, 16); }
        else if (a == "--io-log") O.io_log = true;
        else if (a == "--cpu-log-from") O.cpu_log_from = strtol(need().c_str(), nullptr, 0);
        else if (a == "--cpu-log-to") O.cpu_log_to = strtol(need().c_str(), nullptr, 0);
        else if (a == "--trace-from") O.trace_from = strtol(need().c_str(), nullptr, 0);
        else if (a == "--trace-to") O.trace_to = strtol(need().c_str(), nullptr, 0);
        else if (a == "--trace-file") O.trace_file = absPath(need());
        else if (a == "--expect-text") ft(O.expect_text);
        else if (a == "--expect-no-text") ft(O.expect_notext);
        else if (a == "--expect-mem") {
            long f; string r; splitFrame(need(), f, r); auto p = r.find('='); MemExpect m{f, (uint16_t)strtol(r.substr(0, p).c_str(), nullptr, 16), {}};
            string hx = r.substr(p + 1); for (size_t k = 0; k + 1 < hx.size(); k += 2) m.bytes.push_back(strtol(hx.substr(k, 2).c_str(), nullptr, 16));
            O.expect_mem.push_back(m);
        }
        else if (a == "--expect-hint") { long f; string r; splitFrame(need(), f, r); O.expect_hint.push_back({f, r == "on" || r == "1"}); }
        else if (a == "--expect-latch") { long f; string r; splitFrame(need(), f, r); auto p = r.find('/'); O.expect_latch.push_back({f, (uint8_t)strtoul(r.c_str(), nullptr, 16), (uint8_t)(p == string::npos ? 0xff : strtoul(r.substr(p + 1).c_str(), nullptr, 16))}); }
        else if (a == "--expect-hash") { long f; string r; splitFrame(need(), f, r); O.expect_hash.push_back({f, strtoull(r.c_str(), nullptr, 16)}); }
        else if (a[0] == '+') {}   // verilator +args
        else { fprintf(stderr, "error: unknown option %s (try --help)\n", a.c_str()); exit(2); }
    }
    if (O.cpu_log_from >= 0 && O.cpu_log_to < 0) O.cpu_log_to = O.stop_frame;
    if (O.tape_speed == 0) O.tape_speed = (O.status & (1u << 5)) ? 3.0 : 1.0;
}

static bool inList(const vector<long>& v, long f) { return std::find(v.begin(), v.end(), f) != v.end(); }

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IOLBF, 0);   // logs readable while running / when piped
    char buf[PATH_MAX]; g_cwd = getcwd(buf, sizeof buf) ? buf : ".";
    Verilated::commandArgs(argc, argv);
    parseArgs(argc, argv);

    // ROM .hex init files are relative to verilator/; find it from the binary location.
    if (access("roms/sysrom.hex", R_OK) != 0) {
        char exe[PATH_MAX]; if (realpath(argv[0], exe)) { string d = dirname(exe); d += "/.."; if (chdir(d.c_str())) {} }
        if (access("roms/sysrom.hex", R_OK) != 0) { fprintf(stderr, "error: roms/sysrom.hex not found; run from verilator/\n"); return 2; }
    }

    top = new Vemu();
#ifdef HL_TRACE
    VerilatedFstC* tfp = nullptr;
    if (O.trace_from >= 0) Verilated::traceEverOn(true);
#endif
    top->status = O.status;
    top->cass_in = 0;
    // Power-on: Verilator starts every register at 0, so RESET_N (RESET_DE) is
    // already low and the tv80's async `negedge reset_n` never fires, leaving
    // its one-hot state machine at 0 (CPU hangs at PC 0). Give the resets a real
    // high->low edge: run briefly out of reset, then assert reset.
    top->reset = 0;
    SIG(RESET_DE__DOT__RESET_COUNT) = 0x1FFFF;
    for (int i = 0; i < 8; i++) { top->clk_sys = i & 1; top->eval(); }
    top->reset = 1;
    top->clk_sys = 0;
    top->eval();

    if (!O.sysrom.empty()) loadRom(O.sysrom, false);
    if (!O.dosrom.empty()) loadRom(O.dosrom, true);

    scheduleKeys();
    for (auto& l : O.loads) { Download d; d.data = readFile(l.file); d.index = l.index; d.name = l.file; (void)d; }

    if (!O.tape.empty()) {
        auto d = readFile(O.tape); string e = ext(O.tape);
        if (e == "wav") { if (!T.fromWav(d)) { fprintf(stderr, "error: unsupported WAV %s (PCM 8/16-bit only)\n", O.tape.c_str()); return 2; } }
        else T.fromCas(d);
        if (O.tape_frame < 0) O.tape_frame = g_last_key_frame + 30;
        if (!O.quiet) printf("TAPE %s: %.1f s at %.0f Hz, plays from frame %ld at %.1fx\n", O.tape.c_str(), T.seconds(), T.rate, O.tape_frame, O.tape_speed);
    }

    // SD images: 0 tape (S0), 1/2 disks (S1/S2)
    struct SdImg { vector<uint8_t> d; bool mounted = true; long frame = 0; bool ro = false; string name; uint64_t writes = 0; };
    SdImg img[3];
    if (!O.tape_sd.empty()) { img[0].d = readFile(O.tape_sd); img[0].mounted = false; img[0].frame = O.tape_mount_frame; img[0].name = O.tape_sd;
        if (!O.quiet) printf("TAPE %s (%zu bytes) mounts at frame %ld\n", O.tape_sd.c_str(), img[0].d.size(), O.tape_mount_frame); }
    for (int n = 0; n < 2; n++) if (!O.disk[n].empty()) {
        SdImg& I = img[n + 1]; I.d = readFile(O.disk[n]); I.mounted = false; I.frame = O.disk_frame[n]; I.ro = O.disk_ro[n]; I.name = O.disk[n];
        if (!O.quiet) printf("DISK%d %s (%zu bytes) mounts at frame %ld%s\n", n + 1, O.disk[n].c_str(), I.d.size(), I.frame, I.ro ? " read-only" : "");
    }
    vector<uint8_t>& sd_img = img[0].d;
    int sd_state = 0, sd_n = 0, sd_wr_op = 0; long sd_wait = 0; uint32_t sd_sector = 0; int sd_idx = 0; int mount_clk = 0; long rewind_clk = 0;
    bool old_play = false, old_end = false; uint64_t sd_reads = 0;

    WavOut tapeOut, audioOut;
    if (!O.tape_out.empty() && !tapeOut.open(O.tape_out, O.wav_rate, 8)) { fprintf(stderr, "error: %s\n", O.tape_out.c_str()); return 2; }
    if (!O.audio_out.empty() && !audioOut.open(O.audio_out, O.wav_rate, 16)) { fprintf(stderr, "error: %s\n", O.audio_out.c_str()); return 2; }
    double wav_step = CLK_HZ / O.wav_rate, wav_next = 0;
    bool tape_out_started = false;

    if (O.shot_every || !O.shots.empty() || O.shot_end) mkdirs(O.shot_dir);

    // State
    long frame = 0; uint64_t clocks = 0;
    long reset_left = O.reset_clocks;
    size_t ps_i = 0; uint32_t ps_val = 0; long ps_gap = 0;
    std::vector<IoctlLoad> loads = O.loads;
    std::stable_sort(loads.begin(), loads.end(), [](const IoctlLoad& a, const IoctlLoad& b) { return a.frame < b.frame; });
    size_t load_i = 0;
    std::vector<JoyEv> joys = O.joys; std::stable_sort(joys.begin(), joys.end(), [](const JoyEv& a, const JoyEv& b) { return a.frame < b.frame; });
    size_t joy_i = 0;
    int fails = 0;

    // edge trackers
    bool old_vb = false, old_hb = false, old_hs = false, old_gclk = false;
    bool old_wr = true, old_rd = true, old_m1 = true;
    uint16_t last_pc = 0, fetch_pc = 0; bool in_fetch = false;
    uint64_t f_clocks = 0, f_cpu = 0, f_lines = 0, f_intlow = 0;
    uint64_t sum_clocks = 0, sum_cpu = 0, sum_lines = 0, nframes_stats = 0;
    bool stopped_pc = false;
    auto t0 = std::chrono::steady_clock::now(); std::clock_t c0 = std::clock();
    double tape_last = -1;

    while (!Verilated::gotFinish()) {
        // ---------------- inputs for this clock ----------------
        if (reset_left > 0) { top->reset = 1; reset_left--; } else top->reset = 0;

        // keyboard: one PS/2 event at most every 256 clocks (core samples every 16)
        if (ps_gap > 0) ps_gap--;
        else if (ps_i < g_ps.size() && g_ps[ps_i].frame <= frame) {
            auto& e = g_ps[ps_i++];
            uint32_t toggle = ((ps_val >> 10) & 1) ^ 1;
            ps_val = (toggle << 10) | ((e.down ? 1u : 0u) << 9) | (e.code & 0x1ff);
            top->ps2_key = ps_val; ps_gap = 256;
        }
        while (joy_i < joys.size() && joys[joy_i].frame <= frame) {
            if (joys[joy_i].port == 0) top->joystick_0 = joys[joy_i].mask; else top->joystick_1 = joys[joy_i].mask; joy_i++;
        }

        // ioctl download
        if (!g_dl_active && load_i < loads.size() && loads[load_i].frame <= frame && reset_left == 0) {
            Download d; d.data = readFile(loads[load_i].file); d.index = loads[load_i].index; d.name = loads[load_i].file;
            g_dl.push_back(d); load_i++; g_dl_active = true;
            if (!O.quiet) printf("LOAD frame %ld index %d %s (%zu bytes)\n", frame, d.index, d.name.c_str(), d.data.size());
            top->ioctl_index = d.index; top->ioctl_download = 1; top->ioctl_wr = 0;
        }
        if (g_dl_active) {
            Download& d = g_dl.front();
            if (d.wait > 0) { d.wait--; top->ioctl_wr = 0; }
            else if (d.pos < d.data.size()) {
                top->ioctl_addr = d.pos; top->ioctl_dout = d.data[d.pos]; top->ioctl_wr = 1; d.pos++; d.wait = 7;
            } else if (d.phase == 0) { top->ioctl_wr = 0; d.phase = 1; d.wait = 64; }
            else { top->ioctl_download = 0; g_dl.pop_front(); g_dl_active = false; }
        }

        // tape image slot (hps_io S0): mount, then serve 512-byte sectors after sd_latency clocks
        if (mount_clk > 0) { if (--mount_clk == 0) top->img_mounted = 0; }
        else if (reset_left == 0) for (int n = 0; n < 3; n++) if (!img[n].mounted && frame >= img[n].frame) {
            top->img_size = img[n].d.size(); top->img_readonly = img[n].ro; top->img_mounted = 1u << n; mount_clk = 2; img[n].mounted = true; break;
        }
        // hps_io: serve one 512-byte block read or write at a time, after sd_latency clocks
        switch (sd_state) {
            case 0:
                for (int n = 0; n < 3; n++) if (((top->sd_rd | top->sd_wr) >> n) & 1) {
                    sd_n = n; sd_wr_op = (top->sd_wr >> n) & 1; sd_sector = top->sd_lba[n]; sd_wait = O.sd_latency; sd_state = 1; if (n == 0) sd_reads++; break;
                }
                break;
            case 1: if (--sd_wait <= 0) { top->sd_ack = 1u << sd_n; sd_idx = 0; sd_state = sd_wr_op ? 3 : 2; top->sd_buff_addr = 0; sd_wait = 2; } break;
            case 2: {
                vector<uint8_t>& D = img[sd_n].d;
                if (top->sd_buff_wr) { top->sd_buff_wr = 0; if (++sd_idx == 512) { top->sd_ack = 0; sd_state = 0; } }
                else { size_t o = (size_t)sd_sector * 512 + sd_idx; top->sd_buff_addr = sd_idx; top->sd_buff_dout = o < D.size() ? D[o] : 0; top->sd_buff_wr = 1; }
                break; }
            case 3: {   // write: the core presents sd_buff_din for sd_buff_addr (registered: wait 2 clocks)
                if (--sd_wait > 0) break;
                vector<uint8_t>& D = img[sd_n].d; size_t o = (size_t)sd_sector * 512 + sd_idx;
                if (o < D.size()) D[o] = top->sd_buff_din[sd_n];
                if (++sd_idx == 512) { top->sd_ack = 0; sd_state = 0; img[sd_n].writes++;
                    if (!O.quiet) printf("DISK%d write block %u frame %ld\n", sd_n, sd_sector, frame); }
                else { top->sd_buff_addr = sd_idx; sd_wait = 2; }
                break; }
        }
        if (rewind_clk > 0 && --rewind_clk == 0) top->status = O.status;

        // tape (--tape-direct)
        if (T.loaded) {
            if (!T.playing && frame >= O.tape_frame) { T.playing = true; if (!O.quiet) printf("TAPE play at frame %ld\n", frame); }
            if (T.playing && !T.ended) {
                T.pos_clocks += O.tape_speed;
                top->cass_in = T.level(O.tape_threshold, O.tape_invert);
                if (T.ended && !O.quiet) printf("TAPE end at frame %ld\n", frame);
                double secs = T.pos_clocks / CLK_HZ;
                if (!O.quiet && secs - tape_last >= 10.0) { tape_last = secs; printf("TAPE %.0f/%.0f s (frame %ld)\n", secs * 1, T.seconds(), frame); }
            } else top->cass_in = O.tape_invert ? 1 : 0;
        }

        // ---------------- clock ----------------
        top->clk_sys = 1; top->eval(); main_time++;
#ifdef HL_TRACE
        if (tfp) tfp->dump(main_time * 2);
#endif
        clocks++; f_clocks++;

        // ---------------- observe ----------------
        bool gclk = SIG(GCLK);
        if (gclk && !old_gclk) f_cpu++;
        old_gclk = gclk;
        if (!SIG(CPU_INT_N)) f_intlow++;

        bool m1 = SIG(CPU_M1_N), mreq = SIG(CPU_MREQ_N), rd = SIG(CPU_RD_N), wr = SIG(CPU_WR_N), iorq = SIG(CPU_IORQ_N);
        uint16_t A = SIG(CPU_A);
        // opcode fetch start
        if (!m1 && !mreq && !rd && (old_m1 || old_rd)) { fetch_pc = A; in_fetch = true; last_pc = A;
            if (!O.stop_pc.empty() && std::find(O.stop_pc.begin(), O.stop_pc.end(), A) != O.stop_pc.end()) { printf("STOP pc=%04X frame %ld\n", A, frame); stopped_pc = true; }
            if (!O.break_pc.empty() && std::find(O.break_pc.begin(), O.break_pc.end(), A) != O.break_pc.end()) printf("BREAK pc=%04X frame %ld SP=%04X\n", A, frame, (unsigned)SIG(Z80CPU__DOT__i_tv80_core__DOT__SP));
        }
        if (in_fetch && rd && !old_rd) {   // end of fetch: data valid
            in_fetch = false;
            if (O.cpu_log_from >= 0 && frame >= O.cpu_log_from && frame <= O.cpu_log_to)
                printf("CPU f%ld PC=%04X op=%02X SP=%04X\n", frame, fetch_pc, (unsigned)SIG(CPU_DI), (unsigned)SIG(Z80CPU__DOT__i_tv80_core__DOT__SP));
        }
        if (!wr && old_wr) {   // write strobe start
            uint8_t D = SIG(CPU_DO);
            if (!mreq) {
                if (O.watch && A >= O.watch_lo && A <= O.watch_hi) printf("WRITE f%ld %04X=%02X pc~%04X%s\n", frame, A, D, last_pc, SIG(vz_wr) ? " (vz loader)" : "");
                if (O.io_log && A >= 0x6800 && A < 0x7000 && !SIG(vz_wr)) printf("LATCH f%ld %04X=%02X pc~%04X\n", frame, A, D, last_pc);
            } else if (!iorq && m1 && O.io_log) printf("OUT f%ld port %02X=%02X pc~%04X\n", frame, A & 0xff, D, last_pc);
        }
        // IN: port at the start of the read strobe, value at its end (what the CPU latched)
        static int in_port = -1; static uint8_t in_val = 0;
        if (!rd && old_rd && !iorq && m1) in_port = A & 0xff;
        if (in_port >= 0 && !rd) in_val = SIG(CPU_D_INPORT);
        if (rd && !old_rd && in_port >= 0) { if (O.io_log) printf("IN  f%ld port %02X -> %02X pc~%04X\n", frame, in_port, in_val, last_pc); in_port = -1; }
        old_wr = wr; old_rd = rd; old_m1 = m1;

        // video
        bool hb = top->VGA_HB, vb = top->VGA_VB, hs = top->VGA_HS;
        if (top->CE_PIXEL && !hb && !vb) V.pixel(0xFF000000u | (top->VGA_B << 16) | (top->VGA_G << 8) | top->VGA_R);
        if (hb && !old_hb) V.endLine();
        if (hs && !old_hs) f_lines++;
        old_hb = hb; old_hs = hs;

        // tape player events
        if (!O.tape_sd.empty()) {
            if (SIG(tape_ready)) printf("TAPE ready f%ld length %u samples at %u Hz, auto pitch plays at %u Hz (%+.1f%%)\n", frame, (unsigned)SIG(TAPE_LEN), (unsigned)SIG(vz_tape__DOT__hz), (unsigned)SIG(vz_tape__DOT__cal_hz), 100.0 * SIG(vz_tape__DOT__cal_hz) / SIG(vz_tape__DOT__hz) - 100.0);
            if (SIG(tape_bad)) printf("TAPE bad f%ld (format not supported)\n", frame);
            bool pl = SIG(TAPE_PLAY), en = SIG(TAPE_AT_END);
            if (pl != old_play && !O.quiet) printf("TAPE %s f%ld pos %u/%u%s\n", pl ? "play" : "stop", frame, (unsigned)SIG(TAPE_POS), (unsigned)SIG(TAPE_LEN), SIG(TAPE_FAST) ? " x3" : "");
            if (en && !old_end) printf("TAPE end f%ld underflows %u sd_reads %llu\n", frame, (unsigned)SIG(TAPE_UNDERFLOWS), (unsigned long long)sd_reads);
            old_play = pl; old_end = en;
        }

        // audio / tape out sampling
        if ((tapeOut.f || audioOut.f) && (double)clocks >= wav_next) {
            wav_next += wav_step;
            uint8_t L = SIG(LATCHED_IO_DATA_WR);
            if (tapeOut.f) { bool b = (L >> 2) & 1; if (b) tape_out_started = true; if (tape_out_started) tapeOut.put(b ? 0x6000 : -0x6000); }
            if (audioOut.f) audioOut.put((int16_t)top->AUDIO_L);   // the core's signed mix (speaker + tape when Tape audio On)
        }

        top->clk_sys = 0; top->eval(); main_time++;
#ifdef HL_TRACE
        if (tfp) tfp->dump(main_time * 2);
#endif

        // ---------------- frame boundary: start of vertical blank ----------------
        if (vb && !old_vb) {
            V.endFrame();
            frame++;
            char fn[1024];
            if (O.stats) printf("STATS frame %ld clocks %llu hz %.3f lines %llu pic %dx%d cpu %llu int_low_clocks %llu pc %04X reset_n %d\n",
                frame, (unsigned long long)f_clocks, CLK_HZ / f_clocks, (unsigned long long)f_lines, V.lw, V.lh, (unsigned long long)f_cpu, (unsigned long long)f_intlow, (unsigned)SIG(Z80CPU__DOT__i_tv80_core__DOT__PC), (int)SIG(RESET_N));
            if (frame > 2) { sum_clocks += f_clocks; sum_cpu += f_cpu; sum_lines += f_lines; nframes_stats++; }
            f_clocks = f_cpu = f_lines = f_intlow = 0;

            if (inList(O.rewind_frames, frame)) { top->status = O.status | (1u << 15); rewind_clk = 1000; if (!O.quiet) printf("REWIND frame %ld\n", frame); }
            for (auto& e : O.expect_tape_hint) if (e.first == frame) {
                int h = SIG(tape_hint); bool ok = h == e.second; const char* nm[] = {"none", "crun", "run", "?"};
                printf("EXPECT %s tape-hint f%ld got %s\n", ok ? "OK  " : "FAIL", frame, nm[h & 3]); if (!ok) fails++;
            }
            for (auto& e : O.expect_bar) if (e.first == frame) {
                bool on = SIG(bar_show); bool ok = on == e.second;
                printf("EXPECT %s bar f%ld got %s\n", ok ? "OK  " : "FAIL", frame, on ? "on" : "off"); if (!ok) fails++;
            }
            if (inList(O.reset_frames, frame)) { reset_left = O.reset_clocks; if (!O.quiet) printf("RESET frame %ld\n", frame); }
            bool shot = inList(O.shots, frame) || (O.shot_every && frame % O.shot_every == 0) || (O.shot_end && frame == O.stop_frame);
            if (shot) { snprintf(fn, sizeof fn, "%s/%s_%05ld.png", O.shot_dir.c_str(), O.shot_prefix.c_str(), frame); V.png(fn); if (!O.quiet) printf("SHOT %s\n", fn); }
            if (O.hash || inList(O.hash_at, frame)) printf("FBHASH frame %ld %016llx\n", frame, (unsigned long long)V.hash());
            if (inList(O.text_at, frame) || (O.text_every && frame % O.text_every == 0) || (O.text_end && frame == O.stop_frame))
                printf("TEXT frame %ld\n%s----\n", frame, screenText().c_str());
            for (auto& d : O.dump_ram) if (d.frame == frame) { dumpRam(d.file); if (!O.quiet) printf("DUMP ram %s\n", d.file.c_str()); }
            for (auto& d : O.dump_vram) if (d.frame == frame) { dumpVram(d.file); if (!O.quiet) printf("DUMP vram %s\n", d.file.c_str()); }
            for (auto& e : O.expect_text) if (e.frame == frame) {
                string s = screenText(); string flat; for (char c : s) flat += c == '\n' ? ' ' : c;   // allow matches across lines? no: per line
                bool ok = s.find(e.text) != string::npos;
                printf("EXPECT %s text f%ld \"%s\"\n", ok ? "OK  " : "FAIL", frame, e.text.c_str()); if (!ok) { fails++; printf("%s----\n", s.c_str()); }
            }
            for (auto& e : O.expect_notext) if (e.frame == frame) {
                bool ok = screenText().find(e.text) == string::npos;
                printf("EXPECT %s no-text f%ld \"%s\"\n", ok ? "OK  " : "FAIL", frame, e.text.c_str()); if (!ok) fails++;
            }
            for (auto& e : O.expect_mem) if (e.frame == frame) {
                bool ok = true; string got;
                for (size_t k = 0; k < e.bytes.size(); k++) { uint8_t b = peek(e.addr + k); char t[4]; snprintf(t, 4, "%02X", b); got += t; if (b != e.bytes[k]) ok = false; }
                printf("EXPECT %s mem f%ld %04X got %s\n", ok ? "OK  " : "FAIL", frame, e.addr, got.c_str()); if (!ok) fails++;
            }
            for (auto& e : O.expect_hash) if (e.frame == frame) {
                bool ok = V.hash() == e.hash;
                printf("EXPECT %s hash f%ld %016llx\n", ok ? "OK  " : "FAIL", frame, (unsigned long long)V.hash()); if (!ok) fails++;
            }
            for (auto& e : O.expect_hint) if (e.first == frame) {
                bool on = SIG(hint_show); bool ok = on == e.second;
                printf("EXPECT %s hint f%ld got %s\n", ok ? "OK  " : "FAIL", frame, on ? "on" : "off"); if (!ok) fails++;
            }
            for (auto& e : O.expect_latch) if (e.frame == frame) {
                uint8_t l = SIG(LATCHED_IO_DATA_WR); bool ok = (l & e.mask) == (e.val & e.mask);
                printf("EXPECT %s latch f%ld got %02X want %02X/%02X\n", ok ? "OK  " : "FAIL", frame, l, e.val, e.mask); if (!ok) fails++;
            }
#ifdef HL_TRACE
            if (O.trace_from >= 0 && frame == O.trace_from && !tfp) { tfp = new VerilatedFstC; top->trace(tfp, 99); tfp->open(O.trace_file.c_str()); }
            if (tfp && frame > O.trace_to && O.trace_to >= 0) { tfp->close(); delete tfp; tfp = nullptr; }
#endif
            if (frame >= O.stop_frame) break;
        }
        old_vb = vb;
        if (stopped_pc) break;
    }

    double wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    if (O.stats_summary && nframes_stats)
        printf("SUMMARY frames %llu avg_clocks %.1f hz %.4f lines %.2f cpu_cycles %.1f cpu_mhz %.4f pic %dx%d\n",
            (unsigned long long)nframes_stats, (double)sum_clocks / nframes_stats, CLK_HZ * nframes_stats / sum_clocks,
            (double)sum_lines / nframes_stats, (double)sum_cpu / nframes_stats, sum_cpu * CLK_HZ / sum_clocks / 1e6, V.lw, V.lh);
    if (O.shot_end && frame != O.stop_frame) { char fn[1024]; snprintf(fn, sizeof fn, "%s/%s_%05ld.png", O.shot_dir.c_str(), O.shot_prefix.c_str(), frame); V.png(fn); }
    if (O.text_end && frame != O.stop_frame) printf("TEXT frame %ld\n%s----\n", frame, screenText().c_str());
    tapeOut.close(); audioOut.close();
    for (int n = 0; n < 2; n++) if (!O.disk[n].empty()) {
        if (!O.quiet) printf("DISK%d %llu block writes, %u sectors written by the CPU, head at track %u, ready %u, sd state %u, latch %02X\n", n + 1, (unsigned long long)img[n + 1].writes,
                             (unsigned)SIG(floppy__DOT__sectors_written), (unsigned)SIG(floppy__DOT__ptrk)[n], (unsigned)SIG(floppy__DOT__ready), (unsigned)SIG(floppy__DOT__s), (unsigned)SIG(floppy__DOT__latch));
        if (!O.disk_save[n].empty()) { FILE* f = fopen(O.disk_save[n].c_str(), "wb"); if (f) { fwrite(img[n + 1].d.data(), 1, img[n + 1].d.size(), f); fclose(f); } }
    }
#ifdef HL_TRACE
    if (tfp) { tfp->close(); delete tfp; }
#endif
    double cpu_s = (double)(std::clock() - c0) / CLOCKS_PER_SEC;
    if (!O.quiet) printf("DONE frames %ld sim %.2f s wall %.1f s cpu %.1f s (%.1f fps/cpu-s)%s\n", frame, clocks / CLK_HZ, wall, cpu_s, cpu_s > 0 ? frame / cpu_s : 0.0, fails ? " EXPECT FAILURES" : "");
    top->final(); delete top;
    return fails ? 1 : 0;
}
