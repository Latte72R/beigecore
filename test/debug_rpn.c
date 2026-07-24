#define DEBUG_REG ((volatile unsigned long long *)0x40000000)

char getchar() {
  unsigned long long c = *DEBUG_REG;
  if ((c & (0x01010ULL << 44)) == 0) {
    return 0;
  }
  c = c & 255;
  return c;
}

void putchar(char ch) { *DEBUG_REG = ch | (0x01010ULL << 44); }

void print_number(int num) {
  char digits[10];
  unsigned int value;
  int length = 0;

  if (num < 0) {
    putchar('-');
    value = 0u - (unsigned int)num;
  } else {
    value = (unsigned int)num;
  }

  if (value == 0) {
    putchar('0');
    return;
  }

  while (value > 0) {
    digits[length++] = '0' + value % 10;
    value /= 10;
  }
  while (length > 0) {
    putchar(digits[--length]);
  }
}

void print(const char *str) {
  const char *ch = str;
  while (*ch) {
    putchar(*ch++);
  }
}

int main(void) {
  int saved = 0;
  int digit_count = 0;
  int index = 0;
  int stack[32];
  char c;

  while (1) {
    if ((c = getchar()) == 0) {
      continue;
    }
    putchar(c);

    if (c >= '0' && c <= '9') {
      saved = saved * 10 + c - '0';
      digit_count++;
      continue;
    }

    if (c == ' ') {
      if (digit_count == 0) {
        continue;
      }
      if (index == 32) {
        print("ERROR\n");
        index = 0;
      } else {
        stack[index++] = saved;
      }
      saved = 0;
      digit_count = 0;
      continue;
    }

    if (c == '+' || c == '-' || c == '*' || c == '/') {
      if (digit_count > 0) {
        if (index == 32) {
          print("ERROR\n");
          index = 0;
          saved = 0;
          digit_count = 0;
          continue;
        }
        stack[index++] = saved;
        saved = 0;
        digit_count = 0;
      }

      if (index < 2 || (c == '/' && stack[index - 1] == 0)) {
        print("ERROR\n");
        index = 0;
        continue;
      }

      int right = stack[--index];
      switch (c) {
      case '+':
        stack[index - 1] += right;
        break;
      case '-':
        stack[index - 1] -= right;
        break;
      case '*':
        stack[index - 1] *= right;
        break;
      case '/':
        stack[index - 1] /= right;
        break;
      }
      continue;
    }

    if (c == '\r' || c == '\n') {
      if (digit_count > 0) {
        if (index == 32) {
          print("ERROR\n");
          index = 0;
          saved = 0;
          digit_count = 0;
          continue;
        }
        stack[index++] = saved;
      }

      if (index == 0) {
        saved = 0;
        digit_count = 0;
        continue;
      }

      if (index == 1) {
        print_number(stack[0]);
        putchar('\n');
      } else {
        print("ERROR\n");
      }
      saved = 0;
      digit_count = 0;
      index = 0;
      continue;
    }

    print("ERROR\n");
    saved = 0;
    digit_count = 0;
    index = 0;
  }
}
