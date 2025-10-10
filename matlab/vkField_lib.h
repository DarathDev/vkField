#ifndef LIB_FN
#if defined(_WIN32)
#define LIB_FN __declspec(dllexport)
#else
#define LIB_FN
#endif
#endif

typedef struct {
	float samplingFrequency;
	float speedOfSound;
	int transmitElementCount;
	int receiveElementCount;
	int scatterCount;
	float startTime;
	int sampleCount;
	bool headless;
} SimulationSettings;

typedef struct {
	float apertureInfo[12];
	float apodiation;
	float delay;
	bool active;
	float padding[1];
} Element;

typedef struct {
	float position[3];
	float amplitude;
} Scatter;

LIB_FN void planSimulation_c(SimulationSettings* settings, Element* transmitElements, Element* receiveElements, Scatter* scatters, void* logFunc);
LIB_FN void simulate_c(SimulationSettings* settings, Element* transmitElements, Element* receiveElements, Scatter* scatters, float* pulseEcho, void* logFunc);
