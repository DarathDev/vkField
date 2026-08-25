#include "vkField_lib.hpp"
#include "mex.hpp"
#include "mexAdapter.hpp"
#include <functional>
#include <stdint.h>

using namespace matlab::data;
using matlab::mex::ArgumentList;

static void printLogger(void* pUserData, const char* text) {
	auto* function = static_cast<matlab::mex::Function*>( pUserData );
	if (function != nullptr) {
		std::cout << text << std::endl;
	}
}

static void freeRectangularElementSoaSlice(RectangularElementSoaSlice* slice) {
	if (slice == nullptr) {
		return;
	}
	delete[ ] slice->position;
	delete[ ] slice->normal;
	delete[ ] slice->size;
	delete[ ] slice->apodization;
	delete[ ] slice->delay;
	slice->position = nullptr;
	slice->normal = nullptr;
	slice->size = nullptr;
	slice->apodization = nullptr;
	slice->delay = nullptr;
	slice->len = 0;
}

template <typename T> const T* getDataPtr(matlab::data::Array arr) {
	const matlab::data::TypedArray<T> arr_t = arr;
	matlab::data::TypedIterator<const T> it(arr_t.begin());
	return it.operator->();
}

class MexFunction : public matlab::mex::Function {
	std::ostringstream outputStream;

public:
	void operator()(matlab::mex::ArgumentList outputs,
					matlab::mex::ArgumentList inputs) {
		void mexLock();

		std::shared_ptr<matlab::engine::MATLABEngine> matlabPtr = getEngine();
		ArrayFactory factory;

		checkArguments(outputs, inputs);
		ObjectArray mxSimulator(inputs[0]);

		SimulationSettings settings;
		SimulatorType simulatorType;
		RectangularElementSoaSlice transmitElements;
		RectangularElementSoaSlice receiveElements;
		ScatterSlice scatters;

		readSimulationInputs(mxSimulator, settings, simulatorType,
			transmitElements, receiveElements, scatters);

		Simulator* simulator;
		switch (simulatorType) {
		case SimulatorType::CPU:
			create_cpu_simulator_c(&simulator, printLogger, this);
			break;
		case SimulatorType::GPU:
			create_vulkan_simulator_c(&simulator, printLogger, this);
			break;
		}

		plan_simulation_c(simulator, &settings, transmitElements, receiveElements,
					  scatters, printLogger, this);
		matlabPtr->setProperty(mxSimulator, u"StartTime",
						   factory.createScalar<f32>(settings.startTime));
		matlabPtr->setProperty(mxSimulator, u"SampleCount",
						   factory.createScalar<u32>(settings.sampleCount));

		auto pulseEchoBuffer = factory.createBuffer<float>(
			settings.sampleCount * settings.receiveElementCount);

		simulate_c(simulator, &settings, transmitElements, receiveElements,
				   scatters, pulseEchoBuffer.get(), printLogger, this);
		ObjectArray mxMetrics = matlabPtr->getProperty(mxSimulator, u"Metrics");
		matlabPtr->setProperty(mxMetrics, u"SimulationTime",
							   factory.createScalar<f32>(settings.simulationMetrics.simulationTime));
		matlabPtr->setProperty(mxSimulator, u"Metrics", mxMetrics);

		ArrayDimensions pulseEchoDims;
		pulseEchoDims.push_back((uz)settings.sampleCount);
		pulseEchoDims.push_back((uz)settings.receiveElementCount);
		outputs[0] = factory.createArrayFromBuffer(pulseEchoDims,
												   std::move(pulseEchoBuffer));

		switch (simulatorType) {
		case SimulatorType::CPU:
			destroy_cpu_simulator_c(simulator, printLogger, this);
			break;
		case SimulatorType::GPU:
			destroy_vulkan_simulator_c(simulator, printLogger, this);
			break;
		}

		freeRectangularElementSoaSlice(&transmitElements);
		freeRectangularElementSoaSlice(&receiveElements);
		free(scatters.data);

		void mexUnlock();

		// mexApiGetProperty
	}

	void checkArguments(ArgumentList outputs, ArgumentList inputs) {
		// std::shared_ptr<matlab::engine::MATLABEngine> matlabPtr = getEngine();
		// ArrayFactory factory;
		// if (inputs[0].getType() != ArrayType::OBJECT) {
		// 	matlabPtr->feval(u"error", 0,
		// 					std::vector<Array>({
		// factory.createScalar("Input must be double array") }));
		// }
	}


