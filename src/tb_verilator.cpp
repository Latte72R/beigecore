#if defined(PRINT_DEBUG) && defined(LOG_PIPELINE)
#error "PRINT_DEBUG and LOG_PIPELINE cannot be enabled together"
#endif

#include "Vcore_top.h"
#include <cstdio>
#include <deque>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <signal.h>
#include <stdlib.h>
#include <string>
#include <termios.h>
#include <verilated.h>

#if defined(LOG_PIPELINE) && defined(VL_USER_FINISH)
void vl_finish(const char *, int, const char *) { Verilated::gotFinish(true); }
#endif

namespace fs = std::filesystem;

extern "C" const char *get_env_value(const char *key) {
  const char *value = getenv(key);
  if (value == nullptr)
    return "";
  return value;
}

extern "C" const unsigned long long get_input_dpic() {
  unsigned char c = 0;
  ssize_t bytes_read = read(STDIN_FILENO, &c, 1);

  if (bytes_read == 1) {
    return static_cast<unsigned long long>(c) | (0x01010ULL << 44);
  }
  return 0;
}

struct termios old_setting;

void restore_termios_setting(void) {
  tcsetattr(STDIN_FILENO, TCSANOW, &old_setting);
}

void sighandler(int signum) {
  restore_termios_setting();
  exit(signum);
}

void set_nonblocking(void) {
  struct termios new_setting;

  if (tcgetattr(STDIN_FILENO, &old_setting) == -1) {
    perror("tcgetattr");
    return;
  }
  new_setting = old_setting;
  new_setting.c_lflag &= ~(ICANON | ECHO);
  if (tcsetattr(STDIN_FILENO, TCSANOW, &new_setting) == -1) {
    perror("tcsetattr");
    return;
  }
  signal(SIGINT, sighandler);
  signal(SIGTERM, sighandler);
  signal(SIGQUIT, sighandler);
  atexit(restore_termios_setting);

  int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
  if (flags == -1) {
    perror("fcntl(F_GETFL)");
    return;
  }
  if (fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) == -1) {
    perror("fcntl(F_SETFL)");
    return;
  }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 3) {
    std::cout << "Usage: " << argv[0] << " ROM_FILE_PATH RAM_FILE_PATH [CYCLE]"
              << std::endl;
    return 1;
  }

  std::setvbuf(stdout, nullptr, _IONBF, 0);
  set_nonblocking();

  // メモリの初期値を格納しているファイル名
  std::string rom_file_path = argv[1];
  std::string ram_file_path = argv[2];

  try {
    // 絶対パスに変換する
    rom_file_path = fs::absolute(rom_file_path).string();
    ram_file_path = fs::absolute(ram_file_path).string();
  } catch (const std::exception &e) {
    std::cerr << "Invalid memory file path : " << e.what() << std::endl;
    return 1;
  }

  // シミュレーションを実行するクロックサイクル数
  unsigned long long cycles = 0;
  if (argc >= 4) {
    std::string cycles_string = argv[3];
    try {
      cycles = stoull(cycles_string);
    } catch (const std::exception &e) {
      std::cerr << "Invalid number: " << argv[3] << std::endl;
      return 1;
    }
  }

  // 環境変数でメモリの初期化用ファイルを指定する
  const char *original_env_rom = getenv("ROM_FILE_PATH");
  const char *original_env_ram = getenv("RAM_FILE_PATH");
  setenv("ROM_FILE_PATH", rom_file_path.c_str(), 1);
  setenv("RAM_FILE_PATH", ram_file_path.c_str(), 1);

  // デバッグ用の入出力デバイスのアドレスを取得する
  const char *dbg_addr_c = getenv("DBG_ADDR");
  const unsigned long long DBG_ADDR =
      dbg_addr_c == nullptr ? 0 : std::strtoull(dbg_addr_c, nullptr, 0);

  // top
  Vcore_top *dut = new Vcore_top();
  dut->MMAP_DBG_ADDR = DBG_ADDR;

  dut->uart_rx_valid = 0;
  dut->uart_rx_data = 0;
  dut->uart_tx_ready = 1;

  std::deque<unsigned char> uart_rx_queue;

  if (const char *input = getenv("UART_RX")) {
    while (*input != '\0')
      uart_rx_queue.push_back(static_cast<unsigned char>(*input++));
  }

#ifdef TEST_MODE
  fs::path dump_path = ram_file_path;
  dump_path.replace_extension("");
  dump_path.replace_extension(".dump");

  std::ifstream dump(dump_path);
  std::string line;
  while (std::getline(dump, line)) {
    std::size_t tohost_pos = line.find("<tohost>");
    if (tohost_pos != std::string::npos) {
      std::size_t addr_pos = line.rfind('#', tohost_pos);
      dut->test_tohost_addr =
          std::stoull(line.substr(addr_pos + 1), nullptr, 16);
      break;
    }
  }
#endif

  // reset
  dut->clk = 0;
  dut->rst = 1;
  dut->eval();
  dut->rst = 0;
  dut->eval();

  // 環境変数を元に戻す
  if (original_env_rom != nullptr) {
    setenv("ROM_FILE_PATH", original_env_rom, 1);
  }
  if (original_env_ram != nullptr) {
    setenv("RAM_FILE_PATH", original_env_ram, 1);
  }

  // loop
  dut->rst = 1;
  unsigned long long executed_cycles = 0;
  for (long long i = 0;
       !Verilated::gotFinish() && (cycles == 0 || i / 2 < cycles); i++) {
    const bool rising_edge = dut->clk == 0;

    if (rising_edge) {
      unsigned char input = 0;
      while (read(STDIN_FILENO, &input, 1) == 1)
        uart_rx_queue.push_back(input);

      dut->uart_rx_valid = !uart_rx_queue.empty();
      dut->uart_rx_data = uart_rx_queue.empty() ? 0 : uart_rx_queue.front();

      dut->eval();
    }

    const bool uart_rx_fire =
        rising_edge && dut->uart_rx_valid && dut->uart_rx_ready;
    const bool uart_tx_fire =
        rising_edge && dut->uart_tx_valid && dut->uart_tx_ready;

    // rising edge後にtx_dataが更新される場合に備えて先に保存
    const unsigned char uart_tx_byte = dut->uart_tx_data;

    dut->clk = !dut->clk;
    dut->eval();

    if (uart_rx_fire)
      uart_rx_queue.pop_front();

    if (uart_tx_fire) {
      std::fputc(uart_tx_byte, stdout);
      std::fflush(stdout);
    }

    executed_cycles = i / 2;
  }
  dut->final();
  std::cerr << "cycles: " << executed_cycles << std::endl;

#ifdef TEST_MODE
  const bool test_success = dut->test_success == 1;
  std::cerr << (test_success ? "test success!" : "test failed!") << std::endl;
  return !test_success;
#endif
}
