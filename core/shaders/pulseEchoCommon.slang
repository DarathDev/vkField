module pulseEchoCommon;

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

public struct RectangularApertureBuffer {
  public RectangularAperture apertures[];
}

public struct ScatterBuffer {
  public Scatter scatters[];
}
