#include "Vcore_top.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdlib.h>
#include <string>
#include <verilated.h>

namespace fs = std::filesystem;

extern "C" const char *get_env_value(const char *key) {
  const char *value = getenv(key);
  if (value == nullptr)
    return "";
  return value;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 2) {
    std::cout << "Usage: " << argv[0] << " RAM_FILE_PATH [CYCLE]" << std::endl;
    return 1;
  }

  // メモリの初期値を格納しているファイル名
  std::string memory_file_path = argv[1];
  try {
    // 絶対パスに変換する
    fs::path absolutePath = fs::absolute(memory_file_path);
    memory_file_path = absolutePath.string();
  } catch (const std::exception &e) {
    std::cerr << "Invalid memory file path : " << e.what() << std::endl;
    return 1;
  }

  // シミュレーションを実行するクロックサイクル数
  unsigned long long cycles = 0;
  if (argc >= 3) {
    std::string cycles_string = argv[2];
    try {
      cycles = stoull(cycles_string);
    } catch (const std::exception &e) {
      std::cerr << "Invalid number: " << argv[2] << std::endl;
      return 1;
    }
  }

  // 環境変数でメモリの初期化用ファイルを指定する
  const char *original_env = getenv("RAM_FILE_PATH");
  setenv("RAM_FILE_PATH", memory_file_path.c_str(), 1);

  // top
  Vcore_top *dut = new Vcore_top();

#ifdef TEST_MODE
  fs::path dump_path = memory_file_path;
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
  if (original_env != nullptr) {
    setenv("RAM_FILE_PATH", original_env, 1);
  }

  // loop
  dut->rst = 1;
  unsigned long long executed_cycles = 0;
  for (long long i = 0;
       !Verilated::gotFinish() && (cycles == 0 || i / 2 < cycles); i++) {
    dut->clk = !dut->clk;
    dut->eval();
    executed_cycles = i / 2;
  }
  dut->final();
  std::cout << "cycles: " << executed_cycles << std::endl;

#ifdef TEST_MODE
  return dut->test_success != 1;
#endif
}
