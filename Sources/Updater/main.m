#import "Updater.h"
#include <string.h>

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        if (strcmp(argv[1], "--check") == 0) return updaterRun(NO);
        if (strcmp(argv[1], "--install") == 0) return updaterRun(YES);
        return 2;
    }
}
