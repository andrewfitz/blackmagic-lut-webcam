#include <metal_stdlib>
using namespace metal;

struct Parameters {
  uint4 geometry;
  float4 domainLow;
  float4 domainScale;
  float4 decodeRange;
  float4 decodeMatrix;
  float4 encodeMatrix;
  uint4 options;
};

float3 lookup(float3 rgb, device const float4 *cube, constant Parameters &p) {
  if (!p.options.x) return rgb;
  uint n = p.geometry.w;
  float3 position = clamp((rgb - p.domainLow.xyz) * p.domainScale.xyz, 0.0f, 1.0f) * float(n - 1);
  uint3 lo = uint3(floor(position)), hi = min(lo + 1, uint3(n - 1));
  float3 t = position - float3(lo);
  float3 a = mix(cube[(lo.z * n + lo.y) * n + lo.x].rgb, cube[(lo.z * n + lo.y) * n + hi.x].rgb, t.x);
  float3 b = mix(cube[(lo.z * n + hi.y) * n + lo.x].rgb, cube[(lo.z * n + hi.y) * n + hi.x].rgb, t.x);
  float3 c = mix(cube[(hi.z * n + lo.y) * n + lo.x].rgb, cube[(hi.z * n + lo.y) * n + hi.x].rgb, t.x);
  float3 d = mix(cube[(hi.z * n + hi.y) * n + lo.x].rgb, cube[(hi.z * n + hi.y) * n + hi.x].rgb, t.x);
  return mix(mix(a, b, t.y), mix(c, d, t.y), t.z);
}

float3 decode(float y, float2 c, constant Parameters &p) {
  float luma = (y - p.decodeRange.x) / p.decodeRange.y;
  c = (c - p.decodeRange.z) / p.decodeRange.w;
  return float3(luma + p.decodeMatrix.x * c.y, luma - p.decodeMatrix.z * c.x - p.decodeMatrix.w * c.y, luma + p.decodeMatrix.y * c.x);
}

kernel void planarLUT(texture2d<float, access::read> y [[texture(0)]], texture2d<float, access::sample> uv [[texture(1)]],
  texture2d<float, access::write> rgb [[texture(2)]], device const float4 *cube [[buffer(0)]],
  constant Parameters &p [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= p.geometry.x || gid.y >= p.geometry.y) return;
  constexpr sampler chroma(coord::normalized, address::clamp_to_edge, filter::linear);
  float2 coord = (float2(gid) + 0.5f) / float2(p.geometry.xy);
  float luma = y.read(gid).r * (65535.0f / 64.0f);
  float2 c = uv.sample(chroma, coord).rg * (65535.0f / 64.0f);
  rgb.write(float4(lookup(decode(luma, c, p), cube, p), 1), gid);
}

float2 packedChroma(device const uint *words, int pair, uint row, constant Parameters &p) {
  pair = clamp(pair, 0, int(p.geometry.x / 2) - 1);
  uint offset = row * p.geometry.z + uint(pair / 3) * 4;
  uint lane = uint(pair % 3);
  if (lane == 0) return float2(words[offset] & 1023, (words[offset] >> 20) & 1023);
  if (lane == 1) return float2((words[offset + 1] >> 10) & 1023, words[offset + 2] & 1023);
  return float2((words[offset + 2] >> 20) & 1023, (words[offset + 3] >> 10) & 1023);
}

kernel void packedLUT(device const uint *words [[buffer(2)]], texture2d<float, access::write> rgb [[texture(2)]],
  device const float4 *cube [[buffer(0)]], constant Parameters &p [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= p.geometry.x || gid.y >= p.geometry.y) return;
  uint offset = gid.y * p.geometry.z + (gid.x / 6) * 4;
  uint lane = gid.x % 6, value;
  if (lane == 0) value = (words[offset] >> 10) & 1023;
  else if (lane == 1) value = words[offset + 1] & 1023;
  else if (lane == 2) value = (words[offset + 1] >> 20) & 1023;
  else if (lane == 3) value = (words[offset + 2] >> 10) & 1023;
  else if (lane == 4) value = words[offset + 3] & 1023;
  else value = (words[offset + 3] >> 20) & 1023;
  float position = (float(gid.x) - 0.5f) / 2.0f;
  int pair = int(floor(position));
  float2 c = mix(packedChroma(words, pair, gid.y, p), packedChroma(words, pair + 1, gid.y, p), position - floor(position));
  rgb.write(float4(lookup(decode(float(value), c, p), cube, p), 1), gid);
}

