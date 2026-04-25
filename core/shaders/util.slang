module util;

public static const float EPSILON = 0.0001;
public static const float PI      = radians(180.f);

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
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
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
