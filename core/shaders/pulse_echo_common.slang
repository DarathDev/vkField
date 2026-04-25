module pulse_echo_common;

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
