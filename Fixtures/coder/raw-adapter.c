#include "CoderNet.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void log_message(int level, const char *message) {
    fprintf(stderr, "[%d] %s\n", level, message);
}

int main(void) {
    char *config = NULL;
    size_t capacity = 0;
    if (getline(&config, &capacity, stdin) < 0) {
        free(config);
        return 2;
    }
    CoderNetSetLogCallback(log_message);
    int handle = CoderNetStart(config);
    memset(config, 0, strlen(config));
    free(config);
    if (!handle) return 3;
    char *socket_path = CoderNetDialSSH(handle);
    if (!socket_path) {
        CoderNetClose(handle);
        return 4;
    }
    puts(socket_path);
    fflush(stdout);
    CoderNetFreeString(socket_path);
    int command;
    while ((command = getchar()) != EOF && command != 'c') {
        if (command == 'r') CoderNetRebind(handle);
    }
    CoderNetClose(handle);
    return 0;
}
