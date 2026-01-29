#include "mex.hpp"
#include "mexAdapter.hpp"
#include "vkField_lib.hpp"
#include <functional>

using namespace matlab::data;
using matlab::mex::ArgumentList;


int print(matlab::mex::Function& function, const char* string) {
	std::shared_ptr<matlab::engine::MATLABEngine> matlabPtr = function.getEngine();
	ArrayFactory factory;
	std::string message(string);
	message.push_back('\n');
	matlabPtr->feval(u"fprintf", 0,
			std::vector<Array>({ factory.createScalar(message) }));
	return 0;
}

template <typename T>
const T* getDataPtr(matlab::data::Array arr) {
	const matlab::data::TypedArray<T> arr_t = arr;
	matlab::data::TypedIterator<const T> it(arr_t.begin());
	return it.operator->();
}

class MexFunction : public matlab::mex::Function {
	std::ostringstream outputStream;
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
		const ObjectArray mxTransmitElementSet = matlabPtr->getProperty(mxSimulator, u"TransmitElements");
		const ObjectArray mxReceiveElementSet = matlabPtr->getProperty(mxSimulator, u"ReceiveElements");
		const ObjectArray mxScatterSet = matlabPtr->getProperty(mxSimulator, u"Scatters");

		SimulationSettings settings;
		settings.samplingFrequency = mxSamplingFrequency[0];
		settings.speedOfSound = mxSpeedOfSound[0];
		settings.startTime = mxStartTime[0];
		settings.sampleCount = mxSampleCount[0];
		settings.headless = mxHeadless[0];
		settings.transmitElementCount = (i32)matlabPtr->getProperty(mxTransmitElementSet, "Count")[0];
		settings.receiveElementCount = (i32)matlabPtr->getProperty(mxReceiveElementSet, "Count")[0];
		settings.scatterCount = (i32)matlabPtr->getProperty(mxScatterSet, "Count")[0];

		Element* transmitElements = (Element*)malloc(sizeof(Element) * settings.transmitElementCount);
		Element* receiveElements = (Element*)malloc(sizeof(Element) * settings.receiveElementCount);
		Scatter* scatters = (Scatter*)malloc(sizeof(Scatter) * settings.scatterCount);

		copyElements(mxTransmitElementSet, transmitElements, settings.transmitElementCount);
		copyElements(mxReceiveElementSet, receiveElements, settings.receiveElementCount);
		copyScatters(mxScatterSet, scatters, settings.scatterCount);

		planSimulation_c(&settings, transmitElements, receiveElements, scatters, print, this);
		matlabPtr->setProperty(mxSimulator, u"StartTime", factory.createScalar<f32>(settings.startTime));
		matlabPtr->setProperty(mxSimulator, u"SampleCount", factory.createScalar<u32>(settings.sampleCount));

		auto pulseEchoBuffer = factory.createBuffer<float>(settings.sampleCount * settings.receiveElementCount);

		simulate_c(&settings, transmitElements, receiveElements, scatters, pulseEchoBuffer.get(), print, this);

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

		constexpr uz countPositions = 3;
		constexpr uz countNormals = 3;
		constexpr uz countSizes = 2;
		constexpr uz countApodizations = 1;
		constexpr uz countDelays = 1;
		Array propertyPositions = matlabPtr->getProperty(matlabArray, "Positions");
		Array propertyNormals = matlabPtr->getProperty(matlabArray, "Normals");
		Array propertySizes = matlabPtr->getProperty(matlabArray, "Sizes");
		Array propertyApodizations = matlabPtr->getProperty(matlabArray, "PhysicalApodizations");
		Array propertyDelays = matlabPtr->getProperty(matlabArray, "PhysicalDelays");
		uz numelPositions = propertyPositions.getNumberOfElements();
		uz numelNormals = propertyNormals.getNumberOfElements();
		uz numelSizes = propertySizes.getNumberOfElements();
		uz numelApodizations = propertyApodizations.getNumberOfElements();
		uz numelDelays = propertyDelays.getNumberOfElements();
		const f32* pPositions = getDataPtr<f32>(propertyPositions);
		const f32* pNormals = getDataPtr<f32>(propertyNormals);
		const f32* pSizes = getDataPtr<f32>(propertySizes);
		const f32* pApodizations = getDataPtr<f32>(propertyApodizations);
		const f32* pDelays = getDataPtr<f32>(propertyDelays);
		uz offsetPositions = 0;
		uz offsetNormals = 0;
		uz offsetSizes = 0;
		uz offsetApodizations = 0;
		uz offsetDelays = 0;
		for (uz i = 0; i < length; i++) {
			memcpy(&( (RectangularAperture*)array[i].apertureInfo )->position, pPositions + offsetPositions, countPositions * sizeof(f32));
			memcpy(&( (RectangularAperture*)array[i].apertureInfo )->normal, pNormals + offsetNormals, countNormals * sizeof(f32));
			memcpy(&( (RectangularAperture*)array[i].apertureInfo )->size, pSizes + offsetSizes, countSizes * sizeof(f32));
			array[i].apodization = *( pApodizations + offsetApodizations );
			array[i].delay = *( pDelays + offsetDelays );
			offsetPositions = std::min(offsetPositions + countPositions, numelPositions);
			offsetNormals = std::min(offsetNormals + countNormals, numelNormals);
			offsetSizes = std::min(offsetSizes + countSizes, numelSizes);
			offsetApodizations = std::min(offsetApodizations + countApodizations, numelApodizations);
			offsetDelays = std::min(offsetDelays + countDelays, numelDelays);
		}
	}

	void copyScatters(const Array& matlabArray, Scatter* array, uz length) {
		std::shared_ptr<matlab::engine::MATLABEngine> matlabPtr = getEngine();

		constexpr uz countPositions = 3;
		constexpr uz countAmplitudes = 1;
		Array propertyPositions = matlabPtr->getProperty(matlabArray, "Positions");
		Array propertyAmplitudes = matlabPtr->getProperty(matlabArray, "Amplitudes");
		uz numelPositions = propertyPositions.getNumberOfElements();
		uz numelAmplitudes = propertyAmplitudes.getNumberOfElements();
		const f32* pPositions = getDataPtr<f32>(propertyPositions);
		const f32* pAmplitudes = getDataPtr<f32>(propertyAmplitudes);
		uz offsetPositions = 0;
		uz offsetAmplitudes = 0;
		for (uz i = 0; i < length; i++) {
			memcpy(&array[i].position, pPositions + offsetPositions, countPositions * sizeof(f32));
			array[i].amplitude = *( pAmplitudes + offsetAmplitudes );
			offsetPositions = std::min(offsetPositions + countPositions, numelPositions);
			offsetAmplitudes = std::min(offsetAmplitudes + countAmplitudes, numelAmplitudes);
		}
	}
};
