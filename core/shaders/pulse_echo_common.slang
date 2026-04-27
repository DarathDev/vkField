module pulse_echo_common;

public struct PackScatterRectSettings {
	public uint scatterBatchOffset;
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

[[vk::binding(0, 0)]]
public StructuredBuffer<RectangularAperture> transmitApertures;

[[vk::binding(1, 0)]]
public StructuredBuffer<RectangularAperture> receiveApertures;

[[vk::binding(2, 0)]]
public StructuredBuffer<Scatter> scatters;

[[vk::binding(3, 0)]]
public RWStructuredBuffer<float> response;

[[vk::binding(4, 0)]]
public RWStructuredBuffer<float4> packed_scatter_rects;

[[vk::binding(5, 0)]]
public RWStructuredBuffer<float> packed_scatter_scales;
