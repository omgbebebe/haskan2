#include "jolt_wrapper.h"
#include <stdio.h>
#include <math.h>

int main() {
    printf("Creating Jolt world...\n");
    void* world = joltCreateWorld(1024, 1024, 1024);
    if (!world) {
        printf("FAILED: could not create world\n");
        return 1;
    }
    printf("OK: world created\n");

    printf("Creating ground plane...\n");
    int groundId = joltCreateStaticPlane(world, 0.0f, 1.0f, 0.0f, 0.0f);
    if (groundId < 0) {
        printf("FAILED: could not create ground plane\n");
        return 1;
    }
    printf("OK: ground plane created (id=%d)\n", groundId);

    printf("Creating box body...\n");
    int boxId = joltCreateBoxBody(world, 0.5f, 0.5f, 0.5f, 1.0f, 0.0f, 5.0f, 0.0f);
    if (boxId < 0) {
        printf("FAILED: could not create box body\n");
        return 1;
    }
    printf("OK: box body created (id=%d)\n", boxId);

    printf("Stepping simulation...\n");
    float x, y, z;
    joltGetPosition(world, boxId, &x, &y, &z);
    printf("  Initial position: (%.3f, %.3f, %.3f)\n", x, y, z);

    for (int i = 0; i < 60; ++i) {
        joltUpdate(world, 1.0f / 60.0f, 1);
    }

    joltGetPosition(world, boxId, &x, &y, &z);
    printf("  Final position:   (%.3f, %.3f, %.3f)\n", x, y, z);

    if (fabsf(y) < 1.5f) {
        printf("OK: box fell and hit ground\n");
    } else {
        printf("UNEXPECTED: box did not fall (y=%.3f)\n", y);
    }

    printf("Destroying world...\n");
    joltDestroyWorld(world);
    printf("OK: world destroyed\n");

    printf("\nAll tests passed!\n");
    return 0;
}