	void readSimulationInputs(
		const ObjectArray& mxSimulator,
		SimulationSettings& settings,
		SimulatorType& simulatorType,
		RectangularElementSoaSlice& transmitElements,
		RectangularElementSoaSlice& receiveElements,
		ScatterSlice& scatters) {
		std::shared_ptr<matlab::engine::MATLABEngine> matlabPtr = getEngine();

		const EnumArray mxSimulatorType =
			matlabPtr->getProperty(mxSimulator, u"SimulatorType");
		const ObjectArray mxCpuSettings =
			matlabPtr->getProperty(mxSimulator, u"CpuSettings");
		const ObjectArray mxGpuSettings =
			matlabPtr->getProperty(mxSimulator, u"GpuSettings");
		const TypedArray<f32> mxSamplingFrequency =
			matlabPtr->getProperty(mxSimulator, u"SamplingFrequency");
		const TypedArray<f32> mxSpeedOfSound =
			matlabPtr->getProperty(mxSimulator, u"SpeedOfSound");
		const TypedArray<f32> mxStartTime =
			matlabPtr->getProperty(mxSimulator, u"StartTime");
		const TypedArray<u32> mxSampleCount =
			matlabPtr->getProperty(mxSimulator, u"SampleCount");
		const Array mxCumulative = matlabPtr->getProperty(mxSimulator, u"Cumulative");
		const ObjectArray mxTransmitElementSet =
			matlabPtr->getProperty(mxSimulator, u"TransmitElements");
		const ObjectArray mxReceiveElementSet =
			matlabPtr->getProperty(mxSimulator, u"ReceiveElements");
		const ObjectArray mxScatterSet =
			matlabPtr->getProperty(mxSimulator, u"Scatters");

		const std::string simulatorTypeName = static_cast<std::string>( mxSimulatorType[0] );
		if (simulatorTypeName == "CPU") {
			simulatorType = SimulatorType::CPU;
		}
		else if (simulatorTypeName == "GPU") {
			simulatorType = SimulatorType::GPU;
		}
		else {
			assert(false, "Unsupported simulator type");
		}
		settings.samplingFrequency = mxSamplingFrequency[0];
		settings.speedOfSound = mxSpeedOfSound[0];
		settings.startTime = mxStartTime[0];
		settings.sampleCount = mxSampleCount[0];
		settings.cumulative = mxCumulative[0];
		settings.transmitElementCount =
			(i32)matlabPtr->getProperty(mxTransmitElementSet, "Count")[0];
		settings.receiveElementCount =
			(i32)matlabPtr->getProperty(mxReceiveElementSet, "Count")[0];
		settings.scatterCount = (i32)matlabPtr->getProperty(mxScatterSet, "Count")[0];
		settings.cpuSettings.threadCount = (u32)matlabPtr->getProperty(mxCpuSettings, "ThreadCount")[0];
		const EnumArray mxGpuBackend = matlabPtr->getProperty(mxGpuSettings, u"Backend");
		const std::string gpuBackendName = static_cast<std::string>( mxGpuBackend[0] );
		if (gpuBackendName == "Vulkan") {
			settings.gpuSettings.backend = GpuBackend::Vulkan;
		}
		else {
			assert(false, "Unsupported GPU backend");
		}
		settings.gpuSettings.dispatchWorkLimit =
			(i32)matlabPtr->getProperty(mxGpuSettings, "DispatchWorkLimit")[0];

		transmitElements = { nullptr, nullptr, nullptr, nullptr, nullptr, 0 };
		receiveElements = { nullptr, nullptr, nullptr, nullptr, nullptr, 0 };
		scatters.data = (Scatter*)malloc(sizeof(Scatter) * settings.scatterCount);
		scatters.len = settings.scatterCount;

		copyElements(mxTransmitElementSet, &transmitElements);
		copyElements(mxReceiveElementSet, &receiveElements);
		copyScatters(mxScatterSet, scatters.data, scatters.len);
	}

	void copyElements(const Array& matlabArray, RectangularElementSoaSlice* slice) {
		std::shared_ptr<matlab::engine::MATLABEngine> matlabPtr = getEngine();

		Array propertyCount = matlabPtr->getProperty(matlabArray, "Count");
		Array propertyPositions = matlabPtr->getProperty(matlabArray, "Positions");
		Array propertyNormals = matlabPtr->getProperty(matlabArray, "Normals");
		Array propertySizes = matlabPtr->getProperty(matlabArray, "Sizes");
		Array propertyApodizations = matlabPtr->getProperty(matlabArray, "Apodizations");
		Array propertyDelays = matlabPtr->getProperty(matlabArray, "Delays");

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

		slice->position = new f32[numelPositions];
		slice->normal = new f32[numelNormals];
		slice->size = new f32[numelSizes];
		slice->apodization = new f32[numelApodizations];
		slice->delay = new f32[numelDelays];
		slice->len = static_cast<int>( propertyCount[0] );

		std::memcpy(slice->position, pPositions, numelPositions * sizeof(f32));
		std::memcpy(slice->normal, pNormals, numelNormals * sizeof(f32));
		std::memcpy(slice->size, pSizes, numelSizes * sizeof(f32));
		std::memcpy(slice->apodization, pApodizations, numelApodizations * sizeof(f32));
		std::memcpy(slice->delay, pDelays, numelDelays * sizeof(f32));
	}

	void copyScatters(const Array& matlabArray, Scatter* array, uz length) {
		std::shared_ptr<matlab::engine::MATLABEngine> matlabPtr = getEngine();

		constexpr uz countPositions = 3;
		constexpr uz countAmplitudes = 1;
		Array propertyPositions = matlabPtr->getProperty(matlabArray, "Positions");
		Array propertyAmplitudes =
			matlabPtr->getProperty(matlabArray, "Amplitudes");
		uz numelPositions = propertyPositions.getNumberOfElements();
		uz numelAmplitudes = propertyAmplitudes.getNumberOfElements();
		const f32* pPositions = getDataPtr<f32>(propertyPositions);
		const f32* pAmplitudes = getDataPtr<f32>(propertyAmplitudes);
		uz offsetPositions = 0;
		uz offsetAmplitudes = 0;
		for (uz i = 0; i < length; i++) {
			memcpy(&array[i].position, pPositions + offsetPositions,
				   countPositions * sizeof(f32));
			array[i].amplitude = *( pAmplitudes + offsetAmplitudes );
			offsetPositions =
				std::min(offsetPositions + countPositions, numelPositions);
			offsetAmplitudes =
				std::min(offsetAmplitudes + countAmplitudes, numelAmplitudes);
		}
	}
};
