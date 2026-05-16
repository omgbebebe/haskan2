#include "jolt_wrapper.h"

#include <Jolt/Jolt.h>
#include <Jolt/RegisterTypes.h>
#include <Jolt/Core/Factory.h>
#include <Jolt/Core/TempAllocator.h>
#include <Jolt/Core/JobSystemThreadPool.h>
#include <Jolt/Physics/PhysicsSettings.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/Collision/Shape/SphereShape.h>
#include <Jolt/Physics/Collision/Shape/PlaneShape.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>
#include <Jolt/Physics/Body/BodyActivationListener.h>
#include <Jolt/Physics/Collision/BroadPhase/BroadPhaseLayerInterfaceMask.h>

#include <iostream>
#include <vector>

using namespace JPH;

// Stub activation listener
class StubActivationListener : public BodyActivationListener {
public:
    void OnBodyActivated(const BodyID&, uint64) override {}
    void OnBodyDeactivated(const BodyID&, uint64) override {}
};

// Stub contact listener
class StubContactListener : public ContactListener {
public:
    ValidateResult OnContactValidate(const Body&, const Body&, RVec3Arg, const CollideShapeResult&) override {
        return ValidateResult::AcceptAllContactsForThisBodyPair;
    }
    void OnContactAdded(const Body&, const Body&, const ContactManifold&, ContactSettings&) override {}
    void OnContactPersisted(const Body&, const Body&, const ContactManifold&, ContactSettings&) override {}
    void OnContactRemoved(const SubShapeIDPair&) override {}
};

// Simple broadphase layer interface for a single layer
class BPLayerInterfaceImpl final : public BroadPhaseLayerInterface {
public:
    virtual uint GetNumBroadPhaseLayers() const override { return 1; }
    virtual BroadPhaseLayer GetBroadPhaseLayer(ObjectLayer inLayer) const override { return BroadPhaseLayer(0); }
};

// Object vs broadphase layer filter
class ObjectVsBroadPhaseLayerFilterImpl : public ObjectVsBroadPhaseLayerFilter {
public:
    virtual bool ShouldCollide(ObjectLayer inLayer1, BroadPhaseLayer inLayer2) const override { return true; }
};

// Object layer pair filter
class ObjectLayerPairFilterImpl : public ObjectLayerPairFilter {
public:
    virtual bool ShouldCollide(ObjectLayer inObject1, ObjectLayer inObject2) const override { return true; }
};

struct JoltWorld {
    PhysicsSystem* physicsSystem;
    JobSystemThreadPool* jobSystem;
    TempAllocatorImpl* tempAllocator;
    StubActivationListener activationListener;
    StubContactListener contactListener;
    BPLayerInterfaceImpl bpLayerInterface;
    ObjectVsBroadPhaseLayerFilterImpl objVsBpFilter;
    ObjectLayerPairFilterImpl objPairFilter;
    std::vector<BodyID> bodies;
};

static bool gJoltInitialized = false;

void* joltCreateWorld(int maxBodies, int maxBodyPairs, int maxContactConstraints) {
    if (!gJoltInitialized) {
        RegisterDefaultAllocator();
        Factory::sInstance = new Factory();
        RegisterTypes();
        gJoltInitialized = true;
    }

    JoltWorld* world = new JoltWorld();
    world->tempAllocator = new TempAllocatorImpl(64 * 1024 * 1024); // 64MB
    world->jobSystem = new JobSystemThreadPool(
        1024,  // max jobs
        32,    // max barriers
        std::max(1, (int)std::thread::hardware_concurrency() - 2)
    );

    world->physicsSystem = new PhysicsSystem();
    world->physicsSystem->Init(
        maxBodies,
        0, // num body mutexes (0 = auto)
        maxBodyPairs,
        maxContactConstraints,
        world->bpLayerInterface,
        world->objVsBpFilter,
        world->objPairFilter
    );
    world->physicsSystem->SetBodyActivationListener(&world->activationListener);
    world->physicsSystem->SetContactListener(&world->contactListener);

    return world;
}

void joltDestroyWorld(void* worldPtr) {
    if (!worldPtr) return;
    JoltWorld* world = static_cast<JoltWorld*>(worldPtr);

    // Remove all bodies
    BodyInterface& bodyInterface = world->physicsSystem->GetBodyInterface();
    for (const BodyID& id : world->bodies) {
        bodyInterface.RemoveBody(id);
        bodyInterface.DestroyBody(id);
    }

    delete world->physicsSystem;
    delete world->jobSystem;
    delete world->tempAllocator;
    delete world;
}