float lanczos3(float x) {
  x = abs(x);
  if (x < 1e-5f) return 1;
  if (x >= 3) return 0;
  float pi = 3.14159265358979323846f;
  return (sin(pi * x) / (pi * x)) * (sin(pi * x / 3) / (pi * x / 3));
}

kernel void lanczosHorizontal(texture2d<float, access::read> input [[texture(0)]], texture2d<float, access::write> output [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
  float scale = float(input.get_width()) / float(output.get_width());
  float center = (float(gid.x) + 0.5f) * scale - 0.5f;
  int begin = int(ceil(center - 3 * scale)), end = int(floor(center + 3 * scale));
  float4 sum = 0;
  float weightSum = 0;
  for (int x = begin; x <= end; ++x) {
    float weight = lanczos3((float(x) - center) / scale);
    sum += input.read(uint2(clamp(x, 0, int(input.get_width()) - 1), gid.y)) * weight;
    weightSum += weight;
  }
  output.write(sum / weightSum, gid);
}

kernel void lanczosVertical(texture2d<float, access::read> input [[texture(0)]], texture2d<float, access::write> output [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
  float scale = float(input.get_height()) / float(output.get_height());
  float center = (float(gid.y) + 0.5f) * scale - 0.5f;
  int begin = int(ceil(center - 3 * scale)), end = int(floor(center + 3 * scale));
  float4 sum = 0;
  float weightSum = 0;
  for (int y = begin; y <= end; ++y) {
    float weight = lanczos3((float(y) - center) / scale);
    sum += input.read(uint2(gid.x, clamp(y, 0, int(input.get_height()) - 1))) * weight;
    weightSum += weight;
  }
  output.write(sum / weightSum, gid);
}

float3 encode(float3 rgb, constant Parameters &p) {
  float kr = p.encodeMatrix.x, kb = p.encodeMatrix.y;
  float y = dot(rgb, float3(kr, 1 - kr - kb, kb));
  return float3(y, (rgb.b - y) / (2 * (1 - kb)), (rgb.r - y) / (2 * (1 - kr)));
}

kernel void encodeNV12(texture2d<float, access::read> rgb [[texture(0)]], texture2d<float, access::write> y [[texture(1)]],
  texture2d<float, access::write> uv [[texture(2)]], constant Parameters &p [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= rgb.get_width() || gid.y >= rgb.get_height()) return;
  y.write(float4((16 + 219 * encode(rgb.read(gid).rgb, p).x) / 255), gid);
  if (!(gid.x % 2) && !(gid.y % 2)) {
    float3 color = (rgb.read(gid).rgb + rgb.read(gid + uint2(1, 0)).rgb + rgb.read(gid + uint2(0, 1)).rgb + rgb.read(gid + uint2(1, 1)).rgb) / 4;
    float2 c = (128 + 224 * encode(color, p).yz) / 255;
    uv.write(float4(c, 0, 1), gid / 2);
  }
}

kernel void encode422(texture2d<float, access::read> rgb [[texture(0)]], texture2d<float, access::write> y [[texture(1)]],
  texture2d<float, access::write> uv [[texture(2)]], constant Parameters &p [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= rgb.get_width() || gid.y >= rgb.get_height()) return;
  float code = clamp(round(64 + 876 * encode(rgb.read(gid).rgb, p).x), 0.0f, 1023.0f);
  y.write(float4(code * 64 / 65535), gid);
  if (!(gid.x % 2)) {
    float3 color = (rgb.read(gid).rgb + rgb.read(gid + uint2(1, 0)).rgb) / 2;
    float2 c = clamp(round(512 + 896 * encode(color, p).yz), 0.0f, 1023.0f) * 64 / 65535;
    uv.write(float4(c, 0, 1), uint2(gid.x / 2, gid.y));
  }
}
