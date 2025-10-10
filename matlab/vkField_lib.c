#include "mex.h"
#include "vkField_lib.h"

int print(const char* string) {
	// return mexPrintf("%s\n", string);
	return 0;
}

/* The gateway function */
void mexFunction(int nlhs, mxArray* plhs[ ],
				  int nrhs, const mxArray* prhs[ ]) {


	if (nrhs != 4) {
		mexErrMsgIdAndTxt("vkField:nrhs", "Four inputs required.");
	}

	if (nlhs != 2) {
		mexErrMsgIdAndTxt("vkField:nlhs", "Two outputs required.");
	}

	SimulationSettings* settings = mxGetUint8s(prhs[0]);
	Element* transmitElement = mxGetUint8s(prhs[1]);
	Element* receiveElement = mxGetUint8s(prhs[2]);
	Scatter* scatters = mxGetUint8s(prhs[3]);

	SimulationSettings correctedSettings;
	memcpy(&correctedSettings, settings, sizeof(SimulationSettings));

	correctedSettings.transmitElementCount = mxGetNumberOfElements(prhs[1]) / sizeof(Element);
	correctedSettings.receiveElementCount = mxGetNumberOfElements(prhs[2]) / sizeof(Element);
	correctedSettings.scatterCount = mxGetNumberOfElements(prhs[3]) / sizeof(Scatter);

	planSimulation_c(&correctedSettings, transmitElement, receiveElement, scatters, mexPrintf);
	mwSize pulseEchoDims[2] = {
		correctedSettings.sampleCount,
		correctedSettings.receiveElementCount,
	};

	mxArray* pulseEchoOutput = mxCreateNumericArray((mwSize)2, pulseEchoDims, mxSINGLE_CLASS, mxREAL);
	float* pulseEcho = mxGetSingles(pulseEchoOutput);

	simulate_c(&correctedSettings, transmitElement, receiveElement, scatters, pulseEcho, print);

	plhs[0] = pulseEchoOutput;
	plhs[1] = mxCreateDoubleScalar(correctedSettings.startTime);
}