void joltUpdate(void* worldPtr, float deltaTime, int collisionSteps) {
    if (!worldPtr) return;
    JoltWorld* world = static_cast<JoltWorld*>(worldPtr);

    const float cDeltaTime = deltaTime / collisionSteps;
    for (int step = 0; step < collisionSteps; ++step) {
        world->physicsSystem->Update(cDeltaTime, 1, world->tempAllocator, world->jobSystem);
    }
}

int joltCreateBoxBody(void* worldPtr, float hx, float hy, float hz, float mass, float px, float py, float pz) {
    if (!worldPtr) return -1;
    JoltWorld* world = static_cast<JoltWorld*>(worldPtr);
    BodyInterface& bodyInterface = world->physicsSystem->GetBodyInterface();

    BoxShapeSettings shapeSettings(Vec3(hx, hy, hz));
    ShapeSettings::ShapeResult shapeResult = shapeSettings.Create();
    if (shapeResult.HasError()) return -1;

    EMotionType motionType = mass > 0.0f ? EMotionType::Dynamic : EMotionType::Static;

    BodyCreationSettings settings(
        shapeResult.Get(),
        RVec3(px, py, pz),
        Quat::sIdentity(),
        motionType,
        ObjectLayer(0) // Using a single layer for simplicity
    );
    settings.mOverrideMassProperties = EOverrideMassProperties::CalculateInertia;
    settings.mMassPropertiesOverride.mMass = mass;
    if (motionType == EMotionType::Dynamic) {
        settings.mMotionQuality = EMotionQuality::LinearCast;
    }

    Body* body = bodyInterface.CreateBody(settings);
    if (!body) return -1;

    bodyInterface.AddBody(body->GetID(), EActivation::Activate);
    world->bodies.push_back(body->GetID());
    return body->GetID().GetIndexAndSequenceNumber();
}

int joltCreateSphereBody(void* worldPtr, float radius, float mass, float px, float py, float pz) {
    if (!worldPtr) return -1;
    JoltWorld* world = static_cast<JoltWorld*>(worldPtr);
    BodyInterface& bodyInterface = world->physicsSystem->GetBodyInterface();

    SphereShapeSettings shapeSettings(radius);
    ShapeSettings::ShapeResult shapeResult = shapeSettings.Create();
    if (shapeResult.HasError()) return -1;

    EMotionType motionType = mass > 0.0f ? EMotionType::Dynamic : EMotionType::Static;

    BodyCreationSettings settings(
        shapeResult.Get(),
        RVec3(px, py, pz),
        Quat::sIdentity(),
        motionType,
        ObjectLayer(0)
    );
    settings.mOverrideMassProperties = EOverrideMassProperties::CalculateInertia;
    settings.mMassPropertiesOverride.mMass = mass;
    if (motionType == EMotionType::Dynamic) {
        settings.mMotionQuality = EMotionQuality::LinearCast;
    }

    Body* body = bodyInterface.CreateBody(settings);
    if (!body) return -1;

    bodyInterface.AddBody(body->GetID(), EActivation::Activate);
    world->bodies.push_back(body->GetID());
    return body->GetID().GetIndexAndSequenceNumber();
}

int joltCreateStaticPlane(void* worldPtr, float nx, float ny, float nz, float dist) {
    if (!worldPtr) return -1;
    JoltWorld* world = static_cast<JoltWorld*>(worldPtr);
    BodyInterface& bodyInterface = world->physicsSystem->GetBodyInterface();

    PlaneShapeSettings shapeSettings(Plane(Vec3(nx, ny, nz), dist));
    ShapeSettings::ShapeResult shapeResult = shapeSettings.Create();
    if (shapeResult.HasError()) return -1;

    BodyCreationSettings settings(
        shapeResult.Get(),
        RVec3(0, 0, 0),
        Quat::sIdentity(),
        EMotionType::Static,
        ObjectLayer(0)
    );

    Body* body = bodyInterface.CreateBody(settings);
    if (!body) return -1;

    bodyInterface.AddBody(body->GetID(), EActivation::DontActivate);
    world->bodies.push_back(body->GetID());
    return body->GetID().GetIndexAndSequenceNumber();
}

