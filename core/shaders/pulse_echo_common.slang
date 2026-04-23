module pulse_echo_common;

public static const float EPSILON = 0.0001;
public static const float PI = 3.14159265358979323846264338327950288;

public struct SimulationSettings {
  public float samplingFrequency;
  public float speedOfSound;
  public float startingTime;
  public uint sampleCount;
  public uint receiveStart;
  public uint receiveCount;
  public uint transmitCount;
  public uint transmitStart;
  public uint transmitBatchCount;
  public uint scatterCount;
};

public struct RectangularAperture {
  public float3 position;
  public uint padding0;
  public float3 normal;
  public uint padding1;
  public float2 size;
  public uint2 padding2;
  public uint apertureType;
  public float apodization;
  public float delay;
  public bool active;
};

public struct Scatter {
  public float3 position;
  public float amplitude;
};

[[vk::push_constant]]
public ConstantBuffer<SimulationSettings> settings;

[[vk::binding(0, 0)]]
public RWStructuredBuffer<RectangularAperture> transmitApertures : register(u0, space0);

[[vk::binding(1, 0)]]
public RWStructuredBuffer<RectangularAperture> receiveApertures : register(u1, space0);

[[vk::binding(2, 0)]]
public RWStructuredBuffer<Scatter> scatters : register(u2, space0);

[[format("r32f")]]
[[vk::binding(3, 0)]]
public RWStructuredBuffer<Atomic<float>> response : register(u3, space0);

public float4x4 translate(in float3 from, in float3 to) {
  return float4x4(
      1, 0, 0, to.x - from.x,
      0, 1, 0, to.y - from.y,
      0, 0, 1, to.z - from.z,
      0, 0, 0, 1);
}

public float4x4 rotate(in float3 from, in float3 to) {
  float3 axis = cross(from, to);
  float theta = acos(dot(from, to));
  float4x4 eye = {
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
  };
  float4x4 a = {
    0,
    -axis.z,
    axis.y,
    0,
    axis.z,
    0,
    -axis.x,
    0,
    -axis.y,
    axis.x,
    0,
    0,
    0,
    0,
    0,
    1,
  };
  return eye + sin(theta) * a + (1 - cos(theta)) * mul(a, a);
}
