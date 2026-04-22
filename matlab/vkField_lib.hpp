#include <stdint.h>

#ifndef LIB_FN
#if defined(_WIN32)
#define LIB_FN __declspec(dllexport)
#else
#define LIB_FN
#endif
#endif

typedef char byte;
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int8_t i8;
typedef int16_t i16;
typedef int32_t i32;
typedef int64_t i64;
typedef float f32;
typedef double f64;
typedef ptrdiff_t iz;
typedef size_t    uz;

struct Simulator { };

struct SimulationSettings {
	f32 samplingFrequency;
	f32 speedOfSound;
	i32 transmitElementCount;
	i32 receiveElementCount;
	i32 scatterCount;
	f32 startTime;
	i32 sampleCount;
	bool cumulative;
	f32 simulationTime;
};

typedef enum {
	Rectangular = 0,
} ApertureType;

typedef struct {
	f32 apertureInfo[12];
	f32 apertureType;
	f32 apodization;
	f32 delay;
	f32 padding;
} Element;

typedef struct {
	f32 position[3];
	f32 padding0;
	f32 normal[3];
	f32 padding1;
	f32 size[2];
	f32 padding2[2];
} RectangularAperture;

typedef struct {
	f32 position[3];
	f32 amplitude;
} Scatter;

#ifdef __cplusplus
extern "C" {
#endif

	LIB_FN bool create_vulkan_simulator_c(Simulator** simulator, void* logFunc, void* pUserData);
	LIB_FN void destroy_vulkan_simulator_c(Simulator* simulator, void* logFunc, void* pUserData);
	LIB_FN bool plan_simulation_c(SimulationSettings* settings, Element* transmitElements, Element* receiveElements, Scatter* scatters, void* logFunc, void* pUserData);
	LIB_FN bool simulate_c(Simulator* simulator, SimulationSettings* settings, Element* transmitElements, Element* receiveElements, Scatter* scatters, float* pulseEcho, void* logFunc, void* pUserData);

#ifdef __cplusplus
}
#endif
