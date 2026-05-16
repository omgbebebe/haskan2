#ifndef JOLT_WRAPPER_H
#define JOLT_WRAPPER_H

#ifdef __cplusplus
extern "C" {
#endif

// Lifecycle
void* joltCreateWorld(int maxBodies, int maxBodyPairs, int maxContactConstraints);
void joltDestroyWorld(void* world);

// Stepping
void joltUpdate(void* world, float deltaTime, int collisionSteps);

// Body management
int joltCreateBoxBody(void* world, float hx, float hy, float hz, float mass, float px, float py, float pz);
int joltCreateSphereBody(void* world, float radius, float mass, float px, float py, float pz);
int joltCreateStaticPlane(void* world, float nx, float ny, float nz, float dist);
void joltRemoveBody(void* world, int bodyId);

// State queries
void joltGetPosition(void* world, int bodyId, float* outX, float* outY, float* outZ);
void joltGetRotation(void* world, int bodyId, float* outX, float* outY, float* outZ, float* outW);
void joltGetLinearVelocity(void* world, int bodyId, float* outX, float* outY, float* outZ);
int joltIsActive(void* world, int bodyId);

// State mutations
void joltSetPosition(void* world, int bodyId, float x, float y, float z);
void joltSetLinearVelocity(void* world, int bodyId, float x, float y, float z);
void joltAddForce(void* world, int bodyId, float fx, float fy, float fz);
void joltAddImpulse(void* world, int bodyId, float fx, float fy, float fz);

#ifdef __cplusplus
}
#endif

#endif // JOLT_WRAPPER_H
