// Issue #10: reference GPU contract for the CPU splat rasteriser concepts.
//
// Host dispatch contract:
//   1. Clear tileCounts to zero.
//   2. Dispatch binTiles with ceil(imageWidth / 16), ceil(imageHeight / 16), 1.
//   3. Dispatch rasterizeTiles with the same grid. The two dispatches are separate
//      submissions (or have an equivalent UAV barrier between them).
//
// The input projection is deliberately explicit: the CPU and GPU paths must use
// the same camera projection and populate screenCenterPx, conic, depth, and
// radiusPx. conic represents A, B, C in exp(-0.5 * (A*dx*dx + 2*B*dx*dy + C*dy*dy)).
// This avoids silently treating the legacy screen-space floorDepth as 3D depth.

static const uint TILE_SIZE = 16;
static const uint MAX_GAUSSIANS_PER_TILE = 1024;
static const uint SH_COEFFICIENTS = 16; // degree 3, packed RGB coefficients.

struct Gaussian {
    float3 worldPosition;
    float2 screenCenterPx;
    float3 conic;       // A, B, C; projected inverse covariance.
    float radiusPx;
    float depth;
    float opacity;
    float3 sh[SH_COEFFICIENTS];
};

struct CameraUniforms {
    uint imageWidth;
    uint imageHeight;
    uint gaussianCount;
    uint shDegree;       // 0..3; coefficients above this degree are ignored.
    float3 cameraPosition;
    float _cameraPadding;
};

struct MediumUniforms {
    // Coefficients are inverse scene-distance units. The host owns unit choice.
    float3 betaDirect;
    float _betaDirectPadding;
    float3 betaBackscatter;
    float _betaBackscatterPadding;
    float3 background;
    float _backgroundPadding;
};

ConstantBuffer<CameraUniforms> camera : register(b0);
ConstantBuffer<MediumUniforms> medium : register(b1);
StructuredBuffer<Gaussian> gaussians : register(t0);
RWStructuredBuffer<uint> tileCounts : register(u0);
RWStructuredBuffer<uint> tileIndices : register(u1);
RWTexture2D<float4> outputImage : register(u2);
RWTexture2D<float> outputExpectedDepth : register(u3);

float saturate1(float x) {
    return clamp(x, 0.0, 1.0);
}

uint tileCountX() {
    return (camera.imageWidth + TILE_SIZE - 1) / TILE_SIZE;
}

uint tileCountY() {
    return (camera.imageHeight + TILE_SIZE - 1) / TILE_SIZE;
}

uint tileIndex(uint2 tile) {
    return tile.y * tileCountX() + tile.x;
}

bool overlapsTile(Gaussian g, uint2 tile) {
    float2 lo = float2(tile * TILE_SIZE);
    float2 hi = lo + float2(TILE_SIZE, TILE_SIZE);
    float2 gLo = g.screenCenterPx - g.radiusPx;
    float2 gHi = g.screenCenterPx + g.radiusPx;
    return gHi.x >= lo.x && gLo.x < hi.x && gHi.y >= lo.y && gLo.y < hi.y;
}

// One invocation owns one tile, so appending is deterministic and does not
// require an atomic. The fixed-capacity list is a deliberate bounded contract;
// overflow is clipped rather than writing out of bounds.
[numthreads(1, 1, 1)]
[shader("compute")]
void binTiles(uint3 dispatchId : SV_DispatchThreadID) {
    uint2 tile = dispatchId.xy;
    if (tile.x >= tileCountX() || tile.y >= tileCountY()) return;

    uint list = tileIndex(tile);
    uint count = 0;
    for (uint i = 0; i < camera.gaussianCount; ++i) {
        Gaussian g = gaussians[i];
        if (overlapsTile(g, tile) && count < MAX_GAUSSIANS_PER_TILE) {
            tileIndices[list * MAX_GAUSSIANS_PER_TILE + count] = i;
            count++;
        }
    }
    tileCounts[list] = count;
}

// The list is sorted once per tile, then all 256 pixels in that tile consume
// the same front-to-back order. This is intentionally simple and serves as the
// validation reference rather than a performance implementation.
groupshared uint orderedIds[MAX_GAUSSIANS_PER_TILE];
groupshared uint orderedCount;

