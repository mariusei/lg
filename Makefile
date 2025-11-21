CC = clang
CFLAGS = -O3 -Wall -Wextra
TARGET = lg
PREFIX = /usr/local

$(TARGET): lg.c
	$(CC) $(CFLAGS) -o $(TARGET) lg.c

install: $(TARGET)
	install -m 755 $(TARGET) $(PREFIX)/bin/$(TARGET)

uninstall:
	rm -f $(PREFIX)/bin/$(TARGET)

clean:
	rm -f $(TARGET)

.PHONY: install uninstall clean