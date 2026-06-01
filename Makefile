# Directory where sources live
HELPER_DIR := helper

# Source files
HELPER_SRC := $(HELPER_DIR)/helper.c
HELPER_HDR := $(HELPER_DIR)/helper.h

# Output binary
HELPER_BIN := $(HELPER_DIR)/helper

# Compiler settings
CC := gcc
CFLAGS := -O2 -Wall -Wextra

# Default target
all: $(HELPER_BIN)

# Build rule
$(HELPER_BIN): $(HELPER_SRC) $(HELPER_HDR)
	$(CC) $(CFLAGS) -o $(HELPER_BIN) $(HELPER_SRC)

# Clean rule
clean:
	rm -f $(HELPER_BIN)

.PHONY: all clean
