// Host binding contract: group(0), binding(0) is a uniform buffer containing
// 20 f32 values (80 bytes), in this order:
// resolution.xy, time, _pad0; orbit yaw, pitch, distance, _pad1;
// beta_d.rgb, _pad2; beta_b.rgb, _pad3; b_inf.rgb, _pad4.
// The browser host writes metres as the shader's synthetic view distance unit.

struct CameraMedium {
  resolution: vec2f,
  time: f32,
  _pad0: f32,
  orbit: vec4f,
  beta_d: vec4f,
  beta_b: vec4f,
  b_inf: vec4f,
};

@group(0) @binding(0) var<uniform> params: CameraMedium;

struct VertexOut {
  @builtin(position) position: vec4f,
  @location(0) uv: vec2f,
};

@vertex
fn vertexMain(@builtin(vertex_index) index: u32) -> VertexOut {
  var positions = array<vec2f, 3>(
    vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0)
  );
  var out: VertexOut;
  out.position = vec4f(positions[index], 0.0, 1.0);
  out.uv = positions[index] * 0.5 + vec2f(0.5);
  return out;
}

fn hash21(p: vec2f) -> f32 {
  let q = fract(p * vec2f(123.34, 456.21));
  return fract(q.x * (q.y + 45.32));
}

fn circle(point: vec2f, centre: vec2f, radius: f32) -> f32 {
  return 1.0 - smoothstep(radius * 0.72, radius, distance(point, centre));
}

// This is the raster side of the contract: it produces unattenuated albedo J
// and an explicit positive view distance z for each screen fragment. It is a
// procedural stand-in until the browser splat buffers are integrated.
fn raster(uv: vec2f) -> vec4f {
  let yaw = params.orbit.x;
  let pitch = params.orbit.y;
  let centre = vec2f(0.5 + 0.16 * sin(yaw), 0.56 - 0.10 * sin(pitch));
  let floor = 1.0 - smoothstep(0.63, 0.68 + 0.03 * sin(yaw), uv.y);
  let caustic = 0.025 * sin(uv.x * 42.0 + params.time * 1.7) * sin(uv.y * 31.0 - params.time);
  let object = circle(uv, centre, 0.17) + circle(uv, centre + vec2f(-0.13, 0.04), 0.08);
  let speckle = (hash21(floor(uv * params.resolution / 5.0)) - 0.5) * 0.025;
  let water = vec3f(0.015, 0.13, 0.18) + vec3f(caustic + speckle);
  let albedo = mix(water, vec3f(0.82, 0.30, 0.08), clamp(object, 0.0, 1.0));
  let z = max(0.05, params.orbit.z * (0.35 + 0.9 * uv.y) + 0.35 * floor);
  return vec4f(albedo, z);
}

// Underwater image formation, per channel:
// I = J * exp(-beta_d * z) + b_inf * (1 - exp(-beta_b * z)).
fn applyMedium(sample: vec4f) -> vec3f {
  let z = sample.a;
  let direct = exp(-params.beta_d.xyz * z);
  let backscatter = 1.0 - exp(-params.beta_b.xyz * z);
  return clamp(sample.rgb * direct + params.b_inf.xyz * backscatter, vec3f(0.0), vec3f(1.0));
}

@fragment
fn fragmentMain(in: VertexOut) -> @location(0) vec4f {
  let sample = raster(in.uv);
  return vec4f(applyMedium(sample), 1.0);
}
