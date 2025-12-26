CC = clang
CFLAGS = -O2 -Wall -Wextra -Wformat-security -Wstack-protector \
        -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
        -Wno-unused-result
LDFLAGS = -lm
TARGET = lg
PREFIX = /usr/local

all: $(TARGET)

$(TARGET): lg_v2.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $(TARGET) lg_v2.c

install: $(TARGET)
	install -m 755 $(TARGET) $(PREFIX)/bin/$(TARGET)

install-user: $(TARGET)
	mkdir -p $(HOME)/.local/bin
	install -m 755 $(TARGET) $(HOME)/.local/bin/$(TARGET)

uninstall:
	rm -f $(PREFIX)/bin/$(TARGET)

uninstall-user:
	rm -f $(HOME)/.local/bin/$(TARGET)

clean:
	rm -f $(TARGET) lg_v2

.PHONY: all install install-user uninstall uninstall-user clean