float3 evalSH(Gaussian g) {
    float3 d = normalize(camera.cameraPosition - g.worldPosition);
    float x = d.x;
    float y = d.y;
    float z = d.z;
    uint degree = min(camera.shDegree, 3);
    float3 c = g.sh[0];
    if (degree >= 1) {
        c += g.sh[1] * y + g.sh[2] * z + g.sh[3] * x;
    }
    if (degree >= 2) {
        c += g.sh[4] * (x * y) + g.sh[5] * (y * z)
           + g.sh[6] * (3.0 * z * z - 1.0) + g.sh[7] * (x * z)
           + g.sh[8] * (x * x - y * y);
    }
    if (degree >= 3) {
        c += g.sh[9] * (y * (3.0 * x * x - y * y))
           + g.sh[10] * (x * y * z) + g.sh[11] * (y * (5.0 * z * z - 1.0))
           + g.sh[12] * (5.0 * z * z * z - 3.0 * z)
           + g.sh[13] * (x * (5.0 * z * z - 1.0))
           + g.sh[14] * (z * (x * x - y * y))
           + g.sh[15] * (x * (x * x - 3.0 * y * y));
    }
    return max(c, float3(0.0, 0.0, 0.0));
}

float3 applyMedium(float3 albedo, float z) {
    float3 directT = exp(-medium.betaDirect * max(z, 0.0));
    float3 backT = exp(-medium.betaBackscatter * max(z, 0.0));
    return albedo * directT + medium.background * (1.0 - backT);
}

float gaussianAlpha(Gaussian g, float2 pixel) {
    float2 d = pixel - g.screenCenterPx;
    float exponent = -0.5 * (g.conic.x * d.x * d.x
        + 2.0 * g.conic.y * d.x * d.y + g.conic.z * d.y * d.y);
    return saturate1(g.opacity * exp(exponent));
}

[numthreads(TILE_SIZE, TILE_SIZE, 1)]
[shader("compute")]
void rasterizeTiles(uint3 dispatchId : SV_DispatchThreadID,
                    uint3 groupId : SV_GroupID,
                    uint3 groupThreadId : SV_GroupThreadID) {
    uint2 tile = groupId.xy;
    if (tile.x >= tileCountX() || tile.y >= tileCountY()) return;
    uint list = tileIndex(tile);

    if (groupThreadId.x == 0 && groupThreadId.y == 0) {
        orderedCount = tileCounts[list];
        for (uint i = 0; i < orderedCount; ++i) {
            orderedIds[i] = tileIndices[list * MAX_GAUSSIANS_PER_TILE + i];
        }
        // Insertion sort is safe for the fixed list and gives a stable tie rule.
        for (uint i = 1; i < orderedCount; ++i) {
            uint id = orderedIds[i];
            float key = gaussians[id].depth;
            uint j = i;
            while (j > 0 && gaussians[orderedIds[j - 1]].depth > key) {
                orderedIds[j] = orderedIds[j - 1];
                j--;
            }
            orderedIds[j] = id;
        }
    }
    GroupMemoryBarrierWithGroupSync();

    uint2 pixel = dispatchId.xy;
    if (pixel.x >= camera.imageWidth || pixel.y >= camera.imageHeight) return;
    float2 pixelCenter = float2(pixel) + 0.5;
    float3 colour = float3(0.0, 0.0, 0.0);
    float transmittance = 1.0;
    float depthNumerator = 0.0;
    float depthWeight = 0.0;
    for (uint i = 0; i < orderedCount; ++i) {
        Gaussian g = gaussians[orderedIds[i]];
        float a = gaussianAlpha(g, pixelCenter);
        float contribution = transmittance * a;
        colour += contribution * applyMedium(evalSH(g), g.depth);
        depthNumerator += contribution * g.depth;
        depthWeight += contribution;
        transmittance *= 1.0 - a;
        if (transmittance < 1.0 / 255.0) break;
    }
    colour += transmittance * medium.background;
    float expectedDepth = depthWeight > 0.0 ? depthNumerator / depthWeight : 0.0;
    outputImage[pixel] = float4(colour, 1.0);
    outputExpectedDepth[pixel] = expectedDepth;
}
