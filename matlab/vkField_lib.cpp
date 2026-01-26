#include "mex.hpp"
#include "mexAdapter.hpp"
#include "vkField_lib.hpp"

using namespace matlab::data;
using matlab::mex::ArgumentList;

int print(const char* string) {
	// return mexPrintf("%s\n", string);
	return 0;
}

class MexFunction : public matlab::mex::Function {
public:
	void operator()(matlab::mex::ArgumentList outputs, matlab::mex::ArgumentList inputs) {
		void mexLock();

		std::shared_ptr<matlab::engine::MATLABEngine> matlabPtr = getEngine();
		ArrayFactory factory;

		checkArguments(outputs, inputs);
		ObjectArray mxSimulator(inputs[0]);

		const TypedArray<f32> mxSamplingFrequency = matlabPtr->getProperty(mxSimulator, u"SamplingFrequency");
		const TypedArray<f32> mxSpeedOfSound = matlabPtr->getProperty(mxSimulator, u"SpeedOfSound");
		const TypedArray<f32> mxStartTime = matlabPtr->getProperty(mxSimulator, u"StartTime");
		const TypedArray<u32> mxSampleCount = matlabPtr->getProperty(mxSimulator, u"SampleCount");
		const Array mxHeadless = matlabPtr->getProperty(mxSimulator, u"Headless");
		const Array mxTransmitElements = matlabPtr->getProperty(mxSimulator, u"TransmitElements");
		const Array mxReceiveElements = matlabPtr->getProperty(mxSimulator, u"ReceiveElements");
		const Array mxScatters = matlabPtr->getProperty(mxSimulator, u"Scatters");

		SimulationSettings settings;
		settings.samplingFrequency = mxSamplingFrequency[0];
		settings.speedOfSound = mxSpeedOfSound[0];
		settings.startTime = mxStartTime[0];
		settings.sampleCount = mxSampleCount[0];
		settings.headless = mxHeadless[0];
		settings.transmitElementCount = (i32)mxTransmitElements.getNumberOfElements();
		settings.receiveElementCount = (i32)mxReceiveElements.getNumberOfElements();
		settings.scatterCount = (i32)mxScatters.getNumberOfElements();

		Element* transmitElements = (Element*)malloc(sizeof(Element) * settings.transmitElementCount);
		Element* receiveElements = (Element*)malloc(sizeof(Element) * settings.receiveElementCount);
		Scatter* scatters = (Scatter*)malloc(sizeof(Scatter) * settings.scatterCount);

		copyElements(mxTransmitElements, transmitElements, settings.transmitElementCount);
		copyElements(mxReceiveElements, receiveElements, settings.receiveElementCount);
		copyScatters(mxScatters, scatters, settings.scatterCount);

		planSimulation_c(&settings, transmitElements, receiveElements, scatters, print);
		matlabPtr->setProperty(mxSimulator, u"StartTime", factory.createScalar<f32>(settings.startTime));
		matlabPtr->setProperty(mxSimulator, u"SampleCount", factory.createScalar<u32>(settings.sampleCount));

		auto pulseEchoBuffer = factory.createBuffer<float>(settings.sampleCount * settings.receiveElementCount);

		simulate_c(&settings, transmitElements, receiveElements, scatters, pulseEchoBuffer.get(), print);

		ArrayDimensions pulseEchoDims;
		pulseEchoDims.push_back((uz)settings.sampleCount);
		pulseEchoDims.push_back((uz)settings.receiveElementCount);
		outputs[0] = factory.createArrayFromBuffer(pulseEchoDims, std::move(pulseEchoBuffer));

		void mexUnlock();

		// mexApiGetProperty

	}

	void checkArguments(ArgumentList outputs, ArgumentList inputs) {
		// std::shared_ptr<matlab::engine::MATLABEngine> matlabPtr = getEngine();
		// ArrayFactory factory;
		// if (inputs[0].getType() != ArrayType::OBJECT) {
		// 	matlabPtr->feval(u"error", 0,
		// 					std::vector<Array>({ factory.createScalar("Input must be double array") }));
		// }
	}


	void copyElements(const Array& matlabArray, Element* array, uz length) {
		std::shared_ptr<matlab::engine::MATLABEngine> matlabPtr = getEngine();
		for (uz i = 0; i < length; i++) {
			// EnumArray mxApertureType = matlabPtr->getProperty(matlabArray, i, "ApertureType");
			u32 apertureType = 0;
			array[i].apodization = matlabPtr->getProperty(matlabArray, i, "Apodization")[0];
			array[i].delay = matlabPtr->getProperty(matlabArray, i, "Delay")[0];
			array[i].active = matlabPtr->getProperty(matlabArray, i, "Active")[0];
			switch (apertureType) {
			case Rectangular:
				Array position = matlabPtr->getProperty(matlabArray, i, "Position");
				for (uz j = 0; j < 3; j++) {
					( (RectangularAperture*)array[i].apertureInfo )->position[j] = position[j];
				}
				Array normal = matlabPtr->getProperty(matlabArray, i, "Normal");
				for (uz j = 0; j < 3; j++) {
					( (RectangularAperture*)array[i].apertureInfo )->normal[j] = normal[j];
				}
				Array size = matlabPtr->getProperty(matlabArray, i, "Size");
				for (uz j = 0; j < 2; j++) {
					( (RectangularAperture*)array[i].apertureInfo )->size[j] = size[j];
				}
			}
		}
	}

	void copyScatters(const Array& matlabArray, Scatter* array, uz length) {
		std::shared_ptr<matlab::engine::MATLABEngine> matlabPtr = getEngine();
		for (uz i = 0; i < length; i++) {
			Array position = matlabPtr->getProperty(matlabArray, i, "Position");
			for (uz j = 0; j < 3; j++) {
				array[i].position[j] = position[j];
			}
			array[i].amplitude = matlabPtr->getProperty(matlabArray, i, "Amplitude")[0];
		}
	}
};