void joltRemoveBody(void* worldPtr, int bodyId) {
    if (!worldPtr || bodyId < 0) return;
    JoltWorld* world = static_cast<JoltWorld*>(worldPtr);
    BodyInterface& bodyInterface = world->physicsSystem->GetBodyInterface();

    BodyID id = BodyID((uint32)bodyId);
    bodyInterface.RemoveBody(id);
    bodyInterface.DestroyBody(id);

    // Remove from tracking
    auto it = std::find(world->bodies.begin(), world->bodies.end(), id);
    if (it != world->bodies.end()) {
        world->bodies.erase(it);
    }
}

void joltGetPosition(void* worldPtr, int bodyId, float* outX, float* outY, float* outZ) {
    if (!worldPtr || bodyId < 0 || !outX || !outY || !outZ) return;
    JoltWorld* world = static_cast<JoltWorld*>(worldPtr);
    BodyInterface& bodyInterface = world->physicsSystem->GetBodyInterface();

    RVec3 pos = bodyInterface.GetPosition(BodyID((uint32)bodyId));
    *outX = (float)pos.GetX();
    *outY = (float)pos.GetY();
    *outZ = (float)pos.GetZ();
}

void joltGetRotation(void* worldPtr, int bodyId, float* outX, float* outY, float* outZ, float* outW) {
    if (!worldPtr || bodyId < 0 || !outX || !outY || !outZ || !outW) return;
    JoltWorld* world = static_cast<JoltWorld*>(worldPtr);
    BodyInterface& bodyInterface = world->physicsSystem->GetBodyInterface();

    Quat rot = bodyInterface.GetRotation(BodyID((uint32)bodyId));
    *outX = rot.GetX();
    *outY = rot.GetY();
    *outZ = rot.GetZ();
    *outW = rot.GetW();
}

void joltGetLinearVelocity(void* worldPtr, int bodyId, float* outX, float* outY, float* outZ) {
    if (!worldPtr || bodyId < 0 || !outX || !outY || !outZ) return;
    JoltWorld* world = static_cast<JoltWorld*>(worldPtr);
    BodyInterface& bodyInterface = world->physicsSystem->GetBodyInterface();

    Vec3 vel = bodyInterface.GetLinearVelocity(BodyID((uint32)bodyId));
    *outX = vel.GetX();
    *outY = vel.GetY();
    *outZ = vel.GetZ();
}

int joltIsActive(void* worldPtr, int bodyId) {
    if (!worldPtr || bodyId < 0) return 0;
    JoltWorld* world = static_cast<JoltWorld*>(worldPtr);
    BodyInterface& bodyInterface = world->physicsSystem->GetBodyInterface();
    return bodyInterface.IsActive(BodyID((uint32)bodyId)) ? 1 : 0;
}

void joltSetPosition(void* worldPtr, int bodyId, float x, float y, float z) {
    if (!worldPtr || bodyId < 0) return;
    JoltWorld* world = static_cast<JoltWorld*>(worldPtr);
    BodyInterface& bodyInterface = world->physicsSystem->GetBodyInterface();
    bodyInterface.SetPosition(BodyID((uint32)bodyId), RVec3(x, y, z), EActivation::Activate);
}

void joltSetLinearVelocity(void* worldPtr, int bodyId, float x, float y, float z) {
    if (!worldPtr || bodyId < 0) return;
    JoltWorld* world = static_cast<JoltWorld*>(worldPtr);
    BodyInterface& bodyInterface = world->physicsSystem->GetBodyInterface();
    bodyInterface.SetLinearVelocity(BodyID((uint32)bodyId), Vec3(x, y, z));
}

void joltAddForce(void* worldPtr, int bodyId, float fx, float fy, float fz) {
    if (!worldPtr || bodyId < 0) return;
    JoltWorld* world = static_cast<JoltWorld*>(worldPtr);
    BodyInterface& bodyInterface = world->physicsSystem->GetBodyInterface();
    bodyInterface.AddForce(BodyID((uint32)bodyId), Vec3(fx, fy, fz));
}

void joltAddImpulse(void* worldPtr, int bodyId, float fx, float fy, float fz) {
    if (!worldPtr || bodyId < 0) return;
    JoltWorld* world = static_cast<JoltWorld*>(worldPtr);
    BodyInterface& bodyInterface = world->physicsSystem->GetBodyInterface();
    bodyInterface.AddImpulse(BodyID((uint32)bodyId), Vec3(fx, fy, fz));
}